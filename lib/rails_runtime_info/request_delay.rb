# frozen_string_literal: true

module RailsRuntimeInfo
  # Stateless, query-only parsing. Validation never waits or reads rack.input.
  class RequestDelay
    MAX_SECONDS = 30
    MAX_VALUE_BYTES = 64

    class Invalid < StandardError; end

    def self.seconds(query_string)
      return 0.0 unless query_string.kind_of?(String) && !query_string.empty?
      require "uri"
      found = false
      seconds = 0.0
      # Match Selection's form decoding, including percent-encoded keys. Leave
      # unrelated values alone; neither Rails/Rack params nor a body is parsed.
      String.new(query_string).force_encoding(Encoding::BINARY).each_line("&") do |pair|
        raw_key, raw_value = pair.chomp("&").split("=", 2)
        next unless raw_key
        begin
          key = URI.decode_www_form_component(raw_key)
        rescue ArgumentError
          next
        end
        next unless key == "sleep"
        raise Invalid, "sleep may be specified only once" if found
        found = true
        seconds = parse_seconds(raw_value || "")
      end
      seconds
    end

    def self.parse_seconds(raw_value)
      if raw_value.bytesize > MAX_VALUE_BYTES * 3
        raise Invalid, "sleep exceeds #{MAX_VALUE_BYTES} decoded bytes"
      end
      begin
        value = URI.decode_www_form_component(raw_value)
      rescue ArgumentError
        raise Invalid, "sleep contains invalid percent encoding"
      end
      if value.bytesize > MAX_VALUE_BYTES
        raise Invalid, "sleep exceeds #{MAX_VALUE_BYTES} decoded bytes"
      end
      unless /\A[0-9]+(?:\.[0-9]+)?\z/n.match(value.b)
        raise Invalid, "sleep must be an unsigned decimal number from 0 to #{MAX_SECONDS} seconds"
      end
      whole, fraction = value.split(".", 2)
      integer = whole.to_i
      # Check the exact decimal boundary before Float conversion: a value just
      # above 30 must not become acceptable through floating-point rounding.
      if integer > MAX_SECONDS || (integer == MAX_SECONDS && fraction && /[1-9]/.match(fraction))
        raise Invalid, "sleep must not exceed #{MAX_SECONDS} seconds"
      end
      value.to_f
    end
    private_class_method :parse_seconds
  end
end
