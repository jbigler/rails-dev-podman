# frozen_string_literal: true

module Dashboard
  # The environment every child starts from: the dashboard's own as it was
  # before Bundler set itself up (no BUNDLE_*, no RUBYOPT -rbundler/setup, no
  # GEM_HOME of the dashboard's vendor bundle), captured once at boot. Children
  # get it whole (unsetenv_others), so a host Ruby a child runs never loads the
  # dashboard's bundle.
  module ChildEnv
    def self.base = @base ||= (defined?(Bundler) ? Bundler.unbundled_env : ENV.to_h).freeze

    # → base with extra on top (a nil value unsets).
    def self.with(extra) = base.merge(extra)
  end
end
