# frozen_string_literal: true

require 'time'

module Koderift
  module Rails
    # A manually recorded breadcrumb. Serialises to the same shape
    # Instrumentation already emits for SQL and partial renders, so manual and
    # automatic crumbs interleave in one ordered trail rather than living in
    # two lists the UI would have to merge.
    class Breadcrumb
      # Keys that never appear in a crumb's data, at any depth. The agent's
      # line regexes match `"controller":`, `"method":`, `"job_class":` and
      # `"koderift_capture":` anywhere in a line (see Capture::RESERVED_KEYS),
      # so one of them in a crumb would make it read the whole request or job
      # line as something else, or drop it.
      RESERVED_DATA_KEYS = %w[controller method job_class koderift_capture].freeze

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
          data:      Breadcrumb.scrub(@data),
          timestamp: @timestamp
        }.compact
      end

      # Deeper than this the data is left as given, so data that refers back
      # to itself is not walked forever (it fails, as before, only where the
      # line is written).
      MAX_SCRUB_DEPTH = 32

      # Hashes and Arrays only: other objects in `data` pass through as given.
      def self.scrub(value, depth = 0)
        return value if depth > MAX_SCRUB_DEPTH

        case value
        when Hash
          value.each_with_object({}) do |(k, v), out|
            next if RESERVED_DATA_KEYS.include?(k.to_s)

            out[k] = scrub(v, depth + 1)
          end
        when Array
          value.map { |v| scrub(v, depth + 1) }
        else
          value
        end
      rescue StandardError
        nil
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
          max = limit
          buffer.shift(buffer.size - max) if max && buffer.size > max

          crumb
        rescue StandardError
          nil
        end

        def current
          (Thread.current[KEY] || []).dup
        end

        # Empties the trail in place. Inside a request or job the published
        # array is that unit's own, which its line is built from, so crumbs an
        # app clears leave the line too, and later SQL and manual crumbs still
        # land in one list. Dropping the key instead left the cleared crumbs on
        # the line and split the trail in two.
        def clear
          buffer = Thread.current[KEY]
          buffer.clear if buffer.is_a?(Array)
          RescueContext.clear_crumbs if defined?(RescueContext)
          nil
        rescue StandardError
          nil
        end

        # Used when config.max_breadcrumbs is set to something that is not a
        # number. It is Configuration's default.
        DEFAULT_LIMIT = 20

        # config.max_breadcrumbs as a count, or nil for no cap. nil means no
        # cap, a String such as "20" (from ENV) is read as a number, and zero
        # or less keeps none, as zero always did. Anything else falls back to
        # the default rather than failing every request and job, which a nil
        # or a String did before 2.4.0.
        def limit
          value = Koderift::Rails.configuration.max_breadcrumbs
          return nil if value.nil?

          count = case value
                  when Integer then value
                  when Float
                    return nil if value.infinite? && value.positive?

                    value.infinite? ? 0 : value.to_i
                  when Numeric then value.to_i
                  else Integer(value.to_s.strip, 10)
                  end
          count.negative? ? 0 : count
        rescue StandardError
          DEFAULT_LIMIT
        end

        # The last `limit` of a trail, as a new array.
        def capped(list)
          list  = Array(list)
          count = limit
          count ? list.last(count) : list.dup
        rescue StandardError
          []
        end
      end
    end
  end
end
