# frozen_string_literal: true

module Dashboard
  module Sources
    # `mise tasks --json` for the palette (§9.5).
    module Tasks
      def self.fetch(path)
        r = Sources.check!(Shell.run(%w[mise tasks --json], chdir: path), "mise tasks")
        parse(r.stdout)
      end

      def self.parse(text)
        Sources.json(text, "mise tasks").reject { it["hide"] }.map do |t|
          MiseTask.new(name: t["name"], aliases: Array(t["aliases"]), description: t["description"].to_s, usage: t["usage"].to_s)
        end
      end

      # :required for `arg "<x>"`, :optional for `arg "[x]…"`, nil when it takes none.
      def self.args(usage)
        names = usage.scan(/\barg\s+"([^"]+)"/).flatten
        return nil if names.empty?

        names.any? { it.start_with?("<") } ? :required : :optional
      end
    end
  end
end
