# frozen_string_literal: true

module RailsRuntimeInfo
  # An explicitly selected Rack callable, not application-wide middleware.
  # Construction does no I/O, requires no external libraries, and accepts nil
  # configuration so a missing ENV value cannot prevent Rails from booting.
  class BasicAuth
    DEFAULT_REALM = "Rails Runtime Info".freeze
    MAX_HEADER_BYTES = 16 * 1024
    MAX_PATH_BYTES = 4096
    MAX_REALM_BYTES = 256
    UNAUTHORIZED_JSON = "{\"error\":\"unauthorized\"}\n".freeze
    UNAVAILABLE_JSON = "{\"error\":\"authentication_unavailable\"}\n".freeze

    def initialize(app, htpasswd: nil, realm: DEFAULT_REALM)
      @app = app
      @htpasswd = nil
      @challenge = nil
      begin
        # Do not coerce Pathname, Proc or other objects through arbitrary hooks.
        if htpasswd.instance_of?(String) && htpasswd.bytesize <= MAX_PATH_BYTES &&
            !htpasswd.empty? && !/\A\s*\z/n.match(htpasswd.b) && !/[\x00-\x1f\x7f]/n.match(htpasswd.b) &&
            realm.instance_of?(String) && !realm.empty? && realm.bytesize <= MAX_REALM_BYTES &&
            /\A[\x20-\x7e]+\z/n.match(realm.b)
          @htpasswd = String.new(htpasswd).freeze
          escaped = realm.gsub(/["\\]/) { |character| "\\" + character }
          @challenge = ("Basic realm=\"" + escaped + "\"").freeze
        end
      rescue StandardError, NotImplementedError
        @htpasswd = nil
        @challenge = nil
      end
      # Shared across requests, but only contains immutable route configuration.
      freeze
    end

    def call(env)
      status = authentication_status(env)
      return @app.call(env) if status == 200
      rejection(env, status)
    end

    private

    def authentication_status(env)
      return 503 unless @htpasswd && @challenge
      credentials = decode_credentials(env["HTTP_AUTHORIZATION"])
      return 401 unless credentials
      Htpasswd.verify(@htpasswd, credentials[0], credentials[1]) ? 200 : 401
    rescue StandardError, LoadError, NotImplementedError
      # Never downgrade to unauthenticated access, log secrets, expose exception
      # details, or swallow fatal exceptions. This frame returns before the
      # diagnostic app runs: parsed credentials/file contents are not retained.
      503
    end

    def decode_credentials(header)
      return nil unless header.instance_of?(String) && header.bytesize <= MAX_HEADER_BYTES
      match = /\ABasic +([A-Za-z0-9+\/]+={0,2})[ \t]*\z/in.match(header.b)
      return nil unless match
      decoded = match[1].unpack("m0").first
      return nil if /[\x00-\x1f\x7f]/n.match(decoded)
      username, password = decoded.split(":", 2)
      return nil unless username && !username.empty? && password && !password.empty?
      [username, password]
    rescue ArgumentError
      nil
    end

    def rejection(env, status)
      json = status == 401 ? UNAUTHORIZED_JSON : UNAVAILABLE_JSON
      headers = {
        "content-type" => "application/json; charset=utf-8",
        "content-length" => json.bytesize.to_s,
        "cache-control" => "no-store",
        "x-content-type-options" => "nosniff"
      }
      headers["www-authenticate"] = @challenge if status == 401
      head = env.kind_of?(Hash) && env["REQUEST_METHOD"] == "HEAD"
      [status, headers, Body.new(head ? nil : json)]
    end
  end
end
