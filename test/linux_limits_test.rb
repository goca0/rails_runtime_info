# frozen_string_literal: true

require "test_helper"

class LinuxLimitsTest < Minitest::Test
  Linux = RailsRuntimeInfo::LinuxProcess
  PATH = "process.linux.limits".freeze

  def linux_response(expression)
    with_constant(Object, :RUBY_PLATFORM, "x86_64-linux-test") { response(what_env(expression)) }
  end

  def test_padded_rows_preserve_values_and_units
    text = "Limit                     Soft Limit           Hard Limit           Units\n" \
      "Max cpu time              unlimited            unlimited            seconds   \n" \
      "Max open files            1024                 1048576              files     \n" \
      "Max stack size            8388608              unlimited            bytes     \n" \
      "Max nice priority         0                    0                    \n"
    assert_equal({
      "max_cpu_time" => { "soft" => "unlimited", "hard" => "unlimited", "units" => "seconds" },
      "max_open_files" => { "soft" => 1024, "hard" => 1048576, "units" => "files" },
      "max_stack_size" => { "soft" => 8388608, "hard" => "unlimited", "units" => "bytes" },
      "max_nice_priority" => { "soft" => 0, "hard" => 0, "units" => nil }
    }, Linux.parse_limits(text))
  end

  def test_single_space_columns_keep_twenty_digit_integers_exact
    value = 18446744073709551614
    result = Linux.parse_limits("Max file size #{value} #{value} bytes\n")
    assert_equal({ "soft" => value, "hard" => value, "units" => "bytes" }, result["max_file_size"])
    assert_instance_of Integer, result["max_file_size"]["soft"]
  end

  def test_tabs_crlf_padding_and_decimal_leading_zeroes
    text = "\tMax\topen files\t0008\t0010\tfiles \t\r\nMax realtime priority\t0\t0\t\r\n"
    assert_equal({
      "max_open_files" => { "soft" => 8, "hard" => 10, "units" => "files" },
      "max_realtime_priority" => { "soft" => 0, "hard" => 0, "units" => nil }
    }, Linux.parse_limits(text))
  end

  def test_unknown_resource_names_and_unit_tokens_need_no_fixed_list
    text = "Max future-v2 resource 7 99 widgets\nMax future_resource 1 unlimited items"
    assert_equal({
      "max_future_v2_resource" => { "soft" => 7, "hard" => 99, "units" => "widgets" },
      "max_future_resource" => { "soft" => 1, "hard" => "unlimited", "units" => "items" }
    }, Linux.parse_limits(text))
  end

  def test_headers_empty_input_and_malformed_rows_are_skipped
    text = ["Limit Soft Limit Hard Limit Units", "", "nonsense", "Max missing 1",
      "Max negative -1 2 bytes", "Max negative 1 -2 bytes", "Max fraction 1.5 2 bytes",
      "Max exponent 1e3 2 bytes", "Max infinity inf 2 bytes", "Max extra 1 2 bytes extra",
      "Max bad 1\x002 3 bytes", "Max bad\xff 1 2 bytes"].join("\n").b
    assert_equal({}, Linux.parse_limits(text))
    assert_equal({}, Linux.parse_limits(""))
  end

  def test_malformed_line_does_not_consume_or_discard_next_valid_line
    text = "Max incomplete 1\nMax open files 12 34 files\nMax broken -1 0\nMax nice priority 0 0\n"
    result = Linux.parse_limits(text)
    assert_equal ["max_open_files", "max_nice_priority"], result.keys
    assert_equal 12, result["max_open_files"]["soft"]
    assert_nil result["max_nice_priority"]["units"]
  end

  def test_endpoint_returns_only_parsed_limits_and_reads_once_with_existing_bound
    seen = []
    reader = proc do |path, limit|
      seen << [path, limit]
      "Limit Soft Limit Hard Limit Units\nMax open files 12 34 files\n"
    end
    RailsRuntimeInfo::Support.stub(:read_file, reader) do
      status, _, data = linux_response("-all,#{PATH},errors")
      assert_equal 200, status
      assert_equal({ "process" => { "linux" => { "limits" => {
        "max_open_files" => { "soft" => 12, "hard" => 34, "units" => "files" }
      } } }, "errors" => {} }, data)
    end
    assert_equal [["/proc/self/limits", 64 * 1024]], seen
  end

  def test_dotted_selection_projects_a_single_parsed_value
    Linux.stub(:read, "Max open files 12 34 files\nMax stack size 1 2 bytes\n") do
      _, _, data = linux_response("-all,#{PATH}.max_open_files.soft,errors")
      assert_equal({ "max_open_files" => { "soft" => 12 } }, data["process"]["linux"]["limits"])
      assert_empty data["errors"]
    end
  end

  def test_excluding_limits_skips_reading_and_parsing
    forbid = proc { |*_| raise "excluded limits must not be read or parsed" }
    Linux.stub(:read, forbid) do
      Linux.stub(:parse_limits, forbid) do
        _, _, data = linux_response("-all,process.linux.limits,-process.linux.limits,process.pid,errors")
        assert_equal Process.pid, data["process"]["pid"]
        refute data["process"].fetch("linux", {}).key?("limits")
        assert_empty data["errors"]
      end
    end
  end

  def test_unreadable_or_oversize_file_preserves_unrelated_diagnostics
    [Errno::EACCES, Errno::ENOENT, RailsRuntimeInfo::Support::FileTooLarge].each do |error|
      Linux.stub(:read, proc { |*_| raise error, "synthetic failure" }) do
        _, _, data = linux_response("-all,#{PATH},process.pid,errors")
        assert_equal Process.pid, data["process"]["pid"]
        assert_nil data["process"]["linux"]["limits"]
        assert_equal [PATH], data["errors"].keys
        assert_equal error.name, data["errors"][PATH]["class"]
      end
    end
  end

  def test_parser_failure_is_isolated_and_fatal_failure_propagates
    Linux.stub(:read, "Max open files 12 34 files\n") do
      Linux.stub(:parse_limits, proc { |*_| raise ArgumentError, "synthetic failure" }) do
        _, _, data = linux_response("-all,#{PATH},process.pid,errors")
        assert_equal Process.pid, data["process"]["pid"]
        assert_nil data["process"]["linux"]["limits"]
        assert_equal "ArgumentError", data["errors"][PATH]["class"]
      end
      Linux.stub(:parse_limits, proc { |*_| raise SystemExit }) do
        assert_raises(SystemExit) { linux_response("-all,#{PATH}") }
      end
    end
  end

  def test_non_linux_does_not_read_or_parse_limits
    forbid = proc { |*_| raise "must not access Linux limits" }
    with_constant(Object, :RUBY_PLATFORM, "x86_64-darwin-test") do
      Linux.stub(:read, forbid) do
        Linux.stub(:parse_limits, forbid) do
          _, _, data = response(what_env("-all,process.linux,errors"))
          assert_equal({ "available" => false }, data["process"]["linux"])
          assert_empty data["errors"]
        end
      end
    end
  end

  def test_live_linux_limits
    skip "Linux procfs required" unless RUBY_PLATFORM.include?("linux") && File.file?("/proc/self/limits")
    result = Linux.parse_limits(Linux.read("/proc/self/limits"))
    assert_kind_of Hash, result
    assert_equal "files", result.fetch("max_open_files").fetch("units")
    assert result["max_open_files"].values_at("soft", "hard").all? { |value| Integer === value || value == "unlimited" }
    assert_nil result.fetch("max_nice_priority").fetch("units")
  end
end
