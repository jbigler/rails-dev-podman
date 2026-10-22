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
