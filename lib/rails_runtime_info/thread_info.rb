# frozen_string_literal: true

module RailsRuntimeInfo
  # Request-local inspection through core readers only. Never dispatch methods
  # through an application's Thread instance or enumerate its local variables.
  class ThreadInfo
    INVENTORY_LIMIT = 256
    BACKTRACE_THREAD_LIMIT = 64
    FRAME_LIMIT = 64
    TEXT_BYTES = 1024

    def self.list
      method = Thread.method(:list)
      # A Ruby replacement/prepend may do arbitrary work. Do not try to recover
      # an "original" implementation or force support on another Ruby engine.
      return nil unless method.owner == Thread.singleton_class && method.source_location.nil?
      threads = method.call
      unless Object.instance_method(:class).bind(threads).call == Array
        raise TypeError, "Thread.list did not return a plain Array"
      end
      threads
    end

    def self.reader(name)
      owner = name == :__id__ ? BasicObject : Thread
      method = owner.instance_method(name)
      method if method.owner == owner && method.source_location.nil?
    rescue NameError
      nil
    end

    def self.read(method, thread, *args)
      raise TypeError, "expected a Thread" unless Thread === thread
      method.bind(thread).call(*args)
    end

    def self.text(value)
      klass = Object.instance_method(:class).bind(value).call
      raise TypeError, "expected a String" unless klass <= String
      size = String.instance_method(:bytesize).bind(value).call
      prefix = String.instance_method(:byteslice).bind(value).call(0, TEXT_BYTES)
      [prefix, size > TEXT_BYTES]
    end

    def self.backtrace(method, thread)
      # Request a bounded prefix plus one frame to detect truncation. Never
      # retry without arguments on a runtime that rejects the bounded API.
      frames = read(method, thread, 0, FRAME_LIMIT + 1)
      return nil if frames.nil? # A thread may have exited after enumeration.
      unless Object.instance_method(:class).bind(frames).call == Array
        raise TypeError, "Thread#backtrace did not return a plain Array"
      end
      text_truncated = false
      result = frames.first(FRAME_LIMIT).map do |frame|
        prefix, truncated = text(frame)
        text_truncated ||= truncated
        prefix
      end
      { "frames" => result, "frames_truncated" => frames.size > FRAME_LIMIT,
        "frame_text_truncated" => text_truncated }
    end
  end
end
