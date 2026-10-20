# frozen_string_literal: true

require "timeout"

module Wt
  module Commands
    # Runs `source.fetch(*args)` off the render loop and reports a Msg::Fetched.
    # source: a module whose `fetch` returns a Wt::Message (it may call Shell).
    # A raise or a timeout becomes Msg::SourceFailed for `key`, never a crash.
    class Fetch < Data.define(:key, :source, :args, :timeout)
      include Rooibos::Command::Custom

      def call(out, _token)
        message = Timeout.timeout(timeout) { source.fetch(*args) }
        out.put(Ractor.make_shareable(Msg::Fetched.new(key:, message:)))
      rescue StandardError, Timeout::Error => e
        out.put(Ractor.make_shareable(Msg::Fetched.new(key:, message: Msg::SourceFailed.new(key:, error: "#{e.class}: #{e.message}"))))
      end
    end

    # Emits Msg::Tick(kind) every `interval` seconds until cancelled.
    class Ticker < Data.define(:kind, :interval)
      include Rooibos::Command::Custom

      def call(out, token)
        until token.canceled?
          slept = 0.0
          while slept < interval && !token.canceled?
            sleep 0.1
            slept += 0.1
          end
          out.put(Ractor.make_shareable(Msg::Tick.new(kind:, at: Time.now))) unless token.canceled?
        end
      end
    end

    # `mise run <args...>` in a worktree (or the root). Reports Msg::CommandFinished.
    # Never interactive: anything that needs the terminal goes through Terminal.handover.
    # stdin is empty, so a task that prompts (or an untrusted mise config) fails with
    # its stderr in a toast instead of hanging; MISE_YES is deliberately not set.
    class MiseTask < Data.define(:label, :slug, :cwd, :args, :timeout, :refresh)
      include Rooibos::Command::Custom

      def call(out, _token)
        r = Shell.capture(["mise", "run", *args], chdir: cwd, env: { "NO_COLOR" => "1" }, timeout:, stdin: "")
        msg = Msg::CommandFinished.new(label:, slug:, status: r.timed_out ? -1 : r.status, stderr: r.timed_out ? "timed out" : r.stderr, refresh:)
        out.put(Ractor.make_shareable(msg))
      end
    end

    # Plain argv (not a mise task), same reporting. For gh/kitten/notify-send.
    class Exec < Data.define(:label, :slug, :cwd, :argv, :timeout, :refresh)
      include Rooibos::Command::Custom

      def call(out, _token)
        r = Shell.capture(argv, chdir: cwd, timeout:, stdin: "")
        msg = Msg::CommandFinished.new(label:, slug:, status: r.timed_out ? -1 : r.status, stderr: r.timed_out ? "timed out" : r.stderr, refresh:)
        out.put(Ractor.make_shareable(msg))
      end
    end

    class ExpireToast < Data.define(:id, :after)
      include Rooibos::Command::Custom

      def call(out, token)
        slept = 0.0
        while slept < after && !token.canceled?
          sleep 0.1
          slept += 0.1
        end
        out.put(Msg::ToastExpired.new(id:))
      end
    end

    # Fields are frozen copies (String#-@), so commands are Ractor-shareable even
    # when callers pass interpolated or path-built strings.
    def self.fetch(model, key, source, *args)
      Fetch.new(key: -key, source:, args: Ractor.make_shareable(args), timeout: model.config.timeout * 2)
    end

    def self.mise(model, label, slug, *args, cwd: nil, refresh: true)
      MiseTask.new(label: -label, slug: slug && -slug, cwd: -(cwd || (slug ? model.config.worktree_path(slug) : model.config.root)),
                   args: Ractor.make_shareable(args.map(&:to_s)), timeout: model.config.action_timeout, refresh:)
    end

    def self.exec(model, label, slug, argv, cwd: nil, refresh: false, timeout: nil)
      Exec.new(label: -label, slug: slug && -slug, cwd: -(cwd || model.config.root), argv: Ractor.make_shareable(argv.map(&:to_s)),
               timeout: timeout || model.config.timeout, refresh:)
    end

    def self.expire_toast(id, after: 6) = ExpireToast.new(id:, after:)
  end
end
