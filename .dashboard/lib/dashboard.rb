# frozen_string_literal: true

require "json"
require "time"
require "open3"

module Dashboard
  # Base of every error the dashboard raises on purpose.
  class Error < StandardError; end
end

require_relative "dashboard/shell"
require_relative "dashboard/git_safety"
require_relative "dashboard/model"
require_relative "dashboard/workspace"
require_relative "dashboard/sources"
require_relative "dashboard/sources/git"
require_relative "dashboard/sources/local"
require_relative "dashboard/sources/gh"
require_relative "dashboard/sources/tasks"
require_relative "dashboard/services"
require_relative "dashboard/agent_status"
require_relative "dashboard/derive"
require_relative "dashboard/schedule"
require_relative "dashboard/hub"
require_relative "dashboard/pollers"
require_relative "dashboard/session_env"
require_relative "dashboard/actions"
require_relative "dashboard/runner"
require_relative "dashboard/render"
require_relative "dashboard/render/view"
require_relative "dashboard/streams"
require_relative "dashboard/guard"
require_relative "dashboard/app"
