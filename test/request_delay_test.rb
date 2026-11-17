# frozen_string_literal: true

require "test_helper"

class RequestDelayTest < Minitest::Test
  DELAY = RailsRuntimeInfo::RequestDelay

  def parse_value(value)
    DELAY.seconds(URI.encode_www_form("sleep" => value))
  end

  def test_missing_parameter_or_non_string_query_means_no_delay
    [nil, "", false, 42, Object.new, "what=all", "token=sleep%3D30"].each do |query|
      assert_equal 0.0, DELAY.seconds(query)
    end
  end

  def test_valid_decimal_seconds_including_zero_and_maximum
    { "0" => 0.0, "0.0" => 0.0, "00" => 0.0, "1" => 1.0, "0.5" => 0.5,
      "01.25" => 1.25, "08" => 8.0, "15" => 15.0, "29.999" => 29.999,
      "30" => 30.0, "030.000" => 30.0 }.each do |value, expected|
      assert_equal expected, parse_value(value), value
    end
  end

  def test_invalid_number_syntax_is_not_coerced_to_zero
    ["", " ", " 1", "1 ", "+1", "-1", "-0", ".5", "1.", "1,5", "1_0",
     "1e1", "0x10", "NaN", "Infinity", "inf", "1/2", "1\n", "1\r", "1\t",
     "1\x00", "\xff".b, "1=2"].each do |value|
      assert_raises(DELAY::Invalid, value.inspect) { parse_value(value) }
    end
  end

  def test_greater_than_maximum_is_rejected_before_float_rounding
    ["31", "30.1", "30.00000000000000000000000000000001", "00030.000001", "9" * 64].each do |value|
      assert_raises(DELAY::Invalid, value) { parse_value(value) }
    end
  end

  def test_missing_value_is_invalid
    ["sleep", "sleep=", "sleep=&other=1"].each do |query|
      assert_raises(DELAY::Invalid, query) { DELAY.seconds(query) }
    end
  end

  def test_repeated_parameter_rejected_even_with_zero_or_encoded_key
    ["sleep=0&sleep=0", "sleep=1&sleep=2", "sl%65ep=1&sleep=1", "sleep=1&%73leep=1"].each do |query|
      error = assert_raises(DELAY::Invalid) { DELAY.seconds(query) }
      assert_match(/only once/, error.message)
    end
  end

  def test_decodes_key_and_value_using_query_form_rules
    assert_equal 0.5, DELAY.seconds("%73leep=%30%2e%35")
    assert_equal 2.0, DELAY.seconds("what=-all&sleep=2&")
    ["sleep=+1", "sleep=%2B1", "sleep=1+"].each do |query|
      assert_raises(DELAY::Invalid) { DELAY.seconds(query) }
    end
  end

  def test_malformed_sleep_percent_encoding_is_invalid
    ["sleep=%", "sleep=%0", "sleep=%GG"].each do |query|
      assert_raises(DELAY::Invalid) { DELAY.seconds(query) }
    end
  end

  def test_unrelated_values_and_malformed_keys_are_ignored
    query = "other=%GG&%broken=x&sleeping=10&Sleep=10&sleep[]=10&sleep=2"
    assert_equal 2.0, DELAY.seconds(query)
    assert_equal 0.0, DELAY.seconds("other=%GG&%broken=x&sleep[]=10&Sleep=10")
  end

  def test_decoded_length_limit_is_inclusive
    maximum = DELAY::MAX_VALUE_BYTES
    assert_equal 0.0, parse_value("0" * maximum)
    assert_equal 0.0, DELAY.seconds("sleep=" + "%30" * maximum)
    assert_raises(DELAY::Invalid) { parse_value("0" * (maximum + 1)) }
    assert_raises(DELAY::Invalid) { DELAY.seconds("sleep=" + "%30" * (maximum + 1)) }
  end

  def test_no_query_mutation_or_persistent_parser_state
    query = "sleep=0.5&what=all".freeze
    before_encoding = query.encoding
    assert_equal 0.5, DELAY.seconds(query)
    assert_equal "sleep=0.5&what=all", query
    assert_equal before_encoding, query.encoding
    assert_equal [], DELAY.instance_variables
  end

  def test_unknown_query_objects_are_not_coerced
    query = Object.new
    def query.to_s; raise "must not coerce"; end
    assert_equal 0.0, DELAY.seconds(query)
  end

  def test_tiny_positive_decimals_remain_positive
    seconds = parse_value("0." + "0" * 60 + "1")
    assert_operator seconds, :>, 0
    assert seconds.finite?
  end
end
