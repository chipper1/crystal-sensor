require "thread"

module Instana
  @@processor : ::Instana::Processor?

  def self.processor
    @@processor ||= ::Instana::Processor.new
  end

  class Processor
    def initialize
      # The main queue before being reported to the
      # host agent.  Traces in this queue are complete
      # and ready to be sent.
      @queue = Array(Trace).new

      # The staging queue that holds traces that have completed
      # but still have outstanding async spans.
      # Traces that have been in this queue for more than
      # 5 minutes are discarded.
      @staging_queue = Set(Trace).new

      # No access to the @staging_queue until this lock
      # is taken.
      @staging_lock = Mutex.new
    end

    # Adds a trace to the queue to be processed and
    # sent to the host agent
    #
    # @param [Trace] the trace to be added to the queue
    def add(trace)
      ::Instana.logger.debug("Queuing completed trace id: #{trace.id}")
      @queue.push(trace)
    end

    # Adds a trace to the staging queue.
    #
    # @param [Trace] the trace to be added to the queue
    def stage(trace)
      ::Instana.logger.debug("Staging incomplete trace id: #{trace.id}")
      @staging_queue.add(trace)
    end

    # This will run through the staged traces (if any) to find
    # completed or timed out incompleted traces.  Completed traces will
    # be added to the main @queue.  Timed out traces will be discarded
    #
    def process_staged
      @staging_lock.synchronize {
        if @staging_queue.size > 0
          @staging_queue.each do |t|
            if t.complete?
              ::Instana.logger.debug("Moving staged complete trace to main queue: #{t.id}")
              add(t)
              @staging_queue.delete(t)
            elsif t.discard?
              ::Instana.logger.debug("Discarding trace with uncompleted async spans over 5 mins old. id: #{t.id}")
              @staging_queue.delete(t)
            else
              false
            end
          end
        end
      }
    end

    ##
    # send
    #
    # Sends all traces in @queue to the host
    # agent
    #
    # FIXME: Add limits checking here in regards to:
    #   - Max HTTP Post size
    #   - Out of control/growing queue
    #   - Prevent another run of the timer while this is running
    #
    def send
      return if @queue.empty? || ENV["INSTANA_GEM_TEST"]?

      size = @queue.size
      if size > 100
        Instana.logger.debug "Trace queue is #{size}"
      end

      # Scan for any staged but incomplete traces that have now
      # completed.
      process_staged

      # Retrieve all spans for queued traces
      spans = queued_spans

      ::Instana.agent.report_spans(spans)
    end

    # Retrieves all of the traces in @queue and returns
    # the sum of their raw spans.
    # This is used by Processor::send and in the test suite.
    # Note that traces retrieved with this method are removed
    # entirely from the queue.
    #
    # @return [Array] An array of [Span] or empty
    #
    def queued_spans
      spans = [] of ::Instana::Span::JSONSpan

      if !@queue.empty?
        until @queue.empty?
          # Non-blocking pop; ignore exception
          trace = @queue.pop # FIXME rescue nil
          trace.spans.each do |s|
            spans << s.raw
          end
        end
      end
      spans
    end

    # Retrieves all of the traces that are in @queue.
    # Note that traces retrieved with this method are removed
    # entirely from the queue.
    #
    # @return [Array] An array of [Trace] or empty
    #
    def queued_traces
      traces = [] of Trace
      if !@queue.empty?
        until @queue.empty?
          # Non-blocking pop; ignore exception
          traces << @queue.pop(true) # FIXME rescue nil
        end
      end
      traces
    end

    # Retrieves a all staged traces from the staging queue.  Staged traces
    # are traces that have completed but may have outstanding
    # asynchronous spans.
    #
    # @return [Array]
    #
    def staged_traces
      traces = nil
      @staging_lock.synchronize {
        traces = @staging_queue.to_a
        @staging_queue.clear
      }
      traces
    end

    # Retrieves a single staged trace from the staging queue.  Staged traces
    # are traces that have completed but may have outstanding
    # asynchronous spans.
    #
    # @param trace_id [Integer] the Trace ID to be searched for
    #
    def staged_trace(trace_id)
      candidate = nil
      @staging_lock.synchronize {
        @staging_queue.each do |trace|
          if trace.id == trace_id
            candidate = trace
            break
          end
        end
      }
      unless candidate
        ::Instana.logger.debug("Couldn't find staged trace with trace_id: #{trace_id}")
      end
      candidate
    end

    # Get the number traces currently in the queue
    #
    # @return [Integer] the queue size
    #
    def queue_count
      @queue.size
    end

    # Get the number traces currently in the staging queue
    #
    # @return [Integer] the queue size
    #
    def staged_count
      @staging_queue.size
    end

    # Removes all traces from the @queue and @staging_queue.  Used in the
    # test suite to reset state.
    #
    def clear!
      until @queue.empty?
        # Non-blocking pop; ignore exception
        @queue.pop # FIXME rescue nil
      end
      @staging_queue.clear
    end
  end
end
