# frozen_string_literal: true

require 'active_support/concern'
require 'koderift/rails/trace_context'
require 'koderift/rails/instrumentation'
require 'koderift/rails/scope'
require 'koderift/rails/sentry_bridge'
require 'koderift/rails/rescue_context'

module Koderift
  module Rails
    module Controller
      extend ActiveSupport::Concern

      # Per-request values kept on the ActionDispatch::Request, never in
      # request.env: env dumps (exception_notification) print every value, and
      # these hold SQL. Rails builds a Request per dispatch; each reader
      # removes its own, so a controller the router falls through to with the
      # same Request (X-Cascade) sees none of them.
      KODERIFT_RESULT_IVAR  = :@koderift_result
      KODERIFT_RESCUED_IVAR = :@koderift_rescued

      included do
        around_action :koderift_instrument_request
      end

      # ActionController::Rescue calls this after the around_action below has
      # finished, so a capture in the handler would otherwise have no request
      # context. See RescueContext. Public, as ActiveSupport::Rescuable's is.
      #
      # When a handler took the exception, the request line says which class
      # (`rescued`), because nothing else on it shows that the action raised:
      # its counts stop at the raise, and a raise before the hook has none.
      # Not for an explicit call from inside the action, whose line is the
      # action's own. A handler that passes another error on is marked by the
      # outermost call, which returns last.
      def rescue_with_handler(exception)
        inside  = Koderift::Rails::RescueContext.inside_own_request?(self)
        handled = Koderift::Rails::RescueContext.around(self) { super }
        koderift_mark_rescued(handled, exception) if handled && !inside
        handled
      end

      private

      def koderift_mark_rescued(handled, exception)
        name = (handled.is_a?(Exception) ? handled : exception).class.name
        request.instance_variable_set(KODERIFT_RESCUED_IVAR, name) if name
      rescue StandardError
        nil
      end

      def koderift_instrument_request
        Koderift::Rails::SentryBridge.install_if_ready
        started_at_ms = Koderift::Rails::TraceContext.now_ms

        # Ambient context for manual captures. Koderift.capture_exception can be
        # called from anywhere below this frame -- a model, a service object, a
        # rescue three layers down -- and has no other way to learn which
        # request it happened inside. The controller instance is kept so
        # config.current_user can be resolved at capture time rather than eagerly
        # on every request that never captures anything.
        context = Koderift::Rails::RescueContext.context_for(self)

        trace_frame = koderift_start_trace(context, started_at_ms)
        state       = koderift_start_capture(started_at_ms)

        # The capture's result is built whether or not the action raises, so
        # the request line of an action that raised, handled or not, keeps its
        # spans, counts and breadcrumbs up to the raise.
        # Nothing is rescued here: the exception passes through untouched.
        begin
          yield
          finished = true
        ensure
          result = koderift_finish_capture(state)
        end
      ensure
        # A rescue_from handler for this exception runs after this ensure, so
        # the request's scope is kept for it before the reset below, with the
        # trail the line carries (the request's own, not a transaction left
        # open on top of it). A copy, so a handler that clears breadcrumbs
        # does not change the line.
        unless finished
          crumbs = result && result[:breadcrumbs]
          Koderift::Rails::RescueContext.keep(request, crumbs.is_a?(Array) ? crumbs.dup : nil)
        end
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

      # A failure here costs the request its spans, never the request.
      def koderift_start_capture(started_at_ms)
        Koderift::Rails::Instrumentation.start_capture(started_at_ms: started_at_ms)
      rescue StandardError
        nil
      end

      # Stops the capture and keeps its result on the Request for the request
      # line (append_info_to_payload); returns it. Runs in an ensure while an
      # exception may be on its way out, so nothing here may raise or replace
      # it.
      def koderift_finish_capture(state)
        return nil if state.nil?

        begin
          Koderift::Rails::Instrumentation.stop_capture(state)
        rescue StandardError
          nil
        end
        result = Koderift::Rails::Instrumentation.result_for(state)
        request.instance_variable_set(KODERIFT_RESULT_IVAR, result) if result
        result
      rescue StandardError
        nil
      end

      def koderift_take(ivar)
        request.instance_variable_defined?(ivar) ? request.remove_instance_variable(ivar) : nil
      rescue StandardError
        nil
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
        result = koderift_take(KODERIFT_RESULT_IVAR) || {}
        payload[:koderift_spans]         = result[:spans]
        payload[:koderift_query_count]   = result[:query_count]
        payload[:koderift_partial_count] = result[:partial_count]
        payload[:koderift_search_count]  = result[:search_count]
        payload[:koderift_breadcrumbs]   = result[:breadcrumbs]
        payload[:koderift_rescued]       = koderift_take(KODERIFT_RESCUED_IVAR)
      end
    end
  end
end
