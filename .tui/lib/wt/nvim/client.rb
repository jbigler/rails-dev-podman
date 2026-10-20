# frozen_string_literal: true

require "shellwords"

module Wt
  # The worktree's nvim server (`nvim@`, `--listen 0.0.0.0:7777`, published on
  # 127.0.0.1:NVIM_PORT), driven with the host's `nvim --server ... --remote-*`.
  # Everything here blocks: call it from a command, never from update.
  module Nvim
    MOUNT = "/app"

    # Listed buffers backed by a file that hold unsaved changes — what `:wa`
    # writes. Scratch / terminal / unnamed buffers are not files and never count.
    MODIFIED = "filter(getbufinfo({'buflisted': 1}), " \
               "{_, b -> b.changed && !empty(b.name) && getbufvar(b.bufnr, '&buftype') ==# ''})"
    # Names of the modified buffers, as a JSON string (--remote-expr only prints strings).
    MODIFIED_NAMES = "json_encode(map(#{MODIFIED}, {_, b -> b.name}))"
    # `:wa`, then the names still modified. List items evaluate left to right.
    WRITE_ALL = "[execute('silent! wa'), #{MODIFIED_NAMES}][1]"

    # How long `o` / `d` keep retrying while a new window starts the server.
    START_WAIT = 30.0

    def self.server(port) = "127.0.0.1:#{port}"

    def self.expr(port, expression, timeout:)
      Shell.capture(["nvim", "--server", server(port), "--remote-expr", expression], timeout:, stdin: "")
    end

    # Nothing is listening (E247 "Failed to connect ... connection refused"), or
    # there is no nvim on the host to ask. A hung server (timeout) is not this.
    def self.unreachable?(result)
      return false if result.timed_out

      result.status == 127 || result.stderr.match?(/E247|connection refused|failed to connect/i)
    end

    # Before a stack operation: `:wa` when the server has modified buffers.
    # ok when the server is down (nothing to save) or every buffer was written;
    # otherwise a failing Result whose stderr names what is still unsaved.
    def self.write_all(config, worktree)
      port = worktree.nvim_port
      return ok_result unless port

      before = expr(port, MODIFIED_NAMES, timeout: config.timeout)
      return ok_result if unreachable?(before)
      return failed("nvim: could not list modified buffers (#{before.error_line})") unless before.ok?

      names = parse_names(before.stdout)
      return failed("nvim: unexpected answer listing modified buffers") unless names
      return ok_result if names.empty?

      after = expr(port, WRITE_ALL, timeout: config.timeout * 2)
      return failed("nvim: :wa failed (#{after.error_line})") unless after.ok?

      left = parse_names(after.stdout)
      return failed("nvim: unexpected answer after :wa") unless left
      return ok_result if left.empty?

      shown = left.map { display_path(it) }
      failed("nvim: :wa left #{left.size} unsaved buffer#{'s' if left.size > 1}: #{shown.join(', ')}")
    end

    # Host path of an ACP tool-call location → the same file inside the nvim
    # container. nil for anything outside $ROOT/<slug> (spec: not opened), and
    # for any path holding a control character: the agent chooses these paths.
    def self.container_path(config, slug, host_path)
      return nil unless host_path.is_a?(String) && host_path.start_with?("/")
      return nil if host_path.match?(/[[:cntrl:]]/)

      path = File.expand_path(host_path)
      base = File.expand_path(config.worktree_path(slug))
      return MOUNT if path == base
      return nil unless path.start_with?("#{base}/")

      "#{MOUNT}/#{path.delete_prefix("#{base}/")}"
    end

    # A container path as a person reads it: relative to the worktree.
    def self.display_path(path)
      path.start_with?("#{MOUNT}/") ? path.delete_prefix("#{MOUNT}/") : path
    end

    # `:drop <file>` then the cursor to `line`, as one expression. The path is
    # a Vim string literal escaped by fnameescape() inside nvim: no character
    # of it is ever read as a key or as Ex syntax.
    def self.open_expr(path, line)
      "execute([#{[drop_cmd(path), cursor_cmd(line)].compact.join(', ')}])"
    end

    # One expression that opens the file and shows its diff against HEAD:
    # `:Gitsigns diffthis` when gitsigns is loaded, else a scratch split holding
    # `git show HEAD:<path>` diffed with the buffer. The path only ever appears
    # inside Vim string literals passed through fnameescape() / shellescape(),
    # and container_path has rejected newlines (which would end `:read !`).
    def self.diff_expr(path, line)
      head = "HEAD:#{path.delete_prefix("#{MOUNT}/")}"
      cmds = [
        drop_cmd(path),
        cursor_cmd(line),
        vim_str("if exists(':Gitsigns') == 2"),
        vim_str("Gitsigns diffthis"),
        vim_str("else"),
        vim_str("let g:wt_diff_ft = &filetype"),
        vim_str("diffthis"),
        vim_str("vnew"),
        vim_str("setlocal buftype=nofile bufhidden=wipe noswapfile"),
        "'silent 0read !git -C ' . shellescape(#{vim_str(MOUNT)}, 1) . ' show ' . shellescape(#{vim_str(head)}, 1)",
        vim_str("silent $delete _"),
        vim_str("let &l:filetype = g:wt_diff_ft"),
        vim_str("diffthis"),
        vim_str("wincmd p"),
        vim_str("endif")
      ].compact
      "execute([#{cmds.join(', ')}])"
    end

    # Ways to open `mise run nvim` in a new OS window, best first:
    # kitty remote control, then $TERMINAL -e. Empty: only `n` is left.
    def self.window_launchers(cwd, env: ENV)
      launchers = []
      if !env["KITTY_LISTEN_ON"].to_s.empty? || on_path?("kitten", env)
        launchers << [:capture, ["kitten", "@", "launch", "--type=os-window", "--cwd=#{cwd}", "mise", "run", "nvim"]]
      end
      terminal = Shellwords.split(env["TERMINAL"].to_s)
      launchers << [:spawn, [*terminal, "-e", "mise", "run", "nvim"]] unless terminal.empty?
      launchers
    end

    def self.on_path?(name, env = ENV)
      env["PATH"].to_s.split(File::PATH_SEPARATOR).any? do |dir|
        file = File.join(dir, name)
        File.file?(file) && File.executable?(file)
      end
    end

    # Tries each launcher in order; [true, nil] on the first that starts, else
    # [false, last error]. :spawn launchers are detached (the window outlives us).
    def self.launch_window(launchers, cwd, timeout:)
      error = "no way to open a window"
      launchers.each do |kind, argv|
        if kind == :spawn
          begin
            pid = Process.spawn(*argv, chdir: cwd, pgroup: true, in: File::NULL, out: File::NULL, err: File::NULL)
            Process.detach(pid)
            return [true, nil]
          rescue SystemCallError => e
            error = "#{argv.first}: #{e.message}"
          end
        else
          r = Shell.capture(argv, chdir: cwd, timeout:, stdin: "")
          return [true, nil] if r.ok?

          error = "#{argv.first}: #{r.error_line}"
        end
      end
      [false, error]
    end

    # Evaluates an expression. While the server is still starting (refused),
    # retries for `wait` seconds.
    def self.deliver(port, expression, timeout:, wait: 0.0, canceled: -> { false })
      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + wait
      loop do
        r = expr(port, expression, timeout:)
        return r if r.ok? || !unreachable?(r) || canceled.call
        return r if Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline

        sleep 0.5
      end
    end

    # `o` / `d`: open a new window first when no UI is attached, then deliver
    # the expression. Reports Msg::CommandFinished(label) like every other action.
    class Drive < Data.define(:label, :slug, :port, :payload, :cwd, :launchers, :timeout)
      include Rooibos::Command::Custom

      def call(out, token)
        wait = 0.0
        unless launchers.empty?
          started, error = Nvim.launch_window(launchers, cwd, timeout:)
          return finish(out, 1, "nvim window: #{error}") unless started

          wait = START_WAIT
        end
        r = Nvim.deliver(port, payload, timeout:, wait:, canceled: -> { token.canceled? })
        return finish(out, 0, "") if r.ok?

        finish(out, r.timed_out ? -1 : (r.status || 1), Nvim.unreachable?(r) ? "nvim is not running (#{r.error_line})" : r.error_line)
      end

      private

      def finish(out, status, stderr)
        out.put(Ractor.make_shareable(Msg::CommandFinished.new(label:, slug:, status:, stderr:, refresh: false)))
      end
    end

    # `N`: a new OS window running `mise run nvim`, trying each launcher in turn.
    class LaunchWindow < Data.define(:label, :slug, :cwd, :launchers, :timeout)
      include Rooibos::Command::Custom

      def call(out, _token)
        started, error = Nvim.launch_window(launchers, cwd, timeout:)
        msg = Msg::CommandFinished.new(label:, slug:, status: started ? 0 : 1, stderr: error.to_s, refresh: false)
        out.put(Ractor.make_shareable(msg))
      end
    end

    def self.drop_cmd(path) = "'drop ' . fnameescape(#{vim_str(path)})"

    def self.cursor_cmd(line) = (vim_str("call cursor(#{line}, 1)") if line.is_a?(Integer) && line.positive?)

    # A Vim single-quoted string literal: only `'` is special, doubled.
    def self.vim_str(text) = "'#{text.gsub("'", "''")}'"

    # --remote-expr prints the expression's string result. Older clients wrap it
    # with string(), i.e. in single quotes; accept both.
    def self.unwrap(stdout)
      s = stdout.strip
      s.length >= 2 && s.start_with?("'") && s.end_with?("'") ? s[1...-1].gsub("''", "'") : s
    end

    def self.parse_names(stdout)
      names = JSON.parse(unwrap(stdout))
      names.is_a?(Array) && names.all?(String) ? names : nil
    rescue JSON::ParserError
      nil
    end

    def self.ok_result = Shell::Result.new(stdout: "", stderr: "", status: 0, timed_out: false)
    def self.failed(text) = Shell::Result.new(stdout: "", stderr: text.freeze, status: 1, timed_out: false)
  end
end
