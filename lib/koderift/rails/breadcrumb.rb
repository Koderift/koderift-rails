# frozen_string_literal: true

require 'time'

module Koderift
  module Rails
    # A manually recorded breadcrumb. Serialises to the same shape
    # Instrumentation already emits for SQL and partial renders, so manual and
    # automatic crumbs interleave in one ordered trail rather than living in
    # two lists the UI would have to merge.
    class Breadcrumb
      attr_reader :category, :message, :level, :data, :timestamp

      def initialize(category: nil, message: nil, level: nil, data: nil, timestamp: nil)
        @category  = category.to_s.empty? ? 'manual' : category.to_s
        @message   = message.to_s
        @level     = level&.to_s
        @data      = data
        @timestamp = timestamp || Time.now.utc.iso8601
      end

      def to_h
        {
          type:      @category,
          message:   @message,
          level:     @level,
          data:      @data,
          timestamp: @timestamp
        }.compact
      end
    end

    # The live breadcrumb trail for the current thread.
    #
    # Instrumentation.capture publishes ITS OWN array here for the duration of a
    # request or job, so a manual crumb lands in the same list as the automatic
    # SQL/render ones and ships with that unit's log line. Outside a captured
    # unit the trail is a plain thread-local that captures still read, which is
    # what makes breadcrumbs work in a rake task.
    module Breadcrumbs
      KEY = :koderift_breadcrumbs

      class << self
        def add(crumb)
          crumb = Breadcrumb.new(message: crumb.to_s) unless crumb.is_a?(Breadcrumb)
          buffer = (Thread.current[KEY] ||= [])
          buffer << crumb.to_h

          # Trim here rather than only at the end of Instrumentation.capture:
          # outside a captured unit nothing else ever bounds this array, and a
          # rake task adding crumbs in a loop would grow it without limit.
          max = Koderift::Rails.configuration.max_breadcrumbs.to_i
          buffer.shift(buffer.size - max) if max.positive? && buffer.size > max

          crumb
        rescue StandardError
          nil
        end

        def current
          (Thread.current[KEY] || []).dup
        end

        def clear
          Thread.current[KEY] = nil
        end
      end
    end
  end
end
