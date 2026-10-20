# frozen_string_literal: true

module Wt
  # One service of a worktree's pod, merged from its systemd unit and its container.
  #   state: :running | :healthy | :starting | :stopped | :failed | :exited
  class Service < Data.define(:name, :unit, :state, :detail, :port, :cpu, :mem, :started_at)
    NAMES = %w[rails db redis rustfs playwright].freeze
    # Display label: the db unit is postgres to a person reading the pod panel.
    LABELS = { "db" => "postgres" }.freeze

    def initialize(name:, unit: nil, state: :stopped, detail: nil, port: nil, cpu: nil, mem: nil, started_at: nil)
      super
    end

    def label = LABELS.fetch(name, name)
    def up? = %i[running healthy].include?(state)
  end

  # `podman stats` for one container.
  Stats = Data.define(:cpu, :mem)

  # nvim server state from --remote-expr. ui_count nil means the port refused.
  class NvimStatus < Data.define(:running, :ui_count, :buffers, :modified, :file, :line)
    def initialize(running: false, ui_count: 0, buffers: 0, modified: 0, file: nil, line: nil)
      super
    end
  end
end
