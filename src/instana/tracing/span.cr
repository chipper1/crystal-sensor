require "any_hash"

module Instana
  class Span
    REGISTERED_SPANS = [] of Symbol
    ENTRY_SPANS      = [] of Symbol
    EXIT_SPANS       = [] of Symbol
    HTTP_SPANS       = ENTRY_SPANS + EXIT_SPANS

    property parent : ::Instana::Span | Nil
    property baggage : AnyHash::JSON | Nil

    def initialize(name : Symbol, trace_id, parent_id = nil, start_time = Time.now)
      @data = AnyHash::JSON.new
      @data[:t] = trace_id                    # Trace ID
      @data[:s] = ::Instana::Util.generate_id # Span ID
      @data[:p] = parent_id if parent_id      # Parent ID
      @data[:ta] = :crystal                   # Agent

      # Entity Source
      @data[:f] = {:e => ::Instana.agent.report_pid,
                   :h => ::Instana.agent.agent_uuid}
      # Start time
      @data[:ts] = start_time.epoch_ms

      @parent = nil
      @baggage = nil

      # For entry spans, add a backtrace fingerprint
      add_stack(limit: 2) if ENTRY_SPANS.includes?(name)

      # Attach a backtrace to all exit spans
      add_stack if EXIT_SPANS.includes?(name)

      # Check for custom tracing
      if REGISTERED_SPANS.includes?(name)
        @data[:n] = name
      else
        configure_custom(name)
      end
    end

    # Adds a backtrace to this span
    #
    # @param limit [Integer] Limit the backtrace to the top <limit> frames
    #
    def add_stack(limit = nil, stack = CallStack.new.printable_backtrace)
      frame_count = 0
      @data[:stack] = [] of AnyHash::JSON

      stack.each do |i|
        break if limit && frame_count >= limit

        x = i.split(" ")

        if x.size == 4
          @data[:stack] = AnyHash::JSON.new({
            :f => x[0],
            :n => x[3],
            :m => x[1],
          })
        end
        frame_count = frame_count + 1 if limit
      end
    end

    # Log an error into the span
    #
    # @param e [Exception] The exception to be logged
    #
    def add_error(e)
      @data[:error] = true

      if @data[:ec]?
        @data[:ec] = @data[:ec] + 1
      else
        @data[:ec] = 1
      end

      # If a valid exception has been passed in, log the information about it
      # In case of just logging an error for things such as HTTP client 5xx
      # responses, an exception/backtrace may not exist.
      if e
        if e.backtrace.is_a?(Array)
          add_stack(stack: e.backtrace)
        end

        if HTTP_SPANS.includes?(@data[:n])
          error = {:error => "#{e.class}: #{e.message}"}
          http = {:http => error}
          set_tags(http)
        else
          log = {:log => {:message => e.message, :parameters => e.class.to_s}}
          set_tags(log)
        end
        # FIXME
        # e.instance_variable_set(:@instana_logged, true)
      end
      self
    end

    # Configure this span to be a custom span per the
    # SDK generic span type.
    #
    # @param name [String] name of the span
    # @param kvs [Hash] list of key values to be reported in the span
    #
    def configure_custom(name : Symbol)
      @data[:n] = :sdk
      @data[:data] = AnyHash::JSON.new({:sdk => {
        :name   => name,
        :custom => AnyHash::JSON.new,
      }})
      self
    end

    # Closes out the span.  This difference between this and
    # the finish method tells us how the tracing is being
    # performed (with OpenTracing or Instana default)
    #
    # @param end_time [Time] custom end time, if not now
    # @return [Span]
    #
    def close(end_time = Time.now)
      duration = end_time.epoch_ms - @data[:ts].as(Int64)
      @data[:d] = duration
      self
    end

    #############################################################
    # Accessors
    #############################################################

    # Retrieve the context of this span.
    #
    # @return [Instana::SpanContext]
    #
    def context
      @context ||= ::Instana::SpanContext.new(@data[:t], @data[:s], @baggage)
    end

    # Retrieve the ID for this span
    #
    # @return [Integer] the span ID
    def id
      @data[:s]
    end

    # Retrieve the Trace ID for this span
    #
    # @return [Integer] the Trace ID
    def trace_id
      @data[:t]
    end

    # Retrieve the parent ID of this span
    #
    # @return [Integer] parent span ID
    def parent_id
      @data[:p]
    end

    # Set the parent ID of this span
    #
    # @return [Integer] parent span ID
    def parent_id=(id)
      @data[:p] = id
    end

    # Get the name (operation) of this Span
    #
    # @return [String] or [Symbol] representing the span name
    def name
      if custom?
        @data[:data, :sdk, :name]
      else
        @data[:n]
      end
    end

    # Set the name (operation) for this Span
    #
    # @params name [String] or [Symbol]
    #
    def name=(n)
      if custom?
        @data[:data, :sdk, :name] = n
      else
        @data[:n] = n
      end
    end

    # Get the duration value for this Span
    #
    # @return [Integer] the duration in milliseconds
    def duration
      @data[:d]
    end

    # Indicates whether this span in the root span
    # in the Trace
    #
    # @return [Bool]
    #
    def is_root?
      @data[:s] == @data[:t]
    end

    # Hash accessor to the internal @data hash
    #
    def [](key : Symbol)
      @data[key]
    end

    # Hash setter to the internal @data hash
    #
    def []=(key : Symbol, value)
      @data[key] = value
    end

    # Hash key query to the internal @data hash
    #
    def []?(k)
      @data[k.to_sym]?
    end

    # Get the raw @data hash that summarizes this span
    #
    def raw
      @data
    end

    # Indicates whether this span is a custom or registered Span
    def custom?
      @data[:n] == :sdk
    end

    #############################################################
    # OpenTracing Compatibility Methods
    #############################################################

    # Set the name of the operation
    # Spec: OpenTracing API
    #
    # @params name [String] or [Symbol]
    #
    def operation_name=(name)
      @data[:n] = name
    end

    # Set a tag value on this span
    # Spec: OpenTracing API
    #
    # @param key [Symbol] the key of the tag
    # @param value [String, Numeric, Bool] the value of the tag. If it's not
    # a String, Numeric, or Bool it will be encoded with to_s
    #
    def set_tag(key : Symbol, value)
      if custom?
        @data[:data, :sdk, :custom, key] = value

        if key == :"span.kind"
          case value
          when :server || :consumer
            @data[:data, :sdk, :type] = :entry
          when :client || :producer
            @data[:data, :sdk, :type] = :exit
          end
        end
      else
        if !@data[:data, key]?
          @data[:data, key] = value
        elsif value.is_a?(Hash) && @data[:data, key].is_a?(Hash)
          @data[:data, key].merge!(value)
        else
          @data[:data, key] = value
        end
      end
      self
    end

    # Helper method to add multiple tags to this span
    #
    # @params tags [Hash]
    # @return [Span]
    #
    def set_tags(tags)
      return unless tags.is_a?(Hash)
      tags.each do |k, v|
        set_tag(k, v)
      end
      self
    end

    # Set a baggage item on the span
    # Spec: OpenTracing API
    #
    # @param key [String] the key of the baggage item
    # @param value [String] the value of the baggage item
    def set_baggage_item(key, value)
      if @baggage && @baggage.is_a?(Hash)
        @baggage[key] = value
      else
        @baggage = {key, value}
      end

      # Init/Update the SpanContext item
      if @context
        @context.baggage = @baggage
      else
        @context ||= ::Instana::SpanContext.new(@data[:t], @data[:s], @baggage)
      end
      self
    end

    # Get a baggage item
    # Spec: OpenTracing API
    #
    # @param key [String] the key of the baggage item
    # @return Value of the baggage item
    #
    def get_baggage_item(key)
      @baggage[key]
    end

    # Retrieve the hash of tags for this span
    #
    def tags(key = nil)
      if custom?
        tags = @data[:data, :sdk, :custom]
      else
        tags = @data[:data, key]
      end
      key ? tags[key] : tags
    end

    # Add a log entry to this span
    # Spec: OpenTracing API
    #
    # @param event [String] event name for the log
    # @param timestamp [Time] time of the log
    # @param fields [Hash] Additional information to log
    #
    def log(event = nil, _timestamp = Time.now, **fields)
      log = Hash{:log => Hash{:message => event, :parameters => fields}}
      set_tags(log)
    end

    # Finish the {Span}
    # Spec: OpenTracing API
    #
    # @param end_time [Time] custom end time, if not now
    #
    def finish(end_time = Time.now)
      unless end_time.is_a?(Time)
        ::Instana.logger.debug "span.finish: Passed #{end_time.class} instead of Time class"
      end

      if ::Instana.tracer.current_span.id != id
        ::Instana.logger.debug "Closing a span that isn't active. This will result in a broken trace: #{self.inspect}"
      end

      if is_root?
        # This is the root span for the trace.  Call log_end to close
        # out and queue the trace
        ::Instana.tracer.log_end(name, nil, end_time)
      else
        ::Instana.tracer.current_trace.end_span(nil, end_time)
      end
      self
    end
  end
end
