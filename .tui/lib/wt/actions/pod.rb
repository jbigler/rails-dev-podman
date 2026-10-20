# frozen_string_literal: true

module Wt
  # Pod and worktree lifecycle (s r L c d). Every one goes through the mise task
  # that owns it; the target is the worktree the screen is about (model.focus_slug).
  module Actions
    # `mise run logs` follows these besides the services (their journal; see cmd_logs).
    LOG_SERVICES = (Service::NAMES + %w[nvim deps rustfs-init]).freeze

    # s — stop the pod when anything in it is up or coming up, otherwise start it.
    def self.toggle_pod(model)
      slug = model.focus_slug
      return pod_no_worktree(model) unless slug

      up = (model.services[slug] || []).any? { it.up? || it.state == :starting }
      return [model, Commands.mise(model, "stop", slug, "stop")] if up
      # `up` refuses stale units (podman-wt.sh require_units); offer the fix instead of the failure.
      return [model, Commands.mise(model, "up", slug, "up")] if model.stale_units.to_a.empty?

      prompt = "Installed units are out of date (#{model.stale_units.join(', ')}). Run units:install, then up #{slug}?"
      model.with(ui: model.ui.with(confirm: Confirm.new(prompt:, action: :install_units_then_up, args: [slug])))
    end

    # U — re-render the Quadlet units (`mise run units:install`, from the workspace root).
    def self.install_units(model) = [model, Commands.mise(model, "units:install", nil, "units:install")]

    def self.install_units_then_up(model, slug)
      [model, Commands::MiseChain.new(tasks: [Commands.mise(model, "units:install", nil, "units:install"),
                                              Commands.mise(model, "up", slug, "up")])]
    end

    # r — ask which service (default: the one the log panel follows).
    def self.restart_service(model)
      slug = model.focus_slug
      return pod_no_worktree(model) unless slug

      pod_prompt(model, "restart service", :restart_service_named, slug)
    end

    def self.restart_service_named(model, svc, slug)
      return pod_unknown_service(model, svc, Service::NAMES) unless Service::NAMES.include?(svc)

      [model, Commands.mise(model, "restart #{svc}", slug, "restart", svc)]
    end

    # L — ask which service, then follow it in the log panel (full tier) or hand the
    # terminal to `mise run logs` (narrower tiers, which have no log panel).
    def self.logs(model)
      slug = model.focus_slug
      return pod_no_worktree(model) unless slug

      pod_prompt(model, "logs", :logs_for, slug)
    end

    def self.logs_for(model, svc, slug)
      return pod_unknown_service(model, svc, LOG_SERVICES) unless LOG_SERVICES.include?(svc)

      svc = -svc # prompt text: the model only holds frozen strings
      ui = model.ui.with(log_service: svc)
      unless ui.tier == :full
        Terminal.handover(["mise", "run", "logs", svc], chdir: model.config.worktree_path(slug))
        return model.with(ui:)
      end

      stream = Commands::LogStream.new(config: model.config, slug:, svc:)
      old = model.log_stream
      # Same service already followed: the stream keeps itself alive, keep its lines.
      return model.with(ui:) if old == stream

      model = model.with(ui:, log_stream: stream, log_lines: [].freeze)
      return [model, stream] unless old

      # Cancel and start as two top-level dispatches (see Msg::RunCommand): Rooibos
      # can only cancel, and only honours a cancel for, a command dispatched on its own.
      [model, Rooibos::Command.batch(
        Rooibos::Command.deliver(Msg::RunCommand.new(command: Rooibos::Command.cancel(old))),
        Rooibos::Command.deliver(Msg::RunCommand.new(command: stream))
      )]
    end

    # c — `mise run wt <branch|PR#>` from the workspace root.
    def self.new_worktree(model)
      model.with(ui: model.ui.with(prompt: Prompt.new(label: "new worktree (branch or PR#)", action: :create_worktree)))
    end

    def self.create_worktree(model, name)
      [model, Commands.mise(model, "wt #{name}", nil, "wt", name, cwd: model.config.root)]
    end

    # d — `mise run wt:rm <slug>` after a confirm; the base worktree cannot be removed.
    def self.remove_worktree(model)
      slug = model.focus_slug
      return pod_no_worktree(model) unless slug
      return model.notify(-"#{slug} is the base worktree; it cannot be removed", level: :error) if model.worktree(slug)&.base

      prompt = -"Remove worktree #{slug}? Runs wt:rm (stops its pod, deletes its volumes)."
      model.with(ui: model.ui.with(confirm: Confirm.new(prompt:, action: :remove_worktree_confirmed, args: [slug].freeze)))
    end

    def self.remove_worktree_confirmed(model, slug)
      [model, Commands.mise(model, "wt:rm #{slug}", slug, "wt:rm", slug, cwd: model.config.root)]
    end

    def self.pod_prompt(model, label, action, slug)
      prompt = Prompt.new(label:, text: model.ui.log_service, action:, args: [slug].freeze)
      model.with(ui: model.ui.with(prompt:))
    end

    def self.pod_no_worktree(model) = model.notify("no worktree selected", level: :error)

    def self.pod_unknown_service(model, svc, known)
      model.notify(-"unknown service #{svc} (#{known.join(', ')})", level: :error)
    end
    private_class_method :pod_prompt, :pod_no_worktree, :pod_unknown_service
  end
end
