# frozen_string_literal: true

require "test_helper"

class ThreadInfoTest < Minitest::Test
  Info = RailsRuntimeInfo::ThreadInfo

  def inventory(expression = "-all,process.threads,errors")
    response(what_env(expression))
  end

  def test_default_inventory_contains_core_metadata_without_backtraces
    _, _, data = response
    info = data["process"]["threads"]
    assert_operator info["total"], :>=, 1
    assert_equal 256, info["limit"]
    assert_equal false, info["truncated"]
    row = info["items"].find { |item| item["object_id"] == Thread.current.object_id }
    assert row
    assert_equal "run", row["status"]
    assert row.key?("name")
    if Thread.current.respond_to?(:native_thread_id)
      assert_equal Thread.current.native_thread_id, row["native_tid"]
    end
    refute data["process"].key?("thread_backtraces")
    refute row.key?("backtrace")
  end

  def test_live_terminated_thread_remains_safe_to_inspect
    worker = Thread.new { nil }
    worker.join
    Info.stub(:list, [worker]) do
      _, _, data = inventory("-all,process.threads,process.thread_backtraces,errors")
      row = data["process"]["threads"]["items"].first
      assert_equal false, row["status"]
      assert_nil row["native_tid"] if row.key?("native_tid")
      assert_nil data["process"]["thread_backtraces"]["items"].first["backtrace"]
      assert_empty data["errors"]
    end
  end

  def test_singleton_thread_readers_are_never_dispatched
    worker = Thread.new { nil }
    worker.join
    worker.name = "safe core name"
    [:name, :status, :native_thread_id, :backtrace, :inspect, :to_s, :object_id].each do |name|
      worker.define_singleton_method(name) { raise "must not dispatch overridden method" }
    end
    Info.stub(:list, [worker]) do
      _, _, data = inventory("-all,process.threads,process.thread_backtraces,errors")
      row = data["process"]["threads"]["items"].first
      assert_equal "safe core name", row["name"]
      assert_equal false, row["status"]
      assert_kind_of Integer, row["object_id"]
      assert_empty data["errors"]
    end
  end

  def test_subclass_overrides_are_bypassed
    subclass = Class.new(Thread) do
      def status; raise "subclass status must not run"; end
      def name; raise "subclass name must not run"; end
    end
    worker = subclass.new { nil }
    worker.join
    Info.stub(:list, [worker]) do
      _, _, data = inventory
      assert_equal false, data["process"]["threads"]["items"].first["status"]
      assert_empty data["errors"]
    end
  end

  def test_globally_replaced_reader_is_not_invoked
    with_instance_method(Thread, :name, proc { raise "global replacement must not run" }) do
      assert_nil Info.reader(:name)
      _, _, data = inventory
      refute data["process"]["threads"]["items"].first.key?("name")
      assert_empty data["errors"]
    end
  end

  def test_replaced_thread_list_is_not_invoked
    Thread.stub(:list, proc { raise "replacement must not run" }) do
      assert_nil Info.list
      _, _, data = inventory("-all,process.threads,process.ruby_threads,errors")
      assert_nil data["process"]["ruby_threads"]
      refute data.fetch("process", {}).key?("threads")
      assert_empty data["errors"]
    end
  end

  def test_unavailable_optional_native_id_is_omitted
    original = Info.method(:reader)
    Info.stub(:reader, proc { |name| name == :native_thread_id ? nil : original.call(name) }) do
      _, _, data = inventory
      refute data["process"]["threads"]["items"].first.key?("native_tid")
      assert_empty data["errors"]
    end
  end

  def test_failure_is_isolated_per_field_and_per_thread
    original = Info.method(:read)
    first = Thread.current
    worker = Thread.new { nil }
    worker.join
    Info.stub(:list, [first, worker]) do
      Info.stub(:read, proc { |method, thread, *args|
        raise NotImplementedError, "test unsupported name" if method.name == :name && thread.equal?(first)
        original.call(method, thread, *args)
      }) do
        _, _, data = inventory
        assert_nil data["process"]["threads"]["items"][0]["name"]
        assert_equal "run", data["process"]["threads"]["items"][0]["status"]
        assert_equal false, data["process"]["threads"]["items"][1]["status"]
        assert_equal ["process.threads.items.0.name"], data["errors"].keys
      end
    end
  end

  def test_list_failure_is_local_to_selected_section
    Info.stub(:list, proc { raise IOError, "test list failure" }) do
      _, _, data = inventory("-all,process.threads,process.pid,errors")
      assert_equal Process.pid, data["process"]["pid"]
      assert_nil data["process"]["threads"]
      assert_equal ["process.threads"], data["errors"].keys
    end
  end

  def test_fatal_failures_are_not_swallowed
    Info.stub(:list, proc { raise NoMemoryError }) do
      assert_raises(NoMemoryError) { inventory }
    end
    Info.stub(:read, proc { |*_| raise SystemExit }) do
      assert_raises(SystemExit) { inventory }
    end
  end

  def test_inventory_cap_reports_total_and_truncation
    Info.stub(:list, [Thread.current] * (Info::INVENTORY_LIMIT + 1)) do
      _, _, data = inventory
      info = data["process"]["threads"]
      assert_equal 257, info["total"]
      assert_equal 256, info["items"].size
      assert_equal true, info["truncated"]
      assert_empty data["errors"]
    end
  end

  def test_summary_only_does_not_read_thread_fields
    Info.stub(:reader, proc { |*_| raise "must not inspect a thread" }) do
      _, _, data = inventory("-all,process.threads.total,process.thread_backtraces.total,errors")
      assert_equal ["total"], data["process"]["threads"].keys
      assert_equal ["total"], data["process"]["thread_backtraces"].keys
      assert_empty data["errors"]
    end
  end

  def test_thread_collectors_are_not_run_when_excluded
    Info.stub(:list, proc { raise "excluded discovery must not run" }) do
      _, _, data = inventory("-process.threads,-process.thread_backtraces,-process.ruby_threads")
      refute data["process"].key?("threads")
      refute data["process"].key?("thread_backtraces")
      refute data["errors"].keys.any? { |key| key.start_with?("process.threads", "process.thread_backtraces") }
    end
  end

  def test_backtrace_collector_is_not_run_by_default
    Info.stub(:backtrace, proc { |*_| raise "default must not get backtraces" }) do
      _, _, data = response
      refute data["process"].key?("thread_backtraces")
      refute data["errors"].keys.any? { |key| key.start_with?("process.thread_backtraces") }
    end
  end

  def test_explicit_backtrace_inclusion_and_later_exclusion
    _, _, data = inventory("-all,process.thread_backtraces,errors")
    info = data["process"]["thread_backtraces"]
    assert_equal 64, info["limit"]
    assert_kind_of Array, info["items"].first["backtrace"]["frames"]
    assert_empty data["errors"]
    Info.stub(:backtrace, proc { |*_| raise "exclusion must skip backtrace" }) do
      _, _, data = inventory("-all,process,-process.thread_backtraces,errors")
      refute data["process"].key?("thread_backtraces")
      refute data["errors"].keys.any? { |key| key.start_with?("process.thread_backtraces") }
    end
  end

  def test_backtrace_uses_bounded_api_once_and_truncates_frames_and_text
    calls = []
    Info.stub(:read, proc { |method, thread, *args|
      calls << args
      ["x" * (Info::TEXT_BYTES + 1)] * (Info::FRAME_LIMIT + 1)
    }) do
      data = Info.backtrace(Object.new, Thread.current)
      assert_equal [[0, 65]], calls
      assert_equal 64, data["frames"].size
      assert_equal 1024, data["frames"].first.bytesize
      assert_equal true, data["frames_truncated"]
      assert_equal true, data["frame_text_truncated"]
    end
  end

  def test_no_unbounded_retry_when_bounded_backtrace_is_unsupported
    calls = []
    Info.stub(:read, proc { |method, thread, *args|
      calls << args
      raise ArgumentError, "unsupported bounded API"
    }) do
      assert_raises(ArgumentError) { Info.backtrace(Object.new, Thread.current) }
      assert_equal [[0, 65]], calls
    end
  end

  def test_backtrace_thread_limit_is_independent_of_inventory_limit
    Info.stub(:list, [Thread.current] * 65) do
      Info.stub(:backtrace, { "frames" => [], "frames_truncated" => false, "frame_text_truncated" => false }) do
        _, _, data = inventory("-all,process.thread_backtraces,errors")
        info = data["process"]["thread_backtraces"]
        assert_equal 65, info["total"]
        assert_equal 64, info["items"].size
        assert_equal true, info["truncated"]
      end
    end
  end

  def test_backtrace_failure_does_not_discard_identity_or_inventory
    Info.stub(:backtrace, proc { |*_| raise RuntimeError, "test failure" }) do
      Info.stub(:list, [Thread.current]) do
        _, _, data = inventory("-all,process.threads,process.thread_backtraces,errors")
        row = data["process"]["thread_backtraces"]["items"].first
        assert_equal Thread.current.object_id, row["object_id"]
        assert_nil row["backtrace"]
        assert_equal "run", data["process"]["threads"]["items"].first["status"]
        assert_equal ["process.thread_backtraces.items.0.backtrace"], data["errors"].keys
      end
    end
  end

  def test_long_thread_name_is_bounded_without_changing_thread
    worker = Thread.new { nil }
    worker.join
    worker.name = "x" * 2000
    Info.stub(:list, [worker]) do
      _, _, data = inventory
      row = data["process"]["threads"]["items"].first
      assert_equal 1024, row["name"].bytesize
      assert_equal true, row["name_truncated"]
      assert_equal 2000, worker.name.bytesize
    end
  end

  def test_text_and_backtrace_helpers_do_not_invoke_coercion_hooks
    value = Object.new
    def value.to_s; raise "must not stringify"; end
    assert_raises(TypeError) { Info.text(value) }
    Info.stub(:read, value) do
      assert_raises(TypeError) { Info.backtrace(Object.new, Thread.current) }
    end
    assert_raises(TypeError) { Info.read(Info.reader(:status), value) }
  end

  def test_new_collectors_are_not_reached_before_authentication
    Dir.mktmpdir do |directory|
      file = File.join(directory, "diagnostics.htpasswd")
      File.write(file, "synthetic:{PLAIN}correct-password\n")
      app = RailsRuntimeInfo::Endpoint.basic_auth(htpasswd: file)
      Info.stub(:list, proc { raise "must not enumerate before auth" }) do
        RailsRuntimeInfo::LinuxProcess.stub(:fd_names, proc { raise "must not inspect FDs before auth" }) do
          RailsRuntimeInfo::LinuxProcess.stub(:namespace_names, proc { raise "must not inspect namespaces before auth" }) do
            env = what_env("all", "must remain unread", "HTTP_AUTHORIZATION" => "Basic " + ["synthetic:wrong-password"].pack("m0"))
            status, _, body = app.call(env)
            assert_equal 401, status
            assert_equal 0, env["rack.input"].pos
            body.close
          end
        end
      end
    end
  end

  def test_full_parent_inclusion_and_exclusion_obey_existing_selection_semantics
    counter = 0
    Info.stub(:list, [Thread.current]) do
      Info.stub(:backtrace, proc { |*_| counter += 1; { "frames" => [], "frames_truncated" => false, "frame_text_truncated" => false } }) do
        _, _, first = inventory("-all,process,-process.linux,errors")
        assert_equal 1, counter
        assert first["process"].key?("thread_backtraces")
        _, _, second = inventory("-all,process,-process.linux,-process.thread_backtraces,errors")
        assert_equal 1, counter
        refute second["process"].key?("thread_backtraces")
        assert_equal %w[process errors], second.keys
      end
    end
  end

  def test_unavailable_backtrace_reader_does_not_remove_identity
    original = Info.method(:reader)
    Info.stub(:reader, proc { |name| name == :backtrace ? nil : original.call(name) }) do
      _, _, data = inventory("-all,process.thread_backtraces,errors")
      row = data["process"]["thread_backtraces"]["items"].first
      assert_kind_of Integer, row["object_id"]
      refute row.key?("backtrace")
      assert_empty data["errors"]
    end
  end

  def response_with_weak_list
    list = [Thread.current]
    weak = WeakRef.new(list)
    rack_response = Info.stub(:list, list) do
      RailsRuntimeInfo::Endpoint.call(what_env("-all,process.threads,process.thread_backtraces"))
    end
    [rack_response, weak]
  end

  def test_response_does_not_retain_thread_array
    rack_response, weak = response_with_weak_list
    3.times { GC.start } # Tests only.
    refute weak.weakref_alive?
    assert_equal [:@content], rack_response.last.instance_variables
    rack_response.last.close
  end

  def test_concurrent_snapshots_and_thread_churn_do_not_change_thread_state
    ready = Queue.new
    release = Queue.new
    workers = 4.times.map do |index|
      Thread.new do
        Thread.current.name = "test inventory worker #{index}"
        Thread.current[:test_marker] = index
        before = [Thread.current.keys, Thread.current.thread_variables, Thread.current.name, Thread.current.abort_on_exception]
        result = inventory("-all,process.threads,process.thread_backtraces,errors")
        after = [Thread.current.keys, Thread.current.thread_variables, Thread.current.name, Thread.current.abort_on_exception]
        [result, before, after]
      ensure
        ready << true
        release.pop
      end
    end
    # Natural exits between Thread.list and reads are allowed. Never kill them.
    transient = 20.times.map { Thread.new { Thread.pass } }
    workers.size.times { ready.pop }
    workers.size.times { release << true }
    samples = workers.map(&:value)
    transient.each(&:join)
    samples.each do |result, before, after|
      assert_equal before, after
      assert_equal 200, result[0]
      assert_empty result[2]["errors"]
      assert_kind_of Array, result[2]["process"]["threads"]["items"]
    end
  ensure
    if workers
      workers.size.times { release << true }
      workers.each(&:join)
    end
    transient.each(&:join) if transient
  end
end
