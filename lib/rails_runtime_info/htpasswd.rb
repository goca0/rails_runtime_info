# frozen_string_literal: true

module RailsRuntimeInfo
  # Request-local verification of a small nginx/RFC2307-style password file.
  # No file contents, parsed entries, passwords or results are cached.
  module Htpasswd
    MAX_FILE_BYTES = 64 * 1024
    class InvalidFile < StandardError; end

    def self.verify(path, username, password)
      entries = parse(Support.read_file(path, MAX_FILE_BYTES))
      entry = entries[username]
      return false unless entry

      if entry[0] == :ssha
        # Explicit requires avoid Digest's lazy constant lookup in concurrent
        # first requests. All library loading remains request-time only.
        require "digest/sha1"
        fixed_compare(entry[1], Digest::SHA1.digest(password + entry[2]))
      else
        require "digest/sha2"
        # Compare fixed-size digests, not password Strings of varying lengths.
        fixed_compare(Digest::SHA256.digest(entry[1]), Digest::SHA256.digest(password))
      end
    end

    def self.parse(data)
      entries = {}
      data.each_line do |raw_line|
        line = raw_line.chomp("\n").chomp("\r")
        next if /\A[ \t]*(?:#|\z)/n.match(line)

        username, value, _comment = line.split(":", 3)
        if !username || username.empty? || /[\x00-\x1f\x7f]/n.match(username) || !value || entries.key?(username)
          raise InvalidFile, "invalid htpasswd file"
        end
        entries[username] = parse_value(value)
      end
      raise InvalidFile, "empty htpasswd file" if entries.empty?
      entries
    end

    def self.parse_value(value)
      if value.start_with?("{SSHA}")
        begin
          # m0 is Ruby's strict Base64 decoder (no separate base64 gem needed).
          decoded = value.byteslice(6, value.bytesize - 6).unpack("m0").first
        rescue ArgumentError
          raise InvalidFile, "invalid SSHA entry"
        end
        # A SHA-1 digest is 20 bytes; require at least one actual salt byte.
        raise InvalidFile, "unsalted or truncated SSHA entry" unless decoded.bytesize > 20
        [:ssha, decoded.byteslice(0, 20), decoded.byteslice(20, decoded.bytesize - 20)]
      elsif value.start_with?("{PLAIN}")
        password = value.byteslice(7, value.bytesize - 7)
        if password.empty? || /[\x00-\x1f\x7f]/n.match(password)
          raise InvalidFile, "invalid PLAIN entry"
        end
        [:plain, password]
      else
        # Do not guess algorithms, accept unprefixed plaintext or invoke crypt.
        raise InvalidFile, "unsupported htpasswd scheme"
      end
    end

    def self.fixed_compare(left, right)
      return false unless left.bytesize == right.bytesize
      difference = 0
      index = 0
      while index < left.bytesize
        difference |= left.getbyte(index) ^ right.getbyte(index)
        index += 1
      end
      difference == 0
    end

    private_class_method :parse, :parse_value, :fixed_compare
  end
end
