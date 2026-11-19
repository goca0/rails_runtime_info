# frozen_string_literal: true

require "test_helper"

class AuthLifecycleTest < Minitest::Test
  def test_route_construction_does_not_load_libraries_read_files_or_change_globals
    library = File.expand_path("../lib", __dir__)
    program = <<~RUBY
      require "rails_runtime_info"
      before_features = $LOADED_FEATURES.dup
      before_specs = Gem.loaded_specs.keys.sort
      before_env = ENV.to_h
      before_threads = Thread.list
      before_path = $LOAD_PATH.dup
      module RailsRuntimeInfo::Support
        def self.read_file(*)
          abort "file read during route construction"
        end
      end
      [nil, "", "/missing/diagnostics.htpasswd"].each do |path|
        app = RailsRuntimeInfo::Endpoint.basic_auth(htpasswd: path)
        abort "not a Rack callable" unless app.respond_to?(:call)
        abort "wrapper not frozen" unless app.frozen?
      end
      abort "external library loaded" unless $LOADED_FEATURES == before_features
      abort "gems activated" unless Gem.loaded_specs.keys.sort == before_specs
      abort "environment changed" unless ENV.to_h == before_env
      abort "threads changed" unless Thread.list == before_threads
      abort "load path changed" unless $LOAD_PATH == before_path
      abort "Rack/Rails loaded" if defined?(Rack) || defined?(Rails)
      puts "ok"
    RUBY
    output, error, status = Open3.capture3(RbConfig.ruby, "-I", library, "-e", program)
    assert status.success?, error + output
    assert_equal "ok\n", output
  end

  def test_missing_credentials_do_not_load_authentication_or_diagnostic_libraries
    library = File.expand_path("../lib", __dir__)
    program = <<~'RUBY'
      require "rails_runtime_info"
      before = $LOADED_FEATURES.dup
      app = RailsRuntimeInfo::Endpoint.basic_auth(htpasswd: "/missing/never-opened")
      status, headers, body = app.call("REQUEST_METHOD" => "GET")
      abort "expected 401" unless status == 401
      body.close
      abort "additional libraries loaded" unless $LOADED_FEATURES == before
      puts "ok"
    RUBY
    output, error, status = Open3.capture3(RbConfig.ruby, "-I", library, "-e", program)
    assert status.success?, error + output
    assert_equal "ok\n", output
  end

  def test_first_concurrent_password_checks_load_digest_safely_without_rack_or_rails
    library = File.expand_path("../lib", __dir__)
    Dir.mktmpdir("rails-runtime-auth-first-") do |directory|
      path = File.join(directory, "passwords")
      File.write(path, "alice:{SSHA}7f5oxwoLw9l/oUGGRBiKWy6vhH0Ac2FsdP8=\nbob:{PLAIN}second-pass\n")
      program = <<~'RUBY'
        require "rails_runtime_info"
        abort "Digest already loaded" if defined?(Digest)
        path = ARGV.fetch(0)
        gate = Queue.new
        app = RailsRuntimeInfo::BasicAuth.new(lambda { |_| [204, {}, []] }, htpasswd: path)
        threads = 12.times.map do |i|
          Thread.new do
            gate.pop
            credentials = i.even? ? "alice:sample-pass" : "bob:second-pass"
            app.call("HTTP_AUTHORIZATION" => "Basic " + [credentials].pack("m0"))[0]
          end
        end
        12.times { gate << true }
        abort "concurrent check failed" unless threads.map(&:value) == [204] * 12
        abort "framework loaded" if defined?(Rack) || defined?(Rails)
        puts "ok"
      RUBY
      output, error, status = Open3.capture3(RbConfig.ruby, "-I", library, "-e", program, path)
      assert status.success?, error + output
      assert_equal "ok\n", output
    end
  end

  def auth_response_with_weak_references(app, allow)
    content_ref = nil
    reader = proc do |*_|
      text = String.new("alice:{PLAIN}sample-pass\n")
      content_ref = WeakRef.new(text)
      text
    end
    env = what_env("-all", "", "HTTP_AUTHORIZATION" => "Basic " + [allow ? "alice:sample-pass" : "alice:bad"].pack("m0"))
    env_ref = WeakRef.new(env)
    response = RailsRuntimeInfo::Support.stub(:read_file, reader) { app.call(env) }
    [response, env_ref, content_ref]
  end

  def test_wrapper_and_response_do_not_retain_request_or_password_file_contents
    app = RailsRuntimeInfo::Endpoint.basic_auth(htpasswd: "/fixture/not-read")
    [true, false].each do |allow|
      response, env_ref, content_ref = Thread.new { auth_response_with_weak_references(app, allow) }.value
      # TEST-ONLY forced GC, never performed by the authentication implementation.
      3.times { GC.start }
      refute env_ref.weakref_alive?
      refute content_ref.weakref_alive?
      assert_equal(allow ? 200 : 401, response[0])
      response.last.close
      assert_nil response.last.instance_variable_get(:@content)
    end
  end

  def test_ordinary_authentication_failures_do_not_log_exception_details
    app = RailsRuntimeInfo::Endpoint.basic_auth(htpasswd: "/fixture/not-read")
    env = rack_env("", "HTTP_AUTHORIZATION" => "Basic " + ["alice:pass"].pack("m0"))
    output, error = capture_io do
      RailsRuntimeInfo::Htpasswd.stub(:verify, proc { |*_| raise IOError, "synthetic-secret" }) do
        response = app.call(env)
        assert_equal 503, response[0]
        response.last.close
      end
    end
    assert_equal "", output
    assert_equal "", error
    assert_equal "", env["rack.errors"].string
  end
end
