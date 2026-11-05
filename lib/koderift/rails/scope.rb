# frozen_string_literal: true

require 'koderift/rails/breadcrumb'

module Koderift
  module Rails
    # Sentry-compatible scope: ambient user/tags/extras/contexts merged into
    # every capture made while it is current.
    #
    # The stack is thread-local, and it is RESET at the end of every request and
    # Sidekiq job (see Controller and SidekiqMiddleware). That reset is not
    # housekeeping: Puma and Sidekiq both reuse threads, so without it a tag set
    # for one user's request would silently attach to the next request served by
    # that thread.
    class Scope
      STACK_KEY = :koderift_scope_stack

      attr_reader :user, :tags, :extras, :contexts
      attr_accessor :level, :fingerprint, :component, :action

      def initialize
        @user        = {}
        @tags        = {}
        @extras      = {}
        @contexts    = {}
        @level       = nil
        @fingerprint = nil
        @component   = nil
        @action      = nil
      end

      class << self
        def stack
          Thread.current[STACK_KEY] ||= [new]
        end

        def current
          stack.last
        end

        def push
          stack.push(current.dup)
          current
        end

        def pop
          stack.pop if stack.size > 1
          current
        end

        def reset!
          Thread.current[STACK_KEY] = nil
        end

        # Runs `block` against a temporary copy of the current scope before
        # yielding, so `capture_exception(e) { |scope| scope.set_tags(...) }`
        # cannot leak those tags into later captures on the same thread.
        def with_temporary(block)
          return yield unless block

          push
          begin
            block.call(current)
            yield
          ensure
            pop
          end
        end
      end

      def set_user(hash)
        @user = stringify(hash)
        self
      end

      def set_tags(hash)
        @tags.merge!(stringify(hash))
        self
      end

      def set_tag(key, value)
        @tags[key.to_s] = value
        self
      end

      def set_extras(hash)
        @extras.merge!(stringify(hash))
        self
      end

      def set_extra(key, value)
        @extras[key.to_s] = value
        self
      end

      def set_context(key, value)
        @contexts[key.to_s] = value
        self
      end

      def set_contexts(hash)
        @contexts.merge!(stringify(hash))
        self
      end

      def set_level(level)
        @level = level
        self
      end

      def set_fingerprint(fingerprint)
        @fingerprint = fingerprint
        self
      end

      # Sentry's transaction name is "Controller#action". Koderift stores those
      # as two separate columns and groups errors on them, so split rather than
      # keep the joined string.
      def set_transaction_name(name)
        component, _, action = name.to_s.partition('#')
        @component = component.empty? ? nil : component
        @action    = action.empty?    ? nil : action
        self
      end

      def add_breadcrumb(crumb)
        Breadcrumbs.add(crumb)
        self
      end

      def clear_breadcrumbs
        Breadcrumbs.clear
        self
      end

      def clear
        initialize
        self
      end

      def dup
        copy = self.class.new
        copy.set_user(@user)
        copy.set_tags(@tags)
        copy.set_extras(@extras)
        copy.set_contexts(@contexts)
        copy.level       = @level
        copy.fingerprint = @fingerprint
        copy.component   = @component
        copy.action      = @action
        copy
      end

      private

      def stringify(hash)
        return {} unless hash.respond_to?(:each_pair)

        hash.each_with_object({}) { |(k, v), out| out[k.to_s] = v }
      end
    end
  end
end
