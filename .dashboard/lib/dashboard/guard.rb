# frozen_string_literal: true

module Dashboard
  # Rack middleware for the spec's Security rules. Every request must carry an
  # allowed Host (stops DNS rebinding); a POST must also come from an allowed
  # Origin with the page's token (stops other pages in the browser). A page
  # from before a restart holds an old token: its 403 says reload.
  class Guard
    def initialize(app, port:, token:)
      @app = app
      @token = token
      @hosts = ["wt.localhost:#{port}", "localhost:#{port}", "127.0.0.1:#{port}"].freeze
      @origins = @hosts.map { "http://#{it}" }.freeze
    end

    def call(env)
      return deny("forbidden host") unless @hosts.include?(env["HTTP_HOST"])
      return @app.call(env) unless env["REQUEST_METHOD"] == "POST"
      return deny("forbidden origin") unless @origins.include?(env["HTTP_ORIGIN"])
      return deny("stale token", "x-dashboard-reload" => "1") unless token?(env["HTTP_X_DASHBOARD_TOKEN"])

      @app.call(env)
    end

    private

    def token?(given) = given.is_a?(String) && Rack::Utils.secure_compare(given, @token)

    def deny(reason, headers = {})
      [403, { "content-type" => "text/plain", **headers }, [reason]]
    end
  end
end
