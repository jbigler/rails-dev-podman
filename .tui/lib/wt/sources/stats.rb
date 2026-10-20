# frozen_string_literal: true

module Wt
  module Sources
    # CPU and memory of one worktree's running containers, from
    # `podman stats --no-stream --format json` (all running containers; podman stats
    # has no name filter, so the worktree's are picked out here).
    module Stats
      # Container suffixes a worktree runs: its services plus the on-demand ones.
      # Matching a known suffix keeps slug `api` from claiming `<prefix>-api-v2-rails`.
      SUFFIXES = (Service::NAMES + %w[nvim agent deps rustfs-init]).freeze
      # units.HumanSize (decimal) and BytesSize (binary) suffixes podman prints.
      UNITS = {
        "b" => 1, "kb" => 1000, "mb" => 1000**2, "gb" => 1000**3, "tb" => 1000**4,
        "kib" => 1024, "mib" => 1024**2, "gib" => 1024**3, "tib" => 1024**4
      }.freeze

      def self.fetch(config, slug)
        r = Shell.capture(%w[podman stats --no-stream --format json], timeout: config.timeout)
        raise Error, "podman: #{r.error_line}" unless r.ok?

        Msg::StatsLoaded.new(slug:, stats: parse(r.stdout, prefix: config.prefix, slug:))
      end

      # → { container_name => Wt::Stats(cpu: Float percent, mem: Integer bytes) }
      def self.parse(json, prefix:, slug:)
        names = SUFFIXES.to_h { ["#{prefix}-#{slug}-#{it}", true] }
        rows = json.strip.empty? ? [] : JSON.parse(json)
        rows.select { names.key?(it["name"]) }
            .to_h { [it["name"], Wt::Stats.new(cpu: percent(it["cpu_percent"]), mem: bytes(it["mem_usage"]))] }
      end

      # "3.80%" → 3.8; "--" or missing → nil
      def self.percent(value) = value.to_s[/\A\s*(\d+(?:\.\d+)?)\s*%/, 1]&.to_f

      # "598.2MB / 33.4GB" → 598_200_000 (the usage half only)
      def self.bytes(value)
        m = value.to_s.split("/").first.to_s.strip.match(/\A(\d+(?:\.\d+)?)\s*([a-z]+)\z/i)
        m && UNITS[m[2].downcase] && (m[1].to_f * UNITS[m[2].downcase]).round
      end
    end
  end
end
