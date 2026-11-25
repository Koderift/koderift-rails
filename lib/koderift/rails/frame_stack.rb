# frozen_string_literal: true

module Koderift
  module Rails
    # A per-thread stack of frames for one kind of state, and the thread-local
    # keys that state is published under.
    #
    # Each unit of work (a request, a Sidekiq job, a transaction) pushes a frame
    # when it starts and pops it when it ends. Units nest: a transaction inside a
    # request, a job run with perform_inline inside another job. The rule for
    # popping is what makes nesting safe:
    #
    # * A frame that is no longer on the stack touches nothing. That is an
    #   abandoned non-block transaction finished long after the unit it was
    #   started in has ended. Restoring its saved state would hand the earlier
    #   request's trace and collections to whatever runs now.
    # * Otherwise everything from that frame upward is dropped, so an abandoned
    #   transaction started inside the unit goes with it, and the frame below is
    #   published again.
    # * When the stack empties, the published keys are cleared, or, for a frame
    #   created with restore_outside, set back to what they held before the
    #   first frame was pushed. Requests and jobs clear: Puma and Sidekiq reuse
    #   threads, and nothing from one unit may reach the next.
    class FrameStack
      # Mixed into frame classes.
      module Member
        attr_accessor :outside

        def restore_outside?
          @restore_outside ? true : false
        end
      end

      def initialize(stack_key, published_keys, &values_for)
        @stack_key      = stack_key
        @published_keys = published_keys
        @values_for     = values_for
      end

      def push(frame)
        stack = (Thread.current[@stack_key] ||= [])
        frame.outside = @published_keys.map { |key| Thread.current[key] } if stack.empty?
        stack.push(frame)
        publish(@values_for.call(frame))
        frame
      end

      # Returns true when the frame was found and popped.
      def pop(frame)
        stack = Thread.current[@stack_key]
        return false unless stack

        index = stack.rindex { |f| f.equal?(frame) }
        return false unless index

        bottom = stack.first
        stack.slice!(index..-1)

        if stack.empty?
          Thread.current[@stack_key] = nil
          publish(bottom.restore_outside? ? bottom.outside : nil)
        else
          publish(@values_for.call(stack.last))
        end
        true
      end

      def include?(frame)
        stack = Thread.current[@stack_key]
        stack ? stack.any? { |f| f.equal?(frame) } : false
      end

      # Whether any frame on this thread's stack matches the block.
      def any?
        stack = Thread.current[@stack_key]
        stack ? stack.any? { |f| yield f } : false
      end

      def top
        stack = Thread.current[@stack_key]
        stack && stack.last
      end

      def clear!
        Thread.current[@stack_key] = nil
        publish(nil)
      end

      private

      def publish(values)
        @published_keys.each_with_index do |key, i|
          Thread.current[key] = values && values[i]
        end
      end
    end
  end
end
