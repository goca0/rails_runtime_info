# frozen_string_literal: true

require "test_helper"

# These are in-process API doubles, not running Passenger or Puma servers.
class ServerInfoTest < Minitest::Test
  PassengerHandler = Struct.new(:iteration)
  PumaInstance = Struct.new(:requests_count)

  def with_passenger_handler(handler)
    previous = Thread.current[:passenger_thread_handler]
    Thread.current[:passenger_thread_handler] = handler
    yield
  ensure
    Thread.current[:passenger_thread_handler] = previous
  end

  def with_puma_server(server)
    server_class = Class.new
    server_class.define_singleton_method(:current) { server }
    puma = Module.new
    puma.const_set(:Server, server_class)
    # A counter read must not obtain a broader, potentially mutating snapshot.
    def puma.stats; raise "must not call Puma.stats"; end
    def puma.stats_hash; raise "must not call Puma.stats_hash"; end
    with_constant(Object, :Puma, puma) { yield server_class }
  end

  def server_response(expression = "-all,server,errors")
    response(what_env(expression))
  end

  def raising_reader(method, error = RuntimeError)
    object = Object.new
    object.define_singleton_method(method) { raise error, "counter unavailable" }
    object
  end

  def assert_available_counter(name, key, value)
    status, _, data = server_response
    assert_equal 200, status
    assert_equal({ key => value }, data["server"][name])
    assert_empty data["errors"]
  end

  def assert_unavailable_counter(name)
    status, _, data = server_response
    assert_equal 200, status
    refute data["server"].key?(name)
    assert_empty data["errors"]
  end

  def test_passenger_reads_current_handler_including_zero_and_large_integers
    [0, 123, 2**80].each do |value|
      with_passenger_handler(PassengerHandler.new(value)) do
        assert_available_counter("passenger", "thread_iteration", value)
      end
    end
  end

  def test_passenger_without_handler_is_omitted
    with_passenger_handler(nil) { assert_unavailable_counter("passenger") }
  end

  def test_passenger_without_reader_is_omitted
    with_passenger_handler(Object.new) { assert_unavailable_counter("passenger") }
  end

  def test_passenger_ignores_invalid_values_without_coercion_or_serialization
    unusual = Object.new
    def unusual.to_int; raise "must not coerce"; end
    def unusual.to_i; raise "must not coerce"; end
    def unusual.inspect; raise "must not inspect"; end
    def unusual.to_json(*); raise "must not serialize"; end
    [nil, -1, 1.5, "42", true, unusual, BasicObject.new].each do |value|
      with_passenger_handler(PassengerHandler.new(value)) do
        assert_unavailable_counter("passenger")
      end
    end
  end

  def test_puma_reads_current_server_including_zero_and_large_integers
    [0, 321, 2**80].each do |value|
      with_puma_server(PumaInstance.new(value)) do
        assert_available_counter("puma", "requests_count", value)
      end
    end
  end

  def test_puma_without_current_server_is_omitted
    with_puma_server(nil) { assert_unavailable_counter("puma") }
  end

  def test_puma_without_counter_reader_is_omitted
    with_puma_server(Object.new) { assert_unavailable_counter("puma") }
  end

  def test_puma_without_current_method_is_omitted
    puma = Module.new
    puma.const_set(:Server, Class.new)
    with_constant(Object, :Puma, puma) { assert_unavailable_counter("puma") }
  end

  def test_puma_without_server_constant_is_omitted
    puma = Module.new
    def puma.const_missing(*); raise "must not resolve missing constants"; end
    with_constant(Object, :Puma, puma) { assert_unavailable_counter("puma") }
  end

  def test_puma_ignores_invalid_values_without_coercion_or_serialization
    unusual = Object.new
    def unusual.to_int; raise "must not coerce"; end
    def unusual.to_i; raise "must not coerce"; end
    def unusual.inspect; raise "must not inspect"; end
    def unusual.to_json(*); raise "must not serialize"; end
    [nil, -1, 1.5, "42", true, unusual, BasicObject.new].each do |value|
      with_puma_server(PumaInstance.new(value)) { assert_unavailable_counter("puma") }
    end
  end

  def test_puma_server_constant_is_not_autoloaded
    puma = Module.new
    puma.autoload(:Server, "/never/load/puma_server")
    with_constant(Object, :Puma, puma) do
      assert_unavailable_counter("puma")
      assert_equal "/never/load/puma_server", puma.autoload?(:Server)
    end
  end

  def test_optional_server_modules_are_not_autoloaded
    # Isolate Object's autoload entries in a fresh Ruby process.
    program = <<~'CODE'
      require "json"
      require "rails_runtime_info"
      Object.autoload(:Puma, "/never/load/puma")
      Object.autoload(:PhusionPassenger, "/never/load/passenger")
      status, _, body = RailsRuntimeInfo::Endpoint.call("QUERY_STRING" => "what=-all,server,errors")
      text = String.new
      body.each { |chunk| text << chunk }
      body.close
      data = JSON.parse(text)
      abort "bad response" unless status == 200 && data["errors"].empty?
      abort "Puma autoload changed" unless Object.autoload?(:Puma) == "/never/load/puma"
      abort "Passenger autoload changed" unless Object.autoload?(:PhusionPassenger) == "/never/load/passenger"
      abort "counter invented" if data["server"].key?("puma") || data["server"].key?("passenger")
      puts "ok"
    CODE
    library = File.expand_path("../lib", __dir__)
    output, error, status = Open3.capture3(RbConfig.ruby, "-I", library, "-e", program)
    assert status.success?, error + output
    assert_equal "ok\n", output
  end

  def test_passenger_reader_failures_are_independent
    [RuntimeError, LoadError, NotImplementedError].each do |type|
      with_passenger_handler(raising_reader(:iteration, type)) do
        with_puma_server(PumaInstance.new(42)) do
          status, _, data = server_response("-all,server,process.pid,errors")
          assert_equal 200, status
          assert_nil data["server"]["passenger"]["thread_iteration"]
          assert_equal type.name, data["errors"]["server.passenger.thread_iteration"]["class"]
          assert_equal 42, data["server"]["puma"]["requests_count"]
          assert_equal Process.pid, data["process"]["pid"]
        end
      end
    end
  end

  def test_puma_reader_failures_are_independent
    [RuntimeError, LoadError, NotImplementedError].each do |type|
      with_passenger_handler(PassengerHandler.new(31)) do
        with_puma_server(raising_reader(:requests_count, type)) do
          status, _, data = server_response("-all,server,process.pid,errors")
          assert_equal 200, status
          assert_nil data["server"]["puma"]["requests_count"]
          assert_equal type.name, data["errors"]["server.puma.requests_count"]["class"]
          assert_equal 31, data["server"]["passenger"]["thread_iteration"]
          assert_equal Process.pid, data["process"]["pid"]
        end
      end
    end
  end

  def test_puma_current_failure_is_contained
    with_passenger_handler(PassengerHandler.new(31)) do
      with_puma_server(nil) do |klass|
        def klass.current; raise "current unavailable"; end
        status, _, data = server_response
        assert_equal 200, status
        assert_equal 31, data["server"]["passenger"]["thread_iteration"]
        assert_nil data["server"]["puma"]["requests_count"]
        assert_equal "RuntimeError", data["errors"]["server.puma.requests_count"]["class"]
      end
    end
  end

  def test_broken_capability_checks_are_contained
    broken = Object.new
    def broken.respond_to?(*); raise "broken capability check"; end
    with_passenger_handler(broken) do
      with_puma_server(broken) do
        status, _, data = server_response
        assert_equal 200, status
        assert_equal %w[server.passenger.thread_iteration server.puma.requests_count], data["errors"].keys.sort
      end
    end
  end

  def test_fatal_counter_exceptions_are_not_swallowed
    [NoMemoryError, SystemExit, Interrupt].each do |type|
      with_passenger_handler(raising_reader(:iteration, type)) do
        assert_raises(type) { server_response }
      end
      with_puma_server(raising_reader(:requests_count, type)) do
        assert_raises(type) { server_response }
      end
    end
  end

  def test_counters_are_included_by_default_without_changing_order_or_body_default
    with_passenger_handler(PassengerHandler.new(7)) do
      with_puma_server(PumaInstance.new(8)) do
        input = Object.new
        def input.read(*); raise "default must not read body"; end
        status, _, data = response(rack_env("", "rack.input" => input))
        assert_equal 200, status
        assert_equal 7, data["server"]["passenger"]["thread_iteration"]
        assert_equal 8, data["server"]["puma"]["requests_count"]
        assert_equal %w[gc yjit runtime application request], data.keys.last(5)
        refute data["request"].key?("body")
      end
    end
  end

  def test_excluded_counters_do_not_call_readers_or_current
    reads = []
    handler = Object.new
    handler.define_singleton_method(:iteration) { reads << :passenger; 1 }
    with_passenger_handler(handler) do
      with_puma_server(nil) do |klass|
        klass.define_singleton_method(:current) { reads << :puma; nil }
        ["-server", "-all,server.software,errors", "-server.passenger,-server.puma",
         "-server.passenger.thread_iteration,-server.puma.requests_count"].each do |expression|
          status, _, data = server_response(expression)
          assert_equal 200, status
          assert_empty reads
          assert_empty data["errors"]
        end
      end
    end
  end

  def test_nested_selection_selects_only_its_counter_and_skips_other_reader
    reads = []
    handler = Object.new
    handler.define_singleton_method(:iteration) { reads << :passenger; 31 }
    with_passenger_handler(handler) do
      with_puma_server(PumaInstance.new(42)) do |klass|
        klass.define_singleton_method(:current) { reads << :puma; PumaInstance.new(42) }
        _, _, data = server_response("-all,server.passenger.thread_iteration")
        assert_equal({ "server" => { "passenger" => { "thread_iteration" => 31 } } }, data)
        assert_equal [:passenger], reads
        reads.clear
        _, _, data = server_response("-all,server.puma.requests_count")
        assert_equal({ "server" => { "puma" => { "requests_count" => 42 } } }, data)
        assert_equal [:puma], reads
      end
    end
  end

  def test_later_parent_rule_restores_counter
    with_passenger_handler(PassengerHandler.new(31)) do
      with_puma_server(PumaInstance.new(42)) do
        _, _, data = server_response("-all,-server.passenger.thread_iteration,-server.puma.requests_count,server")
        assert_equal 31, data["server"]["passenger"]["thread_iteration"]
        assert_equal 42, data["server"]["puma"]["requests_count"]
      end
    end
  end

  def test_no_server_state_is_mutated_or_statistics_api_called
    handler = PassengerHandler.new(31)
    server = PumaInstance.new(42)
    def server.stats; raise "must not call Server#stats"; end
    def handler.stats_mutex; raise "must not acquire Passenger mutex"; end
    handler.freeze
    server.freeze
    with_passenger_handler(handler) do
      with_puma_server(server) do
        before_keys = Thread.current.keys.sort
        2.times do
          status, _, data = server_response
          assert_equal 200, status
          assert_empty data["errors"]
          assert_equal 31, data["server"]["passenger"]["thread_iteration"]
          assert_equal 42, data["server"]["puma"]["requests_count"]
        end
        assert_same handler, Thread.current[:passenger_thread_handler]
        assert_equal before_keys, Thread.current.keys.sort
        assert_equal 31, handler.iteration
        assert_equal 42, server.requests_count
      end
    end
  end

  def test_counter_reads_are_fresh_not_cached_or_incremented_by_the_gem
    handler = PassengerHandler.new(1)
    server = PumaInstance.new(2)
    with_passenger_handler(handler) do
      with_puma_server(server) do
        _, _, first = server_response
        handler.iteration = 11
        server.requests_count = 22
        _, _, second = server_response
        assert_equal 1, first["server"]["passenger"]["thread_iteration"]
        assert_equal 2, first["server"]["puma"]["requests_count"]
        assert_equal 11, second["server"]["passenger"]["thread_iteration"]
        assert_equal 22, second["server"]["puma"]["requests_count"]
      end
    end
  end

  def test_passenger_counters_are_thread_specific_and_puma_is_worker_shared
    shared_server = PumaInstance.new(99).freeze
    with_puma_server(shared_server) do
      threads = 4.times.map do |index|
        Thread.new do
          with_passenger_handler(PassengerHandler.new(index)) do
            _, _, data = server_response
            [index, data["server"]]
          end
        end
      end
      threads.each do |thread|
        index, data = thread.value
        assert_equal index, data["passenger"]["thread_iteration"]
        assert_equal 99, data["puma"]["requests_count"]
      end
    end
  end

  def test_missing_passenger_fiber_local_does_not_search_other_fibers
    with_passenger_handler(PassengerHandler.new(31)) do
      _, _, data = Fiber.new { server_response }.resume
      refute data["server"].key?("passenger")
      assert_available_counter("passenger", "thread_iteration", 31)
    end
  end

  def response_with_weak_server_references
    handler = PassengerHandler.new(31)
    server = PumaInstance.new(42)
    weak_handler = WeakRef.new(handler)
    weak_server = WeakRef.new(server)
    rack_response = nil
    with_passenger_handler(handler) do
      with_puma_server(server) do
        rack_response = RailsRuntimeInfo::Endpoint.call(what_env("-all,server"))
      end
    end
    [rack_response, weak_handler, weak_server]
  end

  def test_response_does_not_retain_handler_or_server
    rack_response, weak_handler, weak_server = response_with_weak_server_references
    3.times { GC.start } # Tests only; library code must never force GC.
    refute weak_handler.weakref_alive?
    refute weak_server.weakref_alive?
    assert_equal [:@content], rack_response.last.instance_variables
    rack_response.last.close
  end
end
