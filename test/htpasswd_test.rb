# frozen_string_literal: true

require "test_helper"

class HtpasswdTest < Minitest::Test
  VERIFIER = RailsRuntimeInfo::Htpasswd
  # Independently generated with Python hashlib.sha1 and base64, not the
  # verifier under test: password sample-pass, binary salt "\x00salt\xff".
  SSHA = "{SSHA}7f5oxwoLw9l/oUGGRBiKWy6vhH0Ac2FsdP8=".freeze

  def verify(contents, user = "alice", password = "sample-pass")
    RailsRuntimeInfo::Support.stub(:read_file, contents.b) do
      VERIFIER.verify("/test/diagnostics.htpasswd", user.b, password.b)
    end
  end

  def test_plain_matches_exact_password
    assert verify("alice:{PLAIN}sample-pass\n")
    refute verify("alice:{PLAIN}sample-pass\n", "alice", "wrong")
    refute verify("alice:{PLAIN}sample-pass\n", "Alice")
    refute verify("alice:{PLAIN}sample-pass\n", "missing")
  end

  def test_known_ssha_vector_and_wrong_passwords
    assert verify("alice:#{SSHA}\n")
    refute verify("alice:#{SSHA}\n", "alice", "sample-past")
    refute verify("alice:#{SSHA}\n", "alice", "sample-pas")
    refute verify("alice:#{SSHA}\n", "alice", "sample-passx")
  end

  def test_ssha_password_can_contain_colons
    value = "alice:{SSHA}134DOeCeTYcz0hhQCMpyU26xJntOYUNs"
    assert verify(value, "alice", "a:b:c")
    refute verify(value, "alice", "a")
  end

  def test_multiple_users_comments_crlf_and_final_line_without_newline
    text = "# test fixture\r\n \t# another comment\r\n\t \r\nalice:#{SSHA}:salted:test\r\nbob:{PLAIN}other-pass:plain:test"
    assert verify(text)
    assert verify(text, "bob", "other-pass")
    refute verify(text, "bob", "sample-pass")
    refute verify(text, "alice", "other-pass")
  end

  def test_plain_preserves_spaces_and_hash_sign
    assert verify("alice:{PLAIN} # spaced password \n", "alice", " # spaced password ")
    refute verify("alice:{PLAIN} # spaced password \n", "alice", "# spaced password")
  end

  def test_colon_starts_trailing_comment_not_part_of_plain_password
    assert verify("alice:{PLAIN}pass:comment", "alice", "pass")
    refute verify("alice:{PLAIN}pass:comment", "alice", "pass:comment")
  end

  def test_non_ascii_credentials_are_compared_as_bytes_without_normalization
    user = "u\xc5\xbe".b
    password = "p\xc5\x99".b
    assert verify(user + ":{PLAIN}" + password, user, password)
    refute verify(user + ":{PLAIN}" + password, user, "p?")
    assert verify("alice:{SSHA}iCsJeKVHwVN8QvJJR71eCqps+YwxMjM0", "alice", "\xc5\xbe\xc5\x99lu\xc5\xa5ou\xc4\x8dk\xc3\xbd")
  end

  def test_invalid_lines_reject_the_entire_file_even_after_a_valid_user
    invalid = ["missing-colon", ":{PLAIN}pass", "alice:", "bad\tuser:{PLAIN}pass", "bad\x00user:{PLAIN}pass"]
    invalid.each do |line|
      assert_raises(VERIFIER::InvalidFile) { verify("good:{PLAIN}sample-pass\n#{line}\n", "good") }
    end
  end

  def test_empty_or_comment_only_file_is_invalid
    ["", "\n\t \n", "# nobody here\n"].each do |text|
      assert_raises(VERIFIER::InvalidFile) { verify(text) }
    end
  end

  def test_duplicate_names_fail_closed_instead_of_selecting_a_password
    assert_raises(VERIFIER::InvalidFile) { verify("alice:{PLAIN}sample-pass\nalice:{PLAIN}other") }
    assert_raises(VERIFIER::InvalidFile) { verify("alice:{PLAIN}sample-pass\nalice:#{SSHA}") }
  end

  def test_unsupported_algorithms_and_unprefixed_plaintext_are_rejected
    ["sample-pass", "{SHA}aaaa", "{ssha}aaaa", "{plain}sample-pass", "$apr1$anything", "$2y$anything", "{CRYPT}abc"].each do |value|
      assert_raises(VERIFIER::InvalidFile) { verify("alice:#{value}") }
    end
  end

  def test_malformed_ssha_rejected_strictly
    invalid = ["", "!!!!", "YWJj", "YWJj\t", ["x" * 19].pack("m0"), ["x" * 20].pack("m0"), "7f5oxwoLw9l/oUGGRBiKWy6vhH0Ac2FsdP8", "7f5oxwoLw9l/oUGGRBiKWy6vhH0Ac2FsdP8=garbage"]
    invalid.each do |encoded|
      assert_raises(VERIFIER::InvalidFile) { verify("alice:{SSHA}#{encoded}") }
    end
  end

  def test_empty_plain_and_control_characters_are_invalid
    ["", "abc\x00def", "abc\tdef", "abc\rdef", "abc\x7fdef"].each do |password|
      assert_raises(VERIFIER::InvalidFile) { verify("alice:{PLAIN}#{password}") }
    end
  end

  def test_file_reader_is_bounded_and_called_each_time
    reads = []
    reader = proc do |path, limit|
      reads << [path, limit]
      "alice:{PLAIN}sample-pass\n"
    end
    RailsRuntimeInfo::Support.stub(:read_file, reader) do
      2.times { assert VERIFIER.verify("/test/pw", "alice", "sample-pass") }
    end
    assert_equal [["/test/pw", 65_536], ["/test/pw", 65_536]], reads
    assert_equal [], VERIFIER.instance_variables
  end

  def test_fixed_compare_visits_every_byte_even_after_a_mismatch
    left = "abcdef".dup
    visits = []
    left.define_singleton_method(:getbyte) { |index| visits << index; super(index) }
    refute VERIFIER.send(:fixed_compare, left, "xbcdef")
    assert_equal [0, 1, 2, 3, 4, 5], visits
    assert VERIFIER.send(:fixed_compare, "abc", "abc")
    refute VERIFIER.send(:fixed_compare, "abc", "ab")
  end
end
