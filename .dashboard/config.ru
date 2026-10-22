# frozen_string_literal: true

require_relative "lib/dashboard"

# Dashboard::App.boot replaces this once the web app exists.
run ->(_env) { [200, {}, ["ok"]] }
