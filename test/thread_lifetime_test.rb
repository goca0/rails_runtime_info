# frozen_string_literal: true

require "test_helper"
require "etc"

class ThreadLifetimeTest < Minitest::Test
  LinuxProcess = RailsRuntimeInfo::LinuxProcess
  TASK_PATH = "/proc/self/task/123/stat".freeze
  FALLBACK_PATH = "/proc/thread-self/stat".freeze
  PATH = "process.linux.current_thread".freeze

  def stat_text(tid = 123, ticks = 250, comm = "worker (request) )")
    fields = ["S"] + Array.new(18, "0") + [ticks.to_s] + ["0", "0"]
    "#{tid} (#{comm}) " + fields.join(" ") + "\n"
  end

  def with_proc_files(files)
    reads = []
    reader = proc do |path, *|
      reads << path
      value = files.fetch(path) { raise "unexpected procfs read: #{path}" }
      raise value if value.kind_of?(Exception)
      value
    end
    LinuxProcess.stub(:read, reader) { yield reads }
  end

  def thread_response(expression = "-all,#{PATH},errors")
    with_constant(Object, :RUBY_PLATFORM, "x86_64-linux-test") do
      response(what_env(expression))
    end
  end

  def with_snapshot_data
    stat = { "tid" => 123, "start_ticks_since_boot" => 250, "user_ticks" => "0", "system_ticks" => "0" }.freeze
    age = { "start_ticks_since_boot" => 250, "clock_ticks_per_second" => 100,
            "age_seconds" => 10.0, "started_at_utc_approximate" => "2000-01-01T00:00:00.000000Z" }.freeze
    LinuxProcess.stub(:current_thread_stat, stat) do
      LinuxProcess.stub(:lifetime, age) do
        LinuxProcess.stub(:cpu_seconds, { "user" => 0.0, "system" => 0.0 }) { yield stat, age }
      end
    end
  end

  def test_native_id_uses_old_kernel_task_directory_without_thread_self
    LinuxProcess.stub(:current_native_thread_id, 123) do
      with_proc_files(TASK_PATH => stat_text) do |reads|
        assert_equal({ "tid" => 123, "start_ticks_since_boot" => 250, "user_ticks" => "0", "system_ticks" => "0" }, LinuxProcess.current_thread_stat)
        assert_equal [TASK_PATH], reads
      end
    end
  end

  def test_native_thread_id_reader_is_optional
    result = :not_called
    Thread.stub(:current, Object.new.freeze) { result = LinuxProcess.current_native_thread_id }
    assert_nil result
    fake_thread = Struct.new(:native_thread_id).new(123).freeze
    Thread.stub(:current, fake_thread) { result = LinuxProcess.current_native_thread_id }
    assert_equal 123, result
  end

  def test_absent_invalid_or_opaque_native_ids_use_thread_self_without_coercion
    opaque = Object.new
    def opaque.to_s; raise "must not stringify"; end
    def opaque.to_i; raise "must not coerce"; end
    [nil, 0, -1, "123", 123.0, opaque].each do |value|
      LinuxProcess.stub(:current_native_thread_id, proc { value }) do
        with_proc_files(FALLBACK_PATH => stat_text(456)) do |reads|
          assert_equal 456, LinuxProcess.current_thread_stat["tid"]
          assert_equal [FALLBACK_PATH], reads
        end
      end
    end
  end

  def test_native_id_exceptions_do_not_prevent_the_fallback
    [RuntimeError, LoadError, NotImplementedError].each do |klass|
      LinuxProcess.stub(:current_native_thread_id, proc { raise klass, "unsupported lookup" }) do
        with_proc_files(FALLBACK_PATH => stat_text(456)) do |reads|
          assert_equal 456, LinuxProcess.current_thread_stat["tid"]
          assert_equal [FALLBACK_PATH], reads
        end
      end
    end
  end

  def test_failed_task_file_reads_try_the_fallback_once
    [Errno::ENOENT, Errno::ENOTDIR, Errno::EACCES, IOError, RailsRuntimeInfo::Support::FileTooLarge].each do |klass|
      LinuxProcess.stub(:current_native_thread_id, 123) do
        with_proc_files(TASK_PATH => klass.new("unavailable"), FALLBACK_PATH => stat_text(456)) do |reads|
          assert_equal 456, LinuxProcess.current_thread_stat["tid"]
          assert_equal [TASK_PATH, FALLBACK_PATH], reads
        end
      end
    end
  end

  def test_malformed_or_mismatched_task_stat_tries_the_fallback
    ["not a stat line", stat_text(999), stat_text(123, -1)].each do |text|
      LinuxProcess.stub(:current_native_thread_id, 123) do
        with_proc_files(TASK_PATH => text, FALLBACK_PATH => stat_text(456)) do |reads|
          assert_equal 456, LinuxProcess.current_thread_stat["tid"]
          assert_equal [TASK_PATH, FALLBACK_PATH], reads
        end
      end
    end
  end

  def test_unavailable_paths_return_nil_without_guessing_the_process_id
    [nil, 123].each do |native_id|
      LinuxProcess.stub(:current_native_thread_id, native_id) do
        with_proc_files(TASK_PATH => Errno::ENOENT.new, FALLBACK_PATH => Errno::ENOENT.new) do |reads|
          assert_nil LinuxProcess.current_thread_stat
          refute_includes reads, "/proc/self/stat"
        end
      end
    end
  end

  def test_unimplemented_native_api_and_missing_thread_self_are_unavailable
    LinuxProcess.stub(:current_native_thread_id, proc { raise NotImplementedError }) do
      with_proc_files(FALLBACK_PATH => Errno::ENOENT.new) do
        assert_nil LinuxProcess.current_thread_stat
      end
    end
  end

  def test_unexpected_native_path_failure_is_preserved_if_fallback_is_absent
    LinuxProcess.stub(:current_native_thread_id, 123) do
      with_proc_files(TASK_PATH => Errno::EACCES.new("task denied"), FALLBACK_PATH => Errno::ENOENT.new) do
        error = assert_raises(Errno::EACCES) { LinuxProcess.current_thread_stat }
        assert_match(/task denied/, error.message)
      end
    end
    LinuxProcess.stub(:current_native_thread_id, proc { raise LoadError, "native lookup failed" }) do
      with_proc_files(FALLBACK_PATH => Errno::ENOENT.new) do
        assert_raises(LoadError) { LinuxProcess.current_thread_stat }
      end
    end
  end

  def test_fallback_read_or_parse_failures_propagate_to_the_collector_boundary
    LinuxProcess.stub(:current_native_thread_id, nil) do
      with_proc_files(FALLBACK_PATH => Errno::EACCES.new) do
        assert_raises(Errno::EACCES) { LinuxProcess.current_thread_stat }
      end
      with_proc_files(FALLBACK_PATH => "not a stat") do
        assert_raises(ArgumentError) { LinuxProcess.current_thread_stat }
      end
    end
  end

  def test_fatal_native_and_fallback_errors_are_not_swallowed
    LinuxProcess.stub(:current_native_thread_id, proc { raise SystemExit, "stop" }) do
      with_proc_files({}) { assert_raises(SystemExit) { LinuxProcess.current_thread_stat } }
    end
    LinuxProcess.stub(:current_native_thread_id, nil) do
      with_proc_files(FALLBACK_PATH => NoMemoryError.new) do
        assert_raises(NoMemoryError) { LinuxProcess.current_thread_stat }
      end
    end
  end

  def test_stat_parser_handles_parentheses_spaces_and_newlines_in_comm
    assert_equal({ "tid" => 123, "start_ticks_since_boot" => 250, "user_ticks" => "0", "system_ticks" => "0" }, LinuxProcess.parse_stat(stat_text(123, 250, "a ) b (\nc")))
    assert_equal 123, LinuxProcess.parse_stat(stat_text(123, 250, ""))["tid"]
    assert_equal 0, LinuxProcess.parse_stat(stat_text(123, 0))["start_ticks_since_boot"]
  end

  def test_stat_parser_rejects_malformed_and_negative_values
    ["", "123 no brackets", "x (comm) S 0", stat_text(0), stat_text(123, -1), stat_text(123, "abc")].each do |text|
      assert_raises(ArgumentError) { LinuxProcess.parse_stat(text) }
    end
    assert_raises(IndexError) { LinuxProcess.parse_stat("123 (comm) S 0\n") }
  end

  def test_lifetime_math_and_existing_process_output_shape
    Etc.stub(:sysconf, 100) do
      Time.stub(:now, Time.utc(2000, 1, 1, 0, 0, 10)) do
        with_proc_files("/proc/self/stat" => stat_text, "/proc/uptime" => "12.5 900.0\n") do
          expected = { "start_ticks_since_boot" => 250, "clock_ticks_per_second" => 100,
                       "age_seconds" => 10.0, "started_at_utc_approximate" => "2000-01-01T00:00:00.000000Z" }
          assert_equal expected, LinuxProcess.lifetime(250)
          assert_equal expected, LinuxProcess.start_time
        end
      end
    end
  end

  def test_invalid_clock_tick_rates_fail_without_reading_uptime
    [nil, 0, -1, "100", 100.0].each do |rate|
      Etc.stub(:sysconf, rate) do
        with_proc_files({}) { assert_raises(ArgumentError) { LinuxProcess.lifetime(250) } }
      end
    end
  end

  def test_invalid_ticks_and_uptime_are_rejected
    [-1, nil, "250", 250.0].each do |ticks|
      assert_raises(ArgumentError) { LinuxProcess.lifetime(ticks) }
    end
    Etc.stub(:sysconf, 100) do
      ["-1 0", "NaN 0", "1e999 0", "invalid 0"].each do |text|
        with_proc_files("/proc/uptime" => text) do
          assert_raises(ArgumentError) { LinuxProcess.lifetime(250) }
        end
      end
      with_proc_files("/proc/uptime" => "100 0") do
        assert_raises(ArgumentError) { LinuxProcess.lifetime(10**1000) }
      end
    end
  end

  def test_selected_thread_snapshot_has_tid_and_lifetime
    with_snapshot_data do |stat, age|
      status, _, data = thread_response
      assert_equal 200, status
      assert_equal({ "tid" => stat["tid"], "lifetime" => age, "cpu_seconds" => { "user" => 0.0, "system" => 0.0 } }, data["process"]["linux"]["current_thread"])
      assert_empty data["errors"]
    end
  end

  def test_default_selection_includes_thread_without_enabling_body_capture
    with_snapshot_data do
      _, _, data = thread_response("all,-loaded_features,-load_path,-gems,-environment,-request.body")
      assert_equal 123, data["process"]["linux"]["current_thread"]["tid"]
      refute data["request"].key?("body")
      assert_equal %w[gc yjit runtime application request], data.keys.last(5)
    end
  end

  def test_whole_thread_deselection_and_all_known_children_deselection_skip_discovery
    expressions = ["-all,process.pid", "-all,process.linux,-#{PATH}", "-all,#{PATH},-#{PATH}.tid,-#{PATH}.lifetime,-#{PATH}.cpu_seconds"]
    LinuxProcess.stub(:current_thread_stat, proc { raise "must not discover current thread" }) do
      expressions.each do |expression|
        status, _, data = thread_response(expression + ",errors")
        assert_equal 200, status
        refute data.fetch("errors").key?(PATH)
      end
    end
  end

  def test_tid_only_skips_lifetime_clock_ticks_and_uptime
    LinuxProcess.stub(:current_thread_stat, { "tid" => 123, "start_ticks_since_boot" => 250, "user_ticks" => "0", "system_ticks" => "0" }) do
      LinuxProcess.stub(:lifetime, proc { raise "must not calculate lifetime" }) do
        status, _, data = thread_response("-all,#{PATH}.tid,errors")
        assert_equal 200, status
        assert_equal({ "tid" => 123 }, data["process"]["linux"]["current_thread"])
        assert_empty data["errors"]
      end
    end
  end

  def test_nested_age_only_selection_and_parent_reset
    with_snapshot_data do
      _, _, data = thread_response("-all,#{PATH}.lifetime.age_seconds,errors")
      assert_equal({ "lifetime" => { "age_seconds" => 10.0 } }, data["process"]["linux"]["current_thread"])
      _, _, data = thread_response("-all,#{PATH},-#{PATH}.lifetime,#{PATH},errors")
      assert_equal 10.0, data["process"]["linux"]["current_thread"]["lifetime"]["age_seconds"]
    end
  end

  def test_unavailable_thread_is_omitted_and_other_process_fields_survive
    LinuxProcess.stub(:current_thread_stat, nil) do
      status, _, data = thread_response("-all,#{PATH},process.pid,errors")
      assert_equal 200, status
      assert_equal({ "pid" => Process.pid }, data["process"])
      assert_empty data["errors"]
    end
  end

  def test_lookup_failure_is_field_local
    [IOError, LoadError, NotImplementedError].each do |klass|
      LinuxProcess.stub(:current_thread_stat, proc { raise klass, "test lookup failure" }) do
        status, _, data = thread_response("-all,#{PATH},process.pid,errors")
        assert_equal 200, status
        assert_equal Process.pid, data["process"]["pid"]
        assert_nil data["process"]["linux"]["current_thread"]
        assert_equal klass.name, data["errors"][PATH]["class"]
      end
    end
  end

  def test_lifetime_failure_keeps_tid_and_reports_nested_error
    LinuxProcess.stub(:current_thread_stat, { "tid" => 123, "start_ticks_since_boot" => 250, "user_ticks" => "0", "system_ticks" => "0" }) do
      LinuxProcess.stub(:lifetime, proc { raise Errno::EACCES, "uptime denied" }) do
        status, _, data = thread_response
        assert_equal 200, status
        assert_equal 123, data["process"]["linux"]["current_thread"]["tid"]
        assert_nil data["process"]["linux"]["current_thread"]["lifetime"]
        assert_equal({ "user" => 0.0, "system" => 0.0 }, data["process"]["linux"]["current_thread"]["cpu_seconds"])
        assert_equal ["#{PATH}.lifetime"], data["errors"].keys
        assert_equal "Errno::EACCES", data["errors"]["#{PATH}.lifetime"]["class"]
      end
    end
  end

  def test_fatal_errors_propagate_through_the_endpoint
    LinuxProcess.stub(:current_thread_stat, proc { raise SystemExit }) do
      assert_raises(SystemExit) { thread_response }
    end
    LinuxProcess.stub(:current_thread_stat, { "tid" => 123, "start_ticks_since_boot" => 250, "user_ticks" => "0", "system_ticks" => "0" }) do
      LinuxProcess.stub(:lifetime, proc { raise NoMemoryError }) do
        assert_raises(NoMemoryError) { thread_response }
      end
    end
  end

  def test_non_linux_skips_discovery
    with_constant(Object, :RUBY_PLATFORM, "x86_64-darwin-test") do
      LinuxProcess.stub(:current_thread_stat, proc { raise "must not discover on non-Linux" }) do
        status, _, data = response(what_env("-all,process.linux,errors"))
        assert_equal 200, status
        assert_equal({ "available" => false }, data["process"]["linux"])
        assert_empty data["errors"]
      end
    end
  end

  def test_no_thread_enumeration_or_local_mutation
    before_keys = Thread.current.keys
    before_variables = Thread.current.thread_variables
    with_snapshot_data do
      Thread.stub(:list, proc { raise "must not enumerate threads for this collector" }) do
        status, _, data = thread_response
        assert_equal 200, status
        assert_empty data["errors"]
      end
    end
    assert_equal before_keys, Thread.current.keys
    assert_equal before_variables, Thread.current.thread_variables
  end

  def test_fresh_reads_are_not_cached
    LinuxProcess.stub(:current_native_thread_id, 123) do
      first = LinuxProcess.stub(:read, stat_text(123, 250)) { LinuxProcess.current_thread_stat }
      second = LinuxProcess.stub(:read, stat_text(123, 300)) { LinuxProcess.current_thread_stat }
      assert_equal 250, first["start_ticks_since_boot"]
      assert_equal 300, second["start_ticks_since_boot"]
    end
  end

  def response_with_weak_stat_reference
    stat = { "tid" => 123, "start_ticks_since_boot" => 250, "user_ticks" => "0", "system_ticks" => "0" }
    weak = WeakRef.new(stat)
    rack_response = LinuxProcess.stub(:current_thread_stat, stat) do
      with_constant(Object, :RUBY_PLATFORM, "x86_64-linux-test") do
        RailsRuntimeInfo::Endpoint.call(what_env("-all,#{PATH}.tid"))
      end
    end
    [rack_response, weak]
  end

  def test_response_does_not_retain_stat_snapshot
    rack_response, weak = Thread.new { response_with_weak_stat_reference }.value
    3.times { GC.start } # Tests only; no forced collection in the library.
    refute weak.weakref_alive?
    assert_equal [:@content], rack_response.last.instance_variables
    rack_response.last.close
  end

  def test_live_native_task_and_thread_self_agree
    skip "Linux procfs and native TID needed" unless RUBY_PLATFORM.include?("linux") && File.file?(FALLBACK_PATH) && Thread.current.respond_to?(:native_thread_id)
    native = LinuxProcess.current_thread_stat
    fallback = LinuxProcess.stub(:current_native_thread_id, nil) { LinuxProcess.current_thread_stat }
    assert_equal Thread.current.native_thread_id, native["tid"]
    assert_equal native.values_at("tid", "start_ticks_since_boot"), fallback.values_at("tid", "start_ticks_since_boot")
    # CPU counters can advance between the two procfs reads.
    %w[user_ticks system_ticks].each do |field|
      assert_operator Integer(fallback.fetch(field), 10), :>=, Integer(native.fetch(field), 10)
    end
    assert_operator LinuxProcess.lifetime(native["start_ticks_since_boot"])["age_seconds"], :>=, 0
  end

  def test_live_concurrent_request_threads_have_distinct_native_ids
    skip "Linux procfs and native TID needed" unless RUBY_PLATFORM.include?("linux") && File.file?(FALLBACK_PATH) && Thread.current.respond_to?(:native_thread_id)
    ready = Queue.new
    release = Queue.new
    workers = 3.times.map do
      Thread.new do
        begin
          expected_tid = Thread.current.native_thread_id
          result = response(what_env("-all,#{PATH},errors"))
          [expected_tid, result]
        ensure
          # Always notify the main test, including on failure. Hold the worker
          # alive until every sample is taken so Linux cannot recycle its TID.
          ready << true
          release.pop
        end
      end
    end
    workers.length.times { ready.pop }
    workers.length.times { release << true }
    samples = workers.map(&:value)
    tids = samples.map do |expected_tid, result|
      status, _, data = result
      thread = data["process"]["linux"]["current_thread"]
      assert_equal 200, status
      assert_empty data["errors"]
      assert_equal expected_tid, thread["tid"]
      assert_operator thread["lifetime"]["age_seconds"], :>=, 0
      refute_equal Process.pid, thread["tid"]
      thread["tid"]
    end
    assert_equal workers.length, tids.uniq.length
  ensure
    if workers
      workers.length.times { release << true }
      workers.each(&:join)
    end
  end
end
