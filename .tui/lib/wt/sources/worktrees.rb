# frozen_string_literal: true

module Wt
  module Sources
    # `git worktree list --porcelain` from the base worktree, joined with
    # ports.registry (`slug:WORKTREE_ID`). Lists every worktree git knows,
    # like .scripts/list-worktrees.sh does, base first.
    module Worktrees
      def self.fetch(config)
        raise Error, "no base worktree under #{config.root}" unless config.base_path

        res = Shell.capture(["git", "-C", config.base_path, "worktree", "list", "--porcelain"], timeout: config.timeout)
        raise Error, "git worktree list: #{res.error_line}" unless res.ok?

        registry = File.file?(config.registry_path) ? File.read(config.registry_path) : ""
        Msg::WorktreesLoaded.new(worktrees: Ractor.make_shareable(parse(res.stdout, registry, root: config.root)))
      end

      # porcelain: blank-line separated records; the first record is the main
      # worktree (the one holding .git). Returns [Worktree], base first.
      def self.parse(porcelain, registry_text, root:)
        ids = parse_registry(registry_text)
        records = porcelain.split(/\n{2,}/).map { it.lines.map(&:chomp).reject(&:empty?) }.reject(&:empty?)
        records.each_with_index.filter_map do |lines, i|
          path = lines.find { it.start_with?("worktree ") }&.delete_prefix("worktree ")
          next unless path

          attrs = lines.to_h { |l| k, v = l.split(" ", 2); [k, v] }
          slug = File.basename(path)
          Worktree.new(
            slug:, path:, id: ids[slug], base: i.zero?,
            branch: attrs["branch"]&.delete_prefix("refs/heads/"),
            head: attrs["HEAD"]&.[](0, 7),
            detached: attrs.key?("detached"),
            prunable: attrs.key?("prunable")
          )
        end
      end

      def self.parse_registry(text)
        text.each_line.filter_map do |line|
          slug, id = line.strip.split(":", 2)
          [slug, Integer(id, 10)] if slug && !slug.empty? && id&.match?(/\A\d+\z/)
        end.to_h
      end
    end
  end
end
