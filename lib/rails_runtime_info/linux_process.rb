# frozen_string_literal: true

module RailsRuntimeInfo
  class LinuxProcess
    SMALL_FILE_LIMIT = 64 * 1024
    MAPS_LIMIT = 2 * 1024 * 1024

    def self.read(path, limit = SMALL_FILE_LIMIT)
      Support.read_file(path, limit)
    end

    def self.fields(text)
      result = {}
      text.each_line do |line|
        match = /\A([A-Za-z_][A-Za-z0-9_]*):[ \t]*(.*?)\s*\z/.match(line)
        result[match[1]] = match[2] if match
      end
      result
    end

    def self.fd_count
      count = 0
      Dir.foreach("/proc/self/fd") { |name| count += 1 unless name == "." || name == ".." }
      count
    end

    # Only parse the two fields we need. comm may contain spaces, newlines and
    # parentheses, so splitting the whole line on whitespace is not safe.
    def self.parse_stat(text)
      opening = /\A([0-9]+) \(/.match(text)
      closing = text.rindex(")")
      unless opening && closing && closing >= opening.end(0)
        raise ArgumentError, "unrecognized procfs stat"
      end
      fields = text[(closing + 1)..-1].split
      tid = Integer(opening[1], 10)
      ticks = Integer(fields.fetch(19), 10) # field 22; state is field 3
      raise ArgumentError, "invalid procfs task ID" unless tid > 0
      raise ArgumentError, "invalid procfs start ticks" unless ticks >= 0
      { "tid" => tid, "start_ticks_since_boot" => ticks }
    end

    def self.start_time
      lifetime(parse_stat(read("/proc/self/stat")).fetch("start_ticks_since_boot"))
    end

    def self.lifetime(ticks)
      raise ArgumentError, "invalid procfs start ticks" unless Integer === ticks && ticks >= 0
      require "etc"
      ticks_per_second = Etc.sysconf(Etc::SC_CLK_TCK)
      unless Integer === ticks_per_second && ticks_per_second > 0
        raise ArgumentError, "invalid SC_CLK_TCK"
      end
      uptime = Float(read("/proc/uptime").split.fetch(0))
      raise ArgumentError, "invalid procfs uptime" unless uptime.finite? && uptime >= 0
      age = uptime - ticks.to_f / ticks_per_second
      raise ArgumentError, "invalid procfs age" unless age.finite?
      {
        "start_ticks_since_boot" => ticks,
        "clock_ticks_per_second" => ticks_per_second,
        "age_seconds" => [age, 0.0].max,
        "started_at_utc_approximate" => Support.utc(Time.now - age)
      }
    end

    def self.current_native_thread_id
      thread = Thread.current
      thread.native_thread_id if thread.respond_to?(:native_thread_id)
    end

    def self.current_thread_stat
      failure = nil
      begin
        tid = current_native_thread_id
        # Never interpolate/coerce an opaque or unexpected API result. The task
        # directory predates /proc/thread-self and works on old Linux kernels.
        if Integer === tid && tid > 0
          stat = parse_stat(read("/proc/self/task/#{tid}/stat"))
          unless stat.fetch("tid") == tid
            raise ArgumentError, "native thread ID does not match procfs stat"
          end
          return stat
        end
      rescue Errno::ENOENT, Errno::ENOTDIR, NotImplementedError
        # Missing facilities are expected on some Ruby/kernel combinations.
      rescue StandardError, LoadError => error
        failure = error
      end

      # Also fall back after an ordinary native-ID or task-file failure, not
      # merely when the Ruby API is absent. Each path is tried at most once.
      begin
        parse_stat(read("/proc/thread-self/stat"))
      rescue Errno::ENOENT, Errno::ENOTDIR
        # Both paths unavailable: omit the section. Do not hide an unexpected
        # failure in the first path when the fallback cannot recover it.
        raise failure if failure
        nil
      end
    end

    def self.allocator_hints
      # Mapped library names are evidence, not proof of the allocator actually
      # serving Ruby allocations. Static linkage will not appear here.
      read("/proc/self/maps", MAPS_LIMIT).each_line.select do |line|
        line =~ /(?:jemalloc|tcmalloc|mimalloc)/i
      end.map { |line| line.split(/\s+/, 6).last.to_s.strip }.uniq
    end
  end
end
