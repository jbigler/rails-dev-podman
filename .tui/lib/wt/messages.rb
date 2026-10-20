# frozen_string_literal: true

module Wt
  # wt's own messages. Each is a Data value that knows how to fold itself into the
  # model: `apply(model)` returns a Model or [Model, command]. Update dispatches
  # here for anything including this module; RatatuiRuby events go to Keys.
  module Message
    include Rooibos::Message::Predicates
  end

  module Msg
    # Emitted by Commands::Ticker. kind: :fast (2 s) | :slow (5 s) | :gh (60 s)
    class Tick < Data.define(:kind, :at)
      include Message
      def apply(model) = Refresh.on_tick(model.with(now: at), kind)
    end

    # Wraps whatever a Commands::Fetch produced, so the inflight key is cleared
    # whether the source succeeded or failed.
    class Fetched < Data.define(:key, :message)
      include Message
      def apply(model)
        model = model.with(inflight: model.inflight - [key], failures: model.failures.except(key))
        message.apply(model)
      end
    end

    # A source call failed or timed out. The view dims that cell with `?`.
    class SourceFailed < Data.define(:key, :error)
      include Message
      def apply(model) = model.with(failures: model.failures.merge(key => error))
    end

    # A mise action finished. Failures surface the task's stderr as an error toast.
    class CommandFinished < Data.define(:label, :slug, :status, :stderr, :refresh)
      include Message
      def apply(model)
        text = status == 0 ? "#{label}: done" : "#{label}: #{stderr_line}"
        model, id = model.with(busy: model.busy.except(slug)).toast(text, level: status == 0 ? :info : :error)
        model, refresh_cmd = refresh ? Refresh.all(model) : [model, nil]
        [model, Rooibos::Command.batch(*[Commands.expire_toast(id), refresh_cmd].compact)]
      end

      def stderr_line = Shell.error_line(stderr) || "exit #{status}"
    end

    class ToastExpired < Data.define(:id)
      include Message
      def apply(model) = model.with(ui: model.ui.with(toasts: model.ui.toasts.reject { it.id == id }))
    end

    # --- sources ------------------------------------------------------------

    class WorktreesLoaded < Data.define(:worktrees)
      include Message
      def apply(model)
        first = model.worktrees.empty?
        selected = model.ui.selected
        selected = worktrees.first&.slug unless worktrees.any? { it.slug == selected }
        model = model.with(worktrees:, ui: model.ui.with(selected:))
        first ? Refresh.all(model) : model
      end
    end

    class GitStatusLoaded < Data.define(:slug, :status)
      include Message
      def apply(model) = model.put(:git, slug, status)
    end

    # services: slug => [Service] for every worktree in one podman/systemctl pass.
    class UnitsChanged < Data.define(:services)
      include Message
      def apply(model) = model.with(services: model.services.merge(services))
    end

    class StatsLoaded < Data.define(:slug, :stats)
      include Message
      def apply(model) = model.put(:stats, slug, stats)
    end

    # pr: PrStatus, or :none when the branch has no PR.
    class PrLoaded < Data.define(:slug, :pr, :at)
      include Message
      def apply(model) = model.put(:prs, slug, pr).with(gh_at: at)
    end

    class StackLoaded < Data.define(:slug, :stack)
      include Message
      def apply(model) = model.put(:stacks, slug, stack)
    end

    # statuses: slug => AgentStatus for every status file present.
    class StatusFiles < Data.define(:statuses)
      include Message
      def apply(model) = model.with(agents: statuses)
    end

    class NvimLoaded < Data.define(:slug, :status)
      include Message
      def apply(model) = model.put(:nvim, slug, status)
    end

    # A batch of lines from the LogStream for slug/svc. Batches from a stream that has
    # since been replaced (sent just before its cancel landed) are dropped.
    class LogLines < Data.define(:slug, :svc, :lines)
      include Message
      def apply(model)
        s = model.log_stream
        return model unless s && s.slug == slug && s.svc == svc

        model.with(log_lines: (model.log_lines + lines).last(500))
      end
    end
  end
end
