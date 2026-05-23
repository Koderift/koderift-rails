# frozen_string_literal: true

require 'active_support/concern'
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
        result = Koderift::Rails::Instrumentation.capture do
          yield
        end

        request.env['koderift.slow_partials']  = result[:slow_partials]
        request.env['koderift.query_stats']    = result[:query_stats]
        request.env['koderift.external_calls'] = result[:external_calls]
        request.env['koderift.breadcrumbs']    = result[:breadcrumbs]
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
        payload[:koderift_referer]      = request.referer
        payload[:koderift_params]       = filtered_params.to_h
        payload[:koderift_slow_partials]  = request.env['koderift.slow_partials']
        payload[:koderift_query_stats]    = request.env['koderift.query_stats']
        payload[:koderift_external_calls] = request.env['koderift.external_calls']
        payload[:koderift_breadcrumbs]    = request.env['koderift.breadcrumbs']
      end
    end
  end
end
