# frozen_string_literal: true

require 'active_support/concern'
require 'koderift/rails/trace_context'
require 'koderift/rails/instrumentation'
require 'koderift/rails/scope'

module Koderift
  module Rails
    module Controller
      extend ActiveSupport::Concern

      included do
        around_action :koderift_instrument_request
      end

      private

      def koderift_instrument_request
        started_at_ms = Koderift::Rails::TraceContext.now_ms

        # Ambient context for manual captures. Koderift.capture_exception can be
        # called from anywhere below this frame -- a model, a service object, a
        # rescue three layers down -- and has no other way to learn which
        # request it happened inside. The controller instance is kept so
        # config.current_user can be resolved at capture time rather than eagerly
        # on every request that never captures anything.
        context = {
          component:           self.class.name,
          action:              action_name,
          request_id:          request.request_id,
          path:                request.path,
          http_method:         request.request_method,
          controller_instance: self
        }

        trace_frame = koderift_start_trace(context, started_at_ms)

        result = Koderift::Rails::Instrumentation.capture(started_at_ms: started_at_ms) do
          yield
        end

        request.env['koderift.spans']         = result[:spans]
        request.env['koderift.query_count']   = result[:query_count]
        request.env['koderift.partial_count'] = result[:partial_count]
        request.env['koderift.search_count']  = result[:search_count]
        request.env['koderift.breadcrumbs']   = result[:breadcrumbs]
      ensure
        if trace_frame
          # Clears the trace ID and capture context, and anything a nested
          # transaction left behind.
          Koderift::Rails::TraceContext::Current.pop(trace_frame)
        else
          Thread.current[:koderift_trace_id] = nil
          Thread.current[:koderift_context]  = nil
        end
        # Puma reuses threads across requests. Without this reset a tag set for
        # one user's request would silently attach to the next request served
        # by the same thread.
        Koderift::Rails::Scope.reset!
      end

      # Continues the caller's trace (see TraceContext.incoming for the header
      # precedence) or starts one. A failure here costs the request its trace,
      # never the request itself.
      def koderift_start_trace(context, started_at_ms)
        incoming = Koderift::Rails::TraceContext.incoming(request.headers)
        frame    = Koderift::Rails::TraceContext::Current.push(
          kind:           :request,
          trace_id:       incoming[:trace_id],
          parent_span_id: incoming[:parent_span_id],
          flags:          incoming[:flags],
          tracestate:     incoming[:tracestate],
          context:        context,
          started_at_ms:  started_at_ms
        )

        request.env['koderift.trace_id']       = frame.trace_id
        request.env['koderift.span_id']        = frame.root_span_id
        request.env['koderift.parent_span_id'] = frame.parent_span_id
        request.env['koderift.started_at']     = frame.started_at
        frame
      rescue StandardError
        Thread.current[:koderift_context] = context
        nil
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
        payload[:koderift_span_id]        = request.env['koderift.span_id']
        payload[:koderift_parent_span_id] = request.env['koderift.parent_span_id']
        payload[:koderift_started_at]     = request.env['koderift.started_at']
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
