# frozen_string_literal: true

require 'securerandom'

module Koderift
  module Rails
    # The return value of a successful capture. Shaped after Sentry's event so
    # the idiom that motivated this API keeps working after a namespace swap:
    #
    #   event_id = Koderift.capture_exception(error)&.event_id
    #
    # A capture returns nil rather than an Event whenever it was not emitted —
    # the gem is disabled, the class is excluded, sampling or the rate limiter
    # dropped it, before_send vetoed it, or the exception was already captured.
    # That is why callers reach for &. and it is why nil must stay a real,
    # documented outcome rather than an error.
    Event = Struct.new(:event_id, :level, :message, :exception, :timestamp,
                       keyword_init: true) do
      # Sentry event ids are 32 lowercase hex characters, not a dashed UUID.
      # Anything that already parses Sentry ids out of application logs keeps
      # working against ours.
      def self.generate_id
        SecureRandom.uuid.delete('-')
      end
    end
  end
end
