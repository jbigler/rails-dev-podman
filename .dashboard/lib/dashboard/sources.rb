# frozen_string_literal: true

module Dashboard
  # §5.2: one module per source (sources/*.rb). `fetch` runs the command
  # through Shell and returns plain data; `parse` is pure (tests feed it
  # fixtures). A fetch that raises Sources::Failed keeps the previous value and
  # marks the cells `?`.
  module Sources
    class Failed < Error; end

    def self.check!(result, what)
      raise Failed, "#{what}: #{result.error_line}" unless result.ok?

      result
    end

    def self.json(text, what)
      JSON.parse(text)
    rescue JSON::ParserError => e
      raise Failed, "#{what}: bad JSON (#{e.message.lines.first.strip})"
    end

    # The GitSafety environment for a git or gh call in any worktree of ws.
    # Without it the call must not run at all, so an unsafe repo is a failed read.
    def self.git_env(ws)
      GitSafety.env(ws)
    rescue GitSafety::Unsafe => e
      raise Failed, e.message
    end

    # Files re-read only when their mtime changed. known: name => mtime already
    # loaded. → { changed: name => [mtime, parsed], gone: [names] }; a file the
    # block parses to nil is skipped.
    def self.reread(names, known, path_of)
      changed = {}
      gone = []
      names.each do |name|
        path = path_of.(name)
        mtime = File.mtime(path)
        next if mtime == known[name]

        parsed = yield File.read(path)
        changed[name] = [mtime, parsed] unless parsed.nil?
      rescue SystemCallError
        gone << name if known.key?(name)
      end
      { changed:, gone: }
    end
  end
end
