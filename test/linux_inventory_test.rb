# frozen_string_literal: true

require "test_helper"
require "etc"

class LinuxInventoryTest < Minitest::Test
  Linux = RailsRuntimeInfo::LinuxProcess
  CPU_PATH = "process.linux.current_thread.cpu_seconds".freeze

  def linux_response(expression)
    with_constant(Object, :RUBY_PLATFORM, "x86_64-linux-test") { response(what_env(expression)) }
  end

  def sample_stat(user = "125", system = "50")
    fields = ["S"] + Array.new(18, "0") + ["250"]
    fields[11] = user
    fields[12] = system
    "123 (worker ) (name\n)) " + fields.join(" ") + "\n"
  end

  def test_cpu_fields_and_clock_tick_conversion
    stat = Linux.parse_stat(sample_stat)
    assert_equal "125", stat["user_ticks"]
    assert_equal "50", stat["system_ticks"]
    Etc.stub(:sysconf, 100) do
      assert_equal({ "user" => 1.25, "system" => 0.5 }, Linux.cpu_seconds(stat))
    end
  end

  def test_cpu_only_skips_age_and_uptime_lookups
    Linux.stub(:current_thread_stat, Linux.parse_stat(sample_stat)) do
      Linux.stub(:lifetime, proc { |*_| raise "must not read uptime" }) do
        Etc.stub(:sysconf, 100) do
          _, _, data = linux_response("-all,#{CPU_PATH},errors")
          assert_equal({ "cpu_seconds" => { "user" => 1.25, "system" => 0.5 } }, data["process"]["linux"]["current_thread"])
          assert_empty data["errors"]
        end
      end
    end
  end

  def test_cpu_failure_does_not_discard_tid_or_age
    Linux.stub(:current_thread_stat, Linux.parse_stat(sample_stat("bad", "50"))) do
      Linux.stub(:lifetime, { "age_seconds" => 10.0 }) do
        _, _, data = linux_response("-all,process.linux.current_thread,errors")
        thread = data["process"]["linux"]["current_thread"]
        assert_equal 123, thread["tid"]
        assert_equal 10.0, thread["lifetime"]["age_seconds"]
        assert_nil thread["cpu_seconds"]
        assert_equal [CPU_PATH], data["errors"].keys
      end
    end
  end

  def test_invalid_cpu_ticks_and_rates_are_rejected
    ["-1", "1.5", "nan", "", "+1", nil, 1].each do |value|
      assert_raises(ArgumentError) { Linux.cpu_seconds("user_ticks" => value, "system_ticks" => "0") }
    end
    assert_raises(ArgumentError) { Linux.cpu_seconds("user_ticks" => "9" * 1000, "system_ticks" => "0") }
    [nil, "100", 0, -1].each do |value|
      Etc.stub(:sysconf, value) do
        assert_raises(ArgumentError) { Linux.cpu_seconds("user_ticks" => "0", "system_ticks" => "0") }
      end
    end
  end

  def test_tid_only_uses_no_clock_or_cpu_calculation
    Linux.stub(:current_thread_stat, Linux.parse_stat(sample_stat)) do
      Etc.stub(:sysconf, proc { |*_| raise "must not read clock" }) do
        _, _, data = linux_response("-all,process.linux.current_thread.tid,errors")
        assert_equal({ "tid" => 123 }, data["process"]["linux"]["current_thread"])
        assert_empty data["errors"]
      end
    end
  end

  def test_user_cpu_only_nested_selection
    Linux.stub(:current_thread_stat, Linux.parse_stat(sample_stat)) do
      Etc.stub(:sysconf, 100) do
        _, _, data = linux_response("-all,#{CPU_PATH}.user,errors")
        assert_equal({ "user" => 1.25 }, data["process"]["linux"]["current_thread"]["cpu_seconds"])
        assert_empty data["errors"]
      end
    end
  end

  def test_default_skips_fd_details_but_includes_namespaces
    Linux.stub(:fd_names, proc { raise "default must not enumerate descriptors" }) do
      Linux.stub(:namespace_names, { "names" => ["net"], "limit" => 64, "truncated" => false }) do
        Linux.stub(:link_target, "net:[123]") do
          _, _, data = response
          refute data["process"]["linux"].key?("fd_details")
          assert_equal "net:[123]", data["process"]["linux"]["namespaces"]["entries"]["net"]
          refute data["errors"].keys.any? { |key| key.start_with?("process.linux.fd_details") }
        end
      end
    end
  end

  def test_bounded_directory_traversal_stops_after_sentinel
    seen = []
    foreach = proc do |path, &block|
      [".", "..", "not-a-number", "3", "1", "2", "4"].each do |name|
        seen << name
        block.call(name)
      end
    end
    Dir.stub(:foreach, foreach) do
      result = Linux.directory_names("/proc/self/fd", 2, /\A[0-9]+\z/)
      assert_equal ["1", "3"], result["names"]
      assert_equal true, result["truncated"]
      refute_includes seen, "4"
    end
  end

  def test_directory_exact_limit_is_not_truncated
    Dir.mktmpdir do |path|
      %w[0 1].each { |name| File.write(File.join(path, name), "synthetic") }
      result = Linux.directory_names(path, 2, /\A[0-9]+\z/)
      assert_equal ["0", "1"], result["names"]
      assert_equal false, result["truncated"]
    end
  end

  def test_link_helper_only_reads_link_not_its_target
    Dir.mktmpdir do |path|
      link = File.join(path, "fd")
      File.symlink("/deliberately/nonexistent/target", link)
      File.stub(:open, proc { |*_| raise "must never open target" }) do
        assert_equal "/deliberately/nonexistent/target", Linux.link_target(link)
      end
    end
  end

  def test_oversized_link_result_is_an_error
    File.stub(:readlink, "x" * (Linux::LINK_BYTES + 1)) do
      assert_raises(RailsRuntimeInfo::Support::FileTooLarge) { Linux.link_target("/proc/self/fd/0") }
    end
  end

  def test_fd_disappearance_is_per_entry_and_does_not_abort_other_entries
    listing = { "names" => ["5", "6"], "truncated" => false, "limit" => 1024 }
    Linux.stub(:fd_names, listing) do
      Linux.stub(:link_target, proc { |path| path.end_with?("/5") ? (raise Errno::ENOENT) : "socket:[987]" }) do
        _, _, data = linux_response("-all,process.linux.fd_details,process.pid,errors")
        assert_equal Process.pid, data["process"]["pid"]
        info = data["process"]["linux"]["fd_details"]
        assert_equal 1024, info["limit"]
        assert_nil info["entries"]["5"]
        assert_equal "socket:[987]", info["entries"]["6"]
        assert_equal ["process.linux.fd_details.entries.5"], data["errors"].keys
      end
    end
  end

  def test_missing_old_kernel_namespace_directory_is_omitted
    Linux.stub(:namespace_names, proc { raise Errno::ENOENT }) do
      _, _, data = linux_response("-all,process.linux.namespaces,process.pid,errors")
      assert_equal Process.pid, data["process"]["pid"]
      refute data.fetch("process").fetch("linux", {}).key?("namespaces")
      assert_empty data["errors"]
    end
  end

  def test_denied_directory_is_an_isolated_error
    Linux.stub(:namespace_names, proc { raise Errno::EACCES }) do
      _, _, data = linux_response("-all,process.linux.namespaces,process.pid,errors")
      assert_equal Process.pid, data["process"]["pid"]
      assert_nil data["process"]["linux"]["namespaces"]
      assert_equal "Errno::EACCES", data["errors"]["process.linux.namespaces"]["class"]
    end
  end

  def test_namespaces_dotted_selection_only_reads_selected_link
    seen = []
    Linux.stub(:namespace_names, { "names" => ["net", "mnt"], "truncated" => false, "limit" => 64 }) do
      Linux.stub(:link_target, proc { |path| seen << path; "net:[123]" }) do
        _, _, data = linux_response("-all,process.linux.namespaces.entries.net,errors")
        assert_equal({ "entries" => { "net" => "net:[123]" } }, data["process"]["linux"]["namespaces"])
        assert_equal ["/proc/self/ns/net"], seen
        assert_empty data["errors"]
      end
    end
  end

  def test_deselected_links_and_limit_only_selection_do_no_discovery
    forbid = proc { |*_| raise "must not inspect procfs links" }
    Linux.stub(:fd_names, forbid) do
      Linux.stub(:namespace_names, forbid) do
        Linux.stub(:link_target, forbid) do
          _, _, data = linux_response("-all,process.linux.fd_details.limit,process.linux.namespaces.limit,errors")
          assert_equal({ "limit" => 1024 }, data["process"]["linux"]["fd_details"])
          assert_equal({ "limit" => 64 }, data["process"]["linux"]["namespaces"])
          assert_empty data["errors"]
          _, _, data = linux_response("-all,process.pid,errors")
          assert_empty data["errors"]
        end
      end
    end
  end

  def test_fatal_link_error_propagates
    Linux.stub(:namespace_names, { "names" => ["net"], "truncated" => false, "limit" => 64 }) do
      Linux.stub(:link_target, proc { |*_| raise SystemExit }) do
        assert_raises(SystemExit) { linux_response("-all,process.linux.namespaces") }
      end
    end
  end

  def test_non_linux_does_not_discover_procfs_links
    with_constant(Object, :RUBY_PLATFORM, "darwin-test") do
      Linux.stub(:fd_names, proc { raise "must not enumerate" }) do
        Linux.stub(:namespace_names, proc { raise "must not enumerate" }) do
          _, _, data = response(what_env("-all,process.linux,errors"))
          assert_equal({ "available" => false }, data["process"]["linux"])
          assert_empty data["errors"]
        end
      end
    end
  end

  def test_binary_link_contents_are_preserved_without_invalid_json
    Linux.stub(:fd_names, { "names" => ["42"], "truncated" => false, "limit" => 1024 }) do
      Linux.stub(:link_target, "file-\xff".b) do
        _, _, data = linux_response("-all,process.linux.fd_details,errors")
        value = data["process"]["linux"]["fd_details"]["entries"]["42"]
        assert_equal "binary", value["_type"]
        assert_equal "file-\xff".b, value["base64"].unpack("m0").first
        assert_empty data["errors"]
      end
    end
  end

  def test_live_descriptor_enumeration_does_not_leak_directory_handles
    skip "Linux procfs required" unless File.directory?("/proc/self/fd")
    before = Linux.fd_count
    20.times { Linux.fd_names }
    assert_equal before, Linux.fd_count
  end

  def test_live_procfs_cpu_fd_and_namespace_reads
    skip "Linux procfs required" unless RUBY_PLATFORM.include?("linux") && File.directory?("/proc/self/fd") && File.directory?("/proc/self/ns")
    _, _, data = response(what_env("-all,#{CPU_PATH},process.linux.fd_details,process.linux.namespaces,errors"))
    linux = data["process"]["linux"]
    assert_operator linux["current_thread"]["cpu_seconds"]["user"], :>=, 0
    assert_operator linux["current_thread"]["cpu_seconds"]["system"], :>=, 0
    assert_operator linux["fd_details"]["entries"].size, :>, 0
    assert_match(/net:\[[0-9]+\]/, linux["namespaces"]["entries"]["net"])
    # The directory's own FD normally disappears before readlink; other FDs can
    # also close/recycle. Those per-entry errors are valid live observations.
    assert data["errors"].keys.all? { |key| key.start_with?("process.linux.fd_details.entries.") }
  end
end
