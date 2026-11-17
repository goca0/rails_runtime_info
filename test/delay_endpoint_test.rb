# frozen_string_literal: true

require "test_helper"
require "timeout" # Tests only; the implementation never interrupts threads.

class DelayEndpointTest < Minitest::Test
  def query_env(query, overrides = {})
    rack_env("unread-body", { "QUERY_STRING" => query }.merge(overrides))
  end

  def call_app(app, env)
    status, headers, body = app.call(env)
    text = String.new
    begin
      body.each { |chunk| text << chunk }
    ensure
      body.close
    end
    [status, headers, text.empty? ? nil : JSON.parse(text), text]
  end

  def authorization
    "Basic " + ["alice:sample-pass"].pack("m0")
  end

  def with_auth_app
    Dir.mktmpdir("rails-runtime-delay-") do |directory|
      path = File.join(directory, "diagnostics.htpasswd")
      File.binwrite(path, "alice:{PLAIN}sample-pass\n")
      yield RailsRuntimeInfo::Endpoint.basic_auth(htpasswd: path)
    end
  end

  def test_absent_and_zero_delay_never_call_sleep
    forbidden = proc { |*_| flunk "unexpected sleep" }
    Kernel.stub(:sleep, forbidden) do
      ["what=-all", "what=-all&sleep=0", "what=-all&sleep=0.000"].each do |query|
        status, _, data = response(query_env(query))
        assert_equal 200, status
        assert_equal({}, data)
      end
    end
  end

  def test_sleep_once_before_snapshot_construction_and_collection
    events = []
    original_new = RailsRuntimeInfo::Snapshot.method(:new)
    constructor = proc do |env, selection|
      events << :new_snapshot
      original_new.call(env, selection)
    end
    document = proc { events << :collect; { "sampled" => "after sleep" } }
    sleeper = proc { |seconds| events << [:sleep, seconds]; 0 }
    with_instance_method(RailsRuntimeInfo::Snapshot, :document, document) do
      RailsRuntimeInfo::Snapshot.stub(:new, constructor) do
        Kernel.stub(:sleep, sleeper) do
          status, _, data = response(query_env("what=-all&sleep=0.5"))
          assert_equal 200, status
          assert_equal({ "sampled" => "after sleep" }, data)
        end
      end
    end
    assert_equal [[:sleep, 0.5], :new_snapshot, :collect], events
  end

  def test_parameters_are_both_validated_before_waiting_and_selection_is_reused
    events = []
    original_selection = RailsRuntimeInfo::Selection.method(:new)
    original_delay = RailsRuntimeInfo::RequestDelay.method(:seconds)
    selection_reader = proc { |query| events << :what; original_selection.call(query) }
    delay_reader = proc { |query| events << :sleep_parameter; original_delay.call(query) }
    RailsRuntimeInfo::Selection.stub(:new, selection_reader) do
      RailsRuntimeInfo::RequestDelay.stub(:seconds, delay_reader) do
        Kernel.stub(:sleep, proc { |seconds| events << [:wait, seconds] }) do
          assert_equal 200, response(query_env("sleep=1&what=-all"))[0]
        end
      end
    end
    assert_equal [:what, :sleep_parameter, [:wait, 1.0]], events
  end

  def test_invalid_sleep_is_400_without_waiting_collecting_or_reading_body
    forbidden = proc { |*_| flunk "invalid request must not wait or collect" }
    Kernel.stub(:sleep, forbidden) do
      RailsRuntimeInfo::Snapshot.stub(:new, forbidden) do
        ["sleep=-1", "sleep=31", "sleep=NaN", "sleep=%GG", "sleep=", "sleep=1&sleep=2"].each do |query|
          env = query_env("what=all&" + query)
          status, headers, data, text = response(env)
          assert_equal 400, status, query
          assert_equal "invalid_sleep", data["error"]
          assert_equal "no-store", headers["cache-control"]
          assert_equal text.bytesize.to_s, headers["content-length"]
          assert_equal 0, env["rack.input"].pos
        end
      end
    end
  end

  def test_invalid_what_does_not_sleep_regardless_of_query_order
    forbidden = proc { |*_| flunk "invalid what must not wait or collect" }
    Kernel.stub(:sleep, forbidden) do
      RailsRuntimeInfo::Snapshot.stub(:new, forbidden) do
        ["sleep=1&what=unknown", "what=unknown&sleep=1"].each do |query|
          status, _, data = response(query_env(query))
          assert_equal 400, status
          assert_equal "invalid_what", data["error"]
        end
      end
    end
  end

  def test_authentication_precedes_validation_wait_and_collection
    events = []
    original_verifier = RailsRuntimeInfo::Htpasswd.method(:verify)
    original_selection = RailsRuntimeInfo::Selection.method(:new)
    verifier = proc { |*args| events << :authenticate; original_verifier.call(*args) }
    selector = proc { |query| events << :validate; original_selection.call(query) }
    with_auth_app do |app|
      RailsRuntimeInfo::Htpasswd.stub(:verify, verifier) do
        RailsRuntimeInfo::Selection.stub(:new, selector) do
          Kernel.stub(:sleep, proc { |seconds| events << [:wait, seconds] }) do
            env = query_env("sleep=0.5&what=-all", "HTTP_AUTHORIZATION" => authorization)
            assert_equal 200, call_app(app, env)[0]
          end
        end
      end
    end
    assert_equal [:authenticate, :validate, [:wait, 0.5]], events
  end

  def test_unauthorized_or_unavailable_requests_do_not_parse_wait_or_collect
    forbidden = proc { |*_| flunk "authentication rejection reached the endpoint" }
    with_auth_app do |app|
      RailsRuntimeInfo::Selection.stub(:new, forbidden) do
        RailsRuntimeInfo::RequestDelay.stub(:seconds, forbidden) do
          Kernel.stub(:sleep, forbidden) do
            RailsRuntimeInfo::Snapshot.stub(:new, forbidden) do
              [nil, "Basic !!!", "Basic " + ["alice:incorrect"].pack("m0")].each do |header|
                env = query_env("sleep=30&what=unknown", "HTTP_AUTHORIZATION" => header)
                assert_equal 401, call_app(app, env)[0]
                assert_equal 0, env["rack.input"].pos
              end
              closed = RailsRuntimeInfo::Endpoint.basic_auth(htpasswd: nil)
              env = query_env("sleep=30", "HTTP_AUTHORIZATION" => authorization)
              assert_equal 503, call_app(closed, env)[0]
              assert_equal 0, env["rack.input"].pos
              unavailable = RailsRuntimeInfo::Endpoint.basic_auth(htpasswd: "/must/not/exist/diagnostics.htpasswd")
              assert_equal 503, call_app(unavailable, env)[0]
            end
          end
        end
      end
    end
  end

  def test_authenticated_invalid_query_returns_400_without_wait
    with_auth_app do |app|
      Kernel.stub(:sleep, proc { |*_| flunk "invalid query slept" }) do
        %w[sleep=31 what=unknown].each do |query|
          env = query_env(query, "HTTP_AUTHORIZATION" => authorization)
          assert_equal 400, call_app(app, env)[0]
        end
      end
    end
  end

  def test_query_is_only_input_and_body_is_not_parsed
    input = Object.new
    def input.read(*); raise "must not read body"; end
    env = query_env("what=-all", "rack.input" => input, "HTTP_SLEEP" => "30", "sleep" => 30,
                    "rack.request.form_hash" => { "sleep" => "30" })
    Kernel.stub(:sleep, proc { |*_| flunk "non-query delay" }) do
      assert_equal 200, response(env)[0]
    end
  end

  def test_no_mutation_new_response_fields_or_retained_delay_state
    env = query_env("sleep=0.5", "HTTP_AUTHORIZATION" => authorization)
    before = env.dup
    Kernel.stub(:sleep, proc { |_| 0 }) do
      status, _, data = response(env)
      assert_equal 200, status
      assert_equal %w[gem_version time_utc process server errors gc yjit runtime application request], data.keys
      refute data["request"].key?("sleep_seconds")
      assert_equal "sleep=0.5", data["request"]["metadata"]["QUERY_STRING"]
      assert_equal authorization, data["request"]["headers"]["Authorization"]
    end
    assert_equal before, env
    assert_equal 0, env["rack.input"].pos
    assert_equal [], RailsRuntimeInfo::Endpoint.instance_variables
    assert_equal [], RailsRuntimeInfo::RequestDelay.instance_variables
  end

  def test_opt_in_body_is_collected_only_after_waiting
    env = query_env("sleep=1&what=-all,request.body")
    sleeper = proc { |_| assert_equal 0, env["rack.input"].pos }
    Kernel.stub(:sleep, sleeper) do
      status, _, data = response(env)
      assert_equal 200, status
      assert_equal "unread-body", data["request"]["body"]["data"]
    end
  end

  def test_maximum_delay_is_passed_once_and_never_repeated_during_body_enumeration
    calls = []
    Kernel.stub(:sleep, proc { |seconds| calls << seconds }) do
      status, _, body = RailsRuntimeInfo::Endpoint.call(query_env("what=-all&sleep=30"))
      assert_equal 200, status
      assert_equal [30.0], calls
      2.times { body.each { |chunk| assert_instance_of String, chunk } }
      body.close
      assert_equal [30.0], calls
    end
  end

  def test_head_and_other_methods_obey_delay
    calls = []
    Kernel.stub(:sleep, proc { |seconds| calls << seconds }) do
      %w[GET POST PUT PATCH DELETE OPTIONS HEAD].each do |method|
        status, headers, data, text = response(query_env("sleep=0.5&what=-all", "REQUEST_METHOD" => method))
        assert_equal 200, status, method
        assert_operator headers["content-length"].to_i, :>, 0
        if method == "HEAD"
          assert_nil data
          assert_equal "", text
        else
          assert_equal({}, data)
        end
      end
    end
    assert_equal Array.new(7, 0.5), calls
  end

  def test_ordinary_sleep_failure_uses_existing_500_boundary_without_collecting
    RailsRuntimeInfo::Snapshot.stub(:new, proc { |*_| flunk "collected after failed sleep" }) do
      Kernel.stub(:sleep, proc { |_| raise IOError, "synthetic failure" }) do
        status, _, _, text = response(query_env("sleep=1"))
        assert_equal 500, status
        assert_equal RailsRuntimeInfo::Endpoint::FALLBACK_JSON, text
      end
    end
  end

  def test_fatal_exceptions_during_sleep_propagate
    [NoMemoryError, SystemExit, Interrupt].each do |type|
      Kernel.stub(:sleep, proc { |_| raise type }) do
        assert_raises(type) { RailsRuntimeInfo::Endpoint.call(query_env("sleep=1")) }
      end
    end
  end

  def test_real_fractional_sleep_precedes_timestamp_sampling
    seconds = 0.03
    started_at = Time.now.utc
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    status, _, data = response(query_env("sleep=#{seconds}&what=-all,time_utc"))
    elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started
    assert_equal 200, status
    assert_operator elapsed, :>=, seconds * 0.9
    require "time"
    assert_operator Time.iso8601(data["time_utc"]) - started_at, :>=, seconds * 0.9
  end

  def test_concurrent_authenticated_waits_are_independent_and_do_not_block_no_delay_request
    started = Queue.new
    release = Queue.new
    workers = []
    sleeper = proc { |seconds| started << seconds; release.pop; 0 }
    with_auth_app do |app|
      Kernel.stub(:sleep, sleeper) do
        begin
          [0.5, 1, 2].each_with_index do |seconds, index|
            workers << Thread.new do
              env = query_env("sleep=#{seconds}&what=-all,request.headers", "HTTP_AUTHORIZATION" => authorization,
                              "HTTP_X_MARKER" => index.to_s)
              call_app(app, env)
            end
          end
          observed = Timeout.timeout(5) { 3.times.map { started.pop } }
          assert_equal [0.5, 1.0, 2.0], observed.sort
          assert workers.all?(&:alive?)
          # Must finish while all three delayed requests remain suspended.
          immediate = query_env("what=-all", "HTTP_AUTHORIZATION" => authorization)
          assert_equal 200, Timeout.timeout(5) { call_app(app, immediate)[0] }
          3.times { release << true }
          workers.each_with_index do |worker, index|
            assert worker.join(5), "delayed worker did not finish"
            status, _, data = worker.value
            assert_equal 200, status
            assert_equal index.to_s, data["request"]["headers"]["X-Marker"]
          end
        ensure
          workers.length.times { release << true }
          workers.each { |worker| worker.kill.join unless worker.join(5) }
        end
      end
    end
  end

  def response_with_weak_reference
    env = query_env("sleep=0.5&what=-all")
    weak = WeakRef.new(env)
    [RailsRuntimeInfo::Endpoint.call(env), weak]
  end

  def test_delayed_response_does_not_retain_request_or_delay_objects
    Kernel.stub(:sleep, proc { |_| 0 }) do
      rack_response, weak = response_with_weak_reference
      3.times { GC.start } # Test only.
      refute weak.weakref_alive?
      body = rack_response.last
      assert_equal [:@content], body.instance_variables
      body.close
      assert_nil body.instance_variable_get(:@content)
    end
  end
end
