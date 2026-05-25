# frozen_string_literal: true

require 'active_support/concern'
require 'securerandom'
require 'koderift/rails/instrumentation'

module Koderift
  module Rails
    module Controller
      extend ActiveSupport::Concern

      included do
        around_action :koderift_instrument_request
      end

      private

      def koderift_instrument_request
        trace_id = request.headers['X-Koderift-Trace-ID'].presence ||
                   SecureRandom.uuid

        Thread.current[:koderift_trace_id] = trace_id
        request.env['koderift.trace_id']   = trace_id

        result = Koderift::Rails::Instrumentation.capture do
          yield
        end

        request.env['koderift.spans']         = result[:spans]
        request.env['koderift.query_count']   = result[:query_count]
        request.env['koderift.partial_count'] = result[:partial_count]
        request.env['koderift.search_count']  = result[:search_count]
        request.env['koderift.breadcrumbs']   = result[:breadcrumbs]
      ensure
        Thread.current[:koderift_trace_id] = nil
      end

      def append_info_to_payload(payload)
        super
        config = Koderift::Rails.configuration

        user = begin
          config.current_user.call(self)
        rescue StandardError
          nil
        end

        filtered_params = request.filtered_parameters
                                 .except('controller', 'action', 'format',
                                         'utf8', '_method')
                                 .reject do |k, _|
                                   config.filter_params.any? do |f|
                                     k.to_s.match?(/#{Regexp.escape(f)}/i)
                                   end
                                 end

        payload[:koderift_user_id]      = user&.id
        payload[:koderift_host]         = request.host
        payload[:koderift_ip]           = request.remote_ip
        payload[:koderift_user_agent]   = request.user_agent
        payload[:koderift_request_id]   = request.request_id
        payload[:koderift_trace_id]     = request.env['koderift.trace_id']
        payload[:koderift_referer]      = request.referer
        payload[:koderift_params]       = filtered_params.to_h
        payload[:koderift_spans]         = request.env['koderift.spans']
        payload[:koderift_query_count]   = request.env['koderift.query_count']
        payload[:koderift_partial_count] = request.env['koderift.partial_count']
        payload[:koderift_search_count]  = request.env['koderift.search_count']
        payload[:koderift_breadcrumbs]   = request.env['koderift.breadcrumbs']
      end
    end
  end
end
