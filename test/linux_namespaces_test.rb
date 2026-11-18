# frozen_string_literal: true

require "test_helper"

class LinuxNamespacesTest < Minitest::Test
  Linux = RailsRuntimeInfo::LinuxProcess
  PATH = "process.linux.namespaces".freeze
  NAMES = %w[cgroup ipc mnt net pid pid_for_children time time_for_children user uts].freeze

  def namespace_response(expression = "-all,#{PATH},process.pid,errors")
    with_constant(Object, :RUBY_PLATFORM, "x86_64-linux-test") { response(what_env(expression)) }
  end

  def test_successful_enumeration_discovers_unknown_names_and_never_uses_fallback
    events = []
    foreach = proc do |path, &block|
      events << [:directory, path]
      [".", "..", "net", "future_ns", "invalid/name", "UPPER"].each { |name| block.call(name) }
    end
    readlink = proc do |path|
      events << [:link, path]
      "#{File.basename(path)}:[123]"
    end
    Dir.stub(:foreach, foreach) do
      File.stub(:readlink, readlink) do
        File.stub(:open, proc { |*_| raise "must not open namespace targets" }) do
          _, _, data = namespace_response
          assert_equal({ "future_ns" => "future_ns:[123]", "net" => "net:[123]" }, data["process"]["linux"]["namespaces"]["entries"])
          assert_equal "directory", data["process"]["linux"]["namespaces"]["discovery"]
          assert_equal [[:directory, "/proc/self/ns"], [:link, "/proc/self/ns/future_ns"], [:link, "/proc/self/ns/net"]], events
          assert_empty data["errors"]
        end
      end
    end
  end

  def test_both_permission_errors_try_each_known_name_once_after_enumeration
    [Errno::EACCES, Errno::EPERM].each do |error|
      events = []
      foreach = proc { |path| events << [:directory, path]; raise error }
      readlink = proc { |path| events << [:link, path]; "#{File.basename(path)}:[123]" }
      Dir.stub(:foreach, foreach) do
        File.stub(:readlink, readlink) do
          File.stub(:open, proc { |*_| raise "must not open namespace targets" }) do
            _, _, data = namespace_response
            info = data["process"]["linux"]["namespaces"]
            assert_equal %w[discovery entries limit truncated], info.keys.sort
            assert_equal "known_names_fallback", info["discovery"]
            assert_equal NAMES, info["entries"].keys
            assert_equal 64, info["limit"]
            assert_equal false, info["truncated"]
            assert_operator info["entries"].size, :<=, info["limit"]
            assert_equal [[:directory, "/proc/self/ns"]] + NAMES.map { |name| [:link, "/proc/self/ns/#{name}"] }, events
            assert_empty data["errors"]
          end
        end
      end
    end
  end

  def test_permission_failure_during_enumeration_discards_the_incomplete_listing
    foreach = proc do |path, &block|
      block.call("future_ns")
      raise Errno::EACCES
    end
    seen = []
    Dir.stub(:foreach, foreach) do
      File.stub(:readlink, proc { |path| seen << File.basename(path); "ns:[123]" }) do
        _, _, data = namespace_response
        assert_equal NAMES, seen
        refute data["process"]["linux"]["namespaces"]["entries"].key?("future_ns")
        assert_equal "known_names_fallback", data["process"]["linux"]["namespaces"]["discovery"]
        assert_empty data["errors"]
      end
    end
  end

  def test_missing_namespace_directories_remain_optional_without_probes
    [Errno::ENOENT, Errno::ENOTDIR].each do |error|
      seen = []
      Dir.stub(:foreach, proc { |*_| raise error }) do
        File.stub(:readlink, proc { |path| seen << path; raise "must not probe a missing directory" }) do
          _, _, data = namespace_response
          assert_equal Process.pid, data["process"]["pid"]
          refute data["process"].fetch("linux", {}).key?("namespaces")
          assert_empty seen
          assert_empty data["errors"]
        end
      end
    end
  end

  def test_other_enumeration_errors_do_not_trigger_fallback
    [Errno::EIO, RuntimeError, NotImplementedError].each do |error|
      seen = []
      Dir.stub(:foreach, proc { |*_| raise error }) do
        File.stub(:readlink, proc { |path| seen << path; "ns:[123]" }) do
          _, _, data = namespace_response
          assert_nil data["process"]["linux"]["namespaces"]
          assert_equal [PATH], data["errors"].keys
          assert_equal error.name, data["errors"][PATH]["class"]
          assert_empty seen
        end
      end
    end
  end

  def test_fallback_omits_unavailable_links_and_preserves_other_entries
    failures = {
      "cgroup" => Errno::ENOENT, "ipc" => Errno::ENOTDIR, "mnt" => Errno::EACCES,
      "pid" => Errno::EPERM, "pid_for_children" => Errno::EINVAL,
      "time" => NotImplementedError, "time_for_children" => LoadError, "user" => RuntimeError
    }
    seen = []
    readlink = proc do |path|
      name = File.basename(path)
      seen << name
      raise failures[name] if failures.key?(name)
      "#{name}:[123]"
    end
    Dir.stub(:foreach, proc { |*_| raise Errno::EACCES }) do
      File.stub(:readlink, readlink) do
        _, _, data = namespace_response
        assert_equal({ "net" => "net:[123]", "uts" => "uts:[123]" }, data["process"]["linux"]["namespaces"]["entries"])
        assert_equal NAMES, seen
        assert_equal Process.pid, data["process"]["pid"]
        assert_empty data["errors"]
      end
    end
  end

  def test_all_failed_fallback_probes_return_empty_entries_without_errors
    seen = []
    Dir.stub(:foreach, proc { |*_| raise Errno::EPERM }) do
      File.stub(:readlink, proc { |path| seen << path; raise Errno::ENOENT }) do
        _, _, data = namespace_response
        assert_equal({ "limit" => 64, "truncated" => false, "discovery" => "known_names_fallback", "entries" => {} }, data["process"]["linux"]["namespaces"])
        assert_equal NAMES.size, seen.size
        assert_equal Process.pid, data["process"]["pid"]
        assert_empty data["errors"]
      end
    end
  end

  def test_fallback_preserves_the_link_size_bound
    readlink = proc do |path|
      case File.basename(path)
      when "net" then "x" * Linux::LINK_BYTES
      when "mnt" then "x" * (Linux::LINK_BYTES + 1)
      else raise Errno::ENOENT
      end
    end
    Dir.stub(:foreach, proc { |*_| raise Errno::EACCES }) do
      File.stub(:readlink, readlink) do
        _, _, data = namespace_response
        assert_equal({ "net" => "x" * Linux::LINK_BYTES }, data["process"]["linux"]["namespaces"]["entries"])
        assert_empty data["errors"]
      end
    end
  end

  def test_fallback_dotted_selection_reads_only_the_requested_link
    seen = []
    Dir.stub(:foreach, proc { |*_| raise Errno::EACCES }) do
      File.stub(:readlink, proc { |path| seen << path; "net:[123]" }) do
        _, _, data = namespace_response("-all,#{PATH}.entries.net,errors")
        assert_equal({ "entries" => { "net" => "net:[123]" } }, data["process"]["linux"]["namespaces"])
        assert_equal ["/proc/self/ns/net"], seen
        assert_empty data["errors"]
      end
    end
  end

  def test_discovery_only_selects_directory_without_reading_links
    directories = []
    Dir.stub(:foreach, proc { |path, &block| directories << path; block.call("net") }) do
      File.stub(:readlink, proc { |*_| raise "must not read namespace links" }) do
        _, _, data = namespace_response("-all,#{PATH}.discovery,errors")
        assert_equal({ "discovery" => "directory" }, data["process"]["linux"]["namespaces"])
        assert_equal ["/proc/self/ns"], directories
        assert_empty data["errors"]
      end
    end
  end

  def test_discovery_only_selects_fallback_without_reading_links
    directories = []
    Dir.stub(:foreach, proc { |path| directories << path; raise Errno::EACCES }) do
      File.stub(:readlink, proc { |*_| raise "must not read namespace links" }) do
        _, _, data = namespace_response("-all,#{PATH}.discovery,errors")
        assert_equal({ "discovery" => "known_names_fallback" }, data["process"]["linux"]["namespaces"])
        assert_equal ["/proc/self/ns"], directories
        assert_empty data["errors"]
      end
    end
  end

  def test_discovery_can_be_explicitly_excluded
    Dir.stub(:foreach, proc { |_, &block| block.call("net") }) do
      File.stub(:readlink, "net:[123]") do
        _, _, data = namespace_response("-all,#{PATH},-#{PATH}.discovery,errors")
        assert_equal({ "limit" => 64, "truncated" => false, "entries" => { "net" => "net:[123]" } }, data["process"]["linux"]["namespaces"])
        assert_empty data["errors"]
      end
    end
  end

  def test_fallback_does_not_probe_excluded_links
    seen = []
    Dir.stub(:foreach, proc { |*_| raise Errno::EPERM }) do
      File.stub(:readlink, proc { |path| seen << File.basename(path); "ns:[123]" }) do
        _, _, data = namespace_response("-all,#{PATH},-#{PATH}.entries.net,errors")
        assert_equal NAMES - ["net"], seen
        refute data["process"]["linux"]["namespaces"]["entries"].key?("net")
        assert_empty data["errors"]
      end
    end
  end

  def test_fallback_truncation_only_does_not_read_links
    directories = []
    links = []
    Dir.stub(:foreach, proc { |path| directories << path; raise Errno::EACCES }) do
      File.stub(:readlink, proc { |path| links << path; "ns:[123]" }) do
        _, _, data = namespace_response("-all,#{PATH}.truncated,errors")
        assert_equal({ "truncated" => false }, data["process"]["linux"]["namespaces"])
        assert_equal ["/proc/self/ns"], directories
        assert_empty links
        assert_empty data["errors"]
      end
    end
  end

  def test_fatal_enumeration_errors_propagate
    [SystemExit, Interrupt].each do |error|
      Dir.stub(:foreach, proc { |*_| raise error }) do
        assert_raises(error) { namespace_response }
      end
    end
  end

  def test_fatal_fallback_link_errors_propagate
    [SystemExit, Interrupt].each do |error|
      Dir.stub(:foreach, proc { |*_| raise Errno::EACCES }) do
        File.stub(:readlink, proc { |*_| raise error }) do
          assert_raises(error) { namespace_response }
        end
      end
    end
  end

  def test_normal_namespace_link_failures_keep_their_error_entries
    foreach = proc { |path, &block| %w[mnt net].each { |name| block.call(name) } }
    readlink = proc do |path|
      raise Errno::EACCES if path.end_with?("/mnt")
      "net:[123]"
    end
    Dir.stub(:foreach, foreach) do
      File.stub(:readlink, readlink) do
        _, _, data = namespace_response
        assert_equal({ "mnt" => nil, "net" => "net:[123]" }, data["process"]["linux"]["namespaces"]["entries"])
        assert_equal ["#{PATH}.entries.mnt"], data["errors"].keys
        assert_equal "Errno::EACCES", data["errors"]["#{PATH}.entries.mnt"]["class"]
      end
    end
  end

  def test_fd_directory_permission_errors_do_not_use_namespace_fallback
    seen = []
    Dir.stub(:foreach, proc { |*_| raise Errno::EACCES }) do
      File.stub(:readlink, proc { |path| seen << path; "ns:[123]" }) do
        _, _, data = namespace_response("-all,process.linux.fd_details,errors")
        assert_nil data["process"]["linux"]["fd_details"]
        assert_equal ["process.linux.fd_details"], data["errors"].keys
        assert_equal "Errno::EACCES", data["errors"]["process.linux.fd_details"]["class"]
        assert_empty seen
      end
    end
  end

  def test_fallback_names_do_not_retain_request_mutations
    Dir.stub(:foreach, proc { |*_| raise Errno::EACCES }) do
      first = Linux.namespace_names
      second = Linux.namespace_names
      refute_same first, second
      refute_same first["names"], second["names"]
      first["names"].clear
      assert_equal NAMES, second["names"]
      assert_equal NAMES, Linux.namespace_names["names"]
      assert Linux::KNOWN_NAMESPACE_NAMES.frozen?
      assert Linux::KNOWN_NAMESPACE_NAMES.all? { |name| name.frozen? }
    end
  end
end
