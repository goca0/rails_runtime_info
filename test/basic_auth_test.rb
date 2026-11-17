# frozen_string_literal: true

require "test_helper"

class BasicAuthTest < Minitest::Test
  AUTH = RailsRuntimeInfo::BasicAuth
  SSHA = "{SSHA}7f5oxwoLw9l/oUGGRBiKWy6vhH0Ac2FsdP8=".freeze

  def setup
    @directory = Dir.mktmpdir("rails-runtime-auth-test-")
    @path = File.join(@directory, "diagnostics.htpasswd")
    File.binwrite(@path, "alice:#{SSHA}\nbob:{PLAIN}second-pass\n")
    @app = RailsRuntimeInfo::Endpoint.basic_auth(htpasswd: @path)
  end

  def teardown
    FileUtils.remove_entry(@directory)
  end

  def authorization(user = "alice", password = "sample-pass")
    "Basic " + [user.b + ":" + password.b].pack("m0")
  end

  def auth_env(header = authorization, overrides = {})
    what_env("-all,request.headers", "unread-body", { "HTTP_AUTHORIZATION" => header }.merge(overrides))
  end

  def call_app(env = auth_env, app = @app)
    status, headers, body = app.call(env)
    text = String.new
    begin
      body.each { |chunk| text << chunk }
    ensure
      body.close
    end
    [status, headers, text.empty? ? nil : JSON.parse(text), text]
  end

  def test_factory_returns_immutable_route_callable
    assert_instance_of AUTH, @app
    assert @app.frozen?
    assert @app.instance_variable_get(:@htpasswd).frozen?
    assert @app.instance_variable_get(:@challenge).frozen?
    assert_same RailsRuntimeInfo::Endpoint, @app.instance_variable_get(:@app)
  end

  def test_ssha_authentication_and_authorization_echo
    env = auth_env
    status, headers, data = call_app(env)
    assert_equal 200, status
    assert_equal authorization, data.fetch("request").fetch("headers").fetch("Authorization")
    assert_equal "no-store", headers["cache-control"]
    refute headers.key?("www-authenticate")
    assert_equal 0, env["rack.input"].pos
  end

  def test_plain_authentication_and_multiple_users
    assert_equal 200, call_app(auth_env(authorization("bob", "second-pass")))[0]
    assert_equal 401, call_app(auth_env(authorization("bob", "sample-pass")))[0]
    assert_equal 401, call_app(auth_env(authorization("alice", "second-pass")))[0]
    assert_equal 401, call_app(auth_env(authorization("Alice", "sample-pass")))[0]
  end

  def test_missing_wrong_and_unknown_credentials_have_same_401
    expected = [401, { "error" => "unauthorized" }]
    [nil, authorization("alice", "incorrect"), authorization("unknown", "sample-pass")].each do |header|
      status, headers, data, text = call_app(auth_env(header))
      assert_equal expected, [status, data]
      assert_equal 'Basic realm="Rails Runtime Info"', headers["www-authenticate"]
      assert_equal "no-store", headers["cache-control"]
      assert_equal "nosniff", headers["x-content-type-options"]
      assert_equal text.bytesize.to_s, headers["content-length"]
      refute_includes text, "incorrect"
    end
  end

  def test_case_insensitive_scheme_and_optional_http_whitespace
    header = authorization.sub("Basic ", "bAsIc   ") + " \t"
    assert_equal 200, call_app(auth_env(header))[0]
  end

  def test_malformed_authorization_is_rejected_without_reading_a_file
    invalid = ["", "Bearer token", "Basic", "Basic ", "Basic!!!!", "Basic !!!!", "Basic YQ", "Basic YQ=", "Basic YR==", authorization + "junk", authorization + ", Basic abc", authorization + "\r\nX: foo", "Basic\t" + ["alice:sample-pass"].pack("m0"), [authorization], Object.new, "\xff".b]
    RailsRuntimeInfo::Support.stub(:read_file, proc { |*_| flunk "unexpected file read" }) do
      invalid.each { |header| assert_equal 401, call_app(auth_env(header))[0] }
    end
  end

  def test_empty_credentials_missing_colon_and_control_bytes_are_rejected
    ["", "alice", ":sample-pass", "alice:", "alice:sample-pass\x00", "alice:pass\tword", "alice\r:sample-pass", "alice:pass\x7fword"].each do |value|
      assert_equal 401, call_app(auth_env("Basic " + [value].pack("m0")))[0]
    end
  end

  def test_header_size_limit_is_inclusive
    maximum = AUTH::MAX_HEADER_BYTES
    header = authorization + " " * (maximum - authorization.bytesize)
    assert_equal 200, call_app(auth_env(header))[0]
    RailsRuntimeInfo::Support.stub(:read_file, proc { |*_| flunk "oversized header read the file" }) do
      assert_equal 401, call_app(auth_env(header + " "))[0]
    end
  end

  def test_only_authorization_header_is_used
    env = auth_env(nil, "REMOTE_USER" => "alice", "HTTP_PROXY_AUTHORIZATION" => authorization, "X-HTTP_AUTHORIZATION" => authorization, "HTTP_X_AUTHORIZATION" => authorization)
    assert_equal 401, call_app(env)[0]
  end

  def test_head_requires_authentication_and_has_no_response_body
    [nil, authorization, authorization("alice", "bad")].each do |header|
      status, headers, data, text = call_app(auth_env(header, "REQUEST_METHOD" => "HEAD"))
      assert_equal(header == authorization ? 200 : 401, status)
      assert_nil data
      assert_equal "", text
      assert_operator headers["content-length"].to_i, :>, 0
    end
    missing = RailsRuntimeInfo::Endpoint.basic_auth(htpasswd: nil)
    status, _, _, text = call_app(auth_env(nil, "REQUEST_METHOD" => "HEAD"), missing)
    assert_equal 503, status
    assert_equal "", text
  end

  def test_other_methods_do_not_bypass_authentication
    %w[GET POST PUT DELETE PATCH OPTIONS TRACE].each do |method|
      assert_equal 401, call_app(auth_env(nil, "REQUEST_METHOD" => method))[0]
      assert_equal 200, call_app(auth_env(authorization, "REQUEST_METHOD" => method))[0]
    end
  end

  def test_missing_env_value_does_not_raise_during_route_setup_or_open_access
    with_environment("RAILS_RUNTIME_INFO_HTPASSWD" => nil) do
      app = nil
      RailsRuntimeInfo::Support.stub(:read_file, proc { |*_| flunk "boot-time file read" }) do
        app = RailsRuntimeInfo::Endpoint.basic_auth(htpasswd: ENV["RAILS_RUNTIME_INFO_HTPASSWD"])
      end
      assert_equal 503, call_app(auth_env, app)[0]
      assert_equal 503, call_app(auth_env(nil), app)[0]
    end
  end

  def test_absent_or_invalid_configuration_stays_closed
    [nil, "", " \t ", false, 123, Object.new, "path\x00suffix", "path\nsuffix", "x" * (AUTH::MAX_PATH_BYTES + 1)].each do |path|
      app = RailsRuntimeInfo::Endpoint.basic_auth(htpasswd: path)
      status, headers, data = call_app(auth_env, app)
      assert_equal 503, status
      assert_equal({ "error" => "authentication_unavailable" }, data)
      refute headers.key?("www-authenticate")
    end
    assert_equal 503, call_app(auth_env, RailsRuntimeInfo::Endpoint.basic_auth)[0]
  end

  def test_missing_file_is_not_read_at_construction_and_can_be_created_later
    File.unlink(@path)
    app = RailsRuntimeInfo::Endpoint.basic_auth(htpasswd: @path)
    assert_equal 503, call_app(auth_env, app)[0]
    File.write(@path, "alice:{PLAIN}sample-pass")
    assert_equal 200, call_app(auth_env, app)[0]
  end

  def test_password_file_is_reloaded_and_atomic_replacement_takes_effect
    assert_equal 200, call_app[0]
    replacement = File.join(@directory, "next.htpasswd")
    File.write(replacement, "alice:{PLAIN}new-pass")
    File.rename(replacement, @path)
    assert_equal 401, call_app[0]
    assert_equal 200, call_app(auth_env(authorization("alice", "new-pass")))[0]
    File.unlink(@path)
    assert_equal 503, call_app[0]
  end

  def test_corrupt_unsupported_duplicate_and_empty_files_fail_closed
    ["", "# no users", "alice:{PLAIN}sample-pass\nbroken-line", "alice:{PLAIN}sample-pass\nalice:{PLAIN}other", "alice:{PLAIN}sample-pass\nbob:$apr1$unsupported", "alice:{SSHA}garbage"].each do |data|
      File.binwrite(@path, data)
      status, _, body = call_app
      assert_equal 503, status
      assert_equal({ "error" => "authentication_unavailable" }, body)
    end
  end

  def test_file_size_limit_is_inclusive_and_oversize_is_not_truncated_into_success
    prefix = "alice:{PLAIN}sample-pass\n#"
    File.write(@path, prefix + "x" * (RailsRuntimeInfo::Htpasswd::MAX_FILE_BYTES - prefix.bytesize))
    assert_equal 200, call_app[0]
    File.open(@path, "a") { |file| file.write("x") }
    assert_equal 503, call_app[0]
  end

  def test_nonregular_file_is_rejected
    File.unlink(@path)
    Dir.mkdir(@path)
    assert_equal 503, call_app[0]
  end

  def test_fifo_is_rejected_without_waiting_for_a_writer
    return unless File.respond_to?(:mkfifo)
    File.unlink(@path)
    File.mkfifo(@path, 0600)
    assert_equal 503, call_app[0]
  end

  def test_ordinary_verifier_failures_never_expose_details
    [Errno::EACCES.new("private-path"), IOError.new("private-data"), LoadError.new("private-dependency"), NotImplementedError.new("private-implementation")].each do |error|
      RailsRuntimeInfo::Htpasswd.stub(:verify, proc { |*_| raise error }) do
        status, _, _, text = call_app
        assert_equal 503, status
        assert_equal AUTH::UNAVAILABLE_JSON, text
        refute_includes text, "private"
      end
    end
  end

  def test_digest_library_failure_fails_closed
    File.write(@path, "alice:{PLAIN}sample-pass")
    implementation = proc { |*_| raise LoadError, "missing digest dependency" }
    with_instance_method(Kernel, :require, implementation) do
      assert_equal 503, call_app[0]
    end
  end

  def test_fatal_verifier_errors_propagate
    [SystemExit.new(17), NoMemoryError.new("simulated"), Interrupt.new].each do |error|
      RailsRuntimeInfo::Htpasswd.stub(:verify, proc { |*_| raise error }) do
        assert_raises(error.class) { @app.call(auth_env) }
      end
    end
  end

  def test_rejections_do_not_collect_parse_what_or_read_the_request_body
    invalid_what = "what=not-a-category"
    reader = Object.new
    def reader.read(*); raise "body must not be read"; end
    RailsRuntimeInfo::Endpoint.stub(:call, proc { |*_| flunk "endpoint invoked before authentication" }) do
      assert_equal 401, call_app(auth_env(nil, "QUERY_STRING" => invalid_what, "rack.input" => reader))[0]
      File.unlink(@path)
      assert_equal 503, call_app(auth_env(authorization, "QUERY_STRING" => invalid_what, "rack.input" => reader))[0]
    end
  end

  def test_authenticated_request_keeps_existing_selection_and_errors
    assert_equal 400, call_app(auth_env(authorization, "QUERY_STRING" => "what=not-a-category"))[0]
    env = auth_env(authorization, "QUERY_STRING" => "what=-all,request.body")
    status, _, data = call_app(env)
    assert_equal 200, status
    assert_equal "unread-body", data.fetch("request").fetch("body").fetch("data")
  end

  def test_authentication_itself_does_not_mutate_even_a_frozen_request
    env = auth_env(authorization, "REMOTE_USER" => "already-present")
    before = env.dup
    env.freeze
    RailsRuntimeInfo::Endpoint.stub(:call, proc { |actual| assert_same env, actual; [204, {}, []] }) do
      assert_equal 204, @app.call(env)[0]
    end
    assert_equal before, env
    assert_equal "already-present", env["REMOTE_USER"]
    assert_equal 0, env["rack.input"].pos
  end

  def test_original_authorization_survives_rack_environment_projection
    env = auth_env(authorization, "QUERY_STRING" => "what=-all,request.rack_environment.HTTP_AUTHORIZATION")
    status, _, data = call_app(env)
    assert_equal 200, status
    assert_equal authorization, data.fetch("request").fetch("rack_environment").fetch("HTTP_AUTHORIZATION")
  end

  def test_configuration_is_copied_and_realm_is_escaped
    path = @path.dup
    realm = 'Inspect "app" \\ node'.dup
    app = RailsRuntimeInfo::Endpoint.basic_auth(htpasswd: path, realm: realm)
    path.replace("/no-longer-valid")
    realm.replace("modified")
    assert_equal 200, call_app(auth_env, app)[0]
    assert_equal 'Basic realm="Inspect \\"app\\" \\\\ node"', call_app(auth_env(nil), app)[1]["www-authenticate"]
  end

  def test_invalid_realm_fails_closed_without_header_injection
    [nil, "", "\r\nX-Evil: 1", "non-ascii\xff".b, "x" * (AUTH::MAX_REALM_BYTES + 1), Object.new].each do |realm|
      app = RailsRuntimeInfo::Endpoint.basic_auth(htpasswd: @path, realm: realm)
      status, headers, _ = call_app(auth_env(nil), app)
      assert_equal 503, status
      refute headers.key?("www-authenticate")
    end
  end

  def test_environment_path_is_captured_when_route_is_defined
    with_environment("RAILS_RUNTIME_INFO_HTPASSWD" => @path) do
      app = RailsRuntimeInfo::Endpoint.basic_auth(htpasswd: ENV["RAILS_RUNTIME_INFO_HTPASSWD"])
      ENV.delete("RAILS_RUNTIME_INFO_HTPASSWD")
      assert_equal 200, call_app(auth_env, app)[0]
    end
  end

  def test_bare_endpoint_remains_unprotected_and_does_not_read_password_files
    RailsRuntimeInfo::Htpasswd.stub(:verify, proc { |*_| flunk "authentication enabled globally" }) do
      assert_equal 200, response(what_env("-all"))[0]
    end
  end

  def test_rejection_body_retains_only_static_json_and_releases_on_close
    _, _, body = @app.call(auth_env(nil))
    assert_equal [:@content], body.instance_variables
    assert_equal AUTH::UNAUTHORIZED_JSON, body.instance_variable_get(:@content)
    body.close
    assert_nil body.instance_variable_get(:@content)
  end

  def test_concurrent_requests_do_not_share_credentials_or_results
    expected = []
    workers = 12.times.map do |index|
      good = index % 3 != 0
      user, password = index.even? ? ["alice", "sample-pass"] : ["bob", "second-pass"]
      password = "incorrect" unless good
      expected << (good ? 200 : 401)
      Thread.new { call_app(auth_env(authorization(user, password)))[0] }
    end
    assert_equal expected, workers.map(&:value)
    assert_equal [:@app, :@challenge, :@htpasswd], @app.instance_variables.sort
    assert_equal [], RailsRuntimeInfo::Htpasswd.instance_variables
    assert_equal [], RailsRuntimeInfo::BasicAuth.instance_variables
  end
end
