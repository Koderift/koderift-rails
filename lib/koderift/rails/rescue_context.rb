# frozen_string_literal: true

require 'koderift/rails/trace_context'
require 'koderift/rails/scope'
require 'koderift/rails/breadcrumb'

module Koderift
  module Rails
    # What a capture made inside a controller's rescue_from handler sees.
    #
    # ActionController::Rescue runs the handler after the gem's around_action
    # has finished: Rescue#process_action wraps Callbacks#process_action, so by
    # the time `rescue_with_handler` is called the request's trace frame has
    # been popped, its context cleared and its scope reset. A capture in the
    # handler used to go out with no request_id, so it could not pair with
    # Sentry's event from the same handler, and it could not be found from the
    # request.
    #
    # While a handler runs, this keeps a read-only view of the request in its
    # own thread keys. Only Capture (base_payload) and SentryBridge (rule 1)
    # read them, and only while the trace frame that was on top when the
    # handler started is still on top, so a transaction started inside the
    # handler carries its own context, as it does inside an action.
    #
    # Nothing is re-pushed, and no request data goes into a FrameStack-
    # published key: :koderift_trace_id and :koderift_context are never
    # written, and the capture keys only ever get nil or the value they had
    # before. Those keys are snapshot as `outside` by transactions, and an
    # abandoned one would then hand this request's state to a later one. So
    # outbound calls, jobs enqueued and transactions started in a handler
    # behave as before.
    #
    # Inside a Sidekiq job (a job that dispatches a request in-process) no
    # view is opened, and the handler keeps the job's context as before:
    # sentry-sidekiq tags every event in the job with its jid, which Koderift
    # pairs on first, so the gem's capture has to carry the jid to pair.
    #
    # The view carries:
    #
    # * the context the around_action builds (context_for), from the
    #   controller, so the user resolves through config.current_user;
    # * the trace and span the request line carries, read from the same
    #   request.env keys append_info_to_payload reads. A request whose hook
    #   never ran (Rails' default CSRF check, prepend_before_action, a skipped
    #   hook) has neither, on the line or in the capture;
    # * the request's scope, kept by `keep` when the action raised. When the
    #   handler ends the scope is reset, as at the end of a request, so a tag
    #   or crumb set in a handler never reaches the next request on the
    #   thread;
    # * the action's breadcrumbs as the request line carries them, up to the
    #   raise (2.4.0), kept the same way and held in a private thread key
    #   while the handler runs. Capture puts them before the handler's own.
    module RescueContext
      VIEW_KEY         = :koderift_rescue_view
      VIEW_BELOW_KEY   = :koderift_rescue_view_below
      VIEW_CONTEXT_KEY = :koderift_rescue_view_context
      VIEW_CRUMBS_KEY  = :koderift_rescue_view_crumbs

      # The ambient context a live unit publishes (Capture::CONTEXT_KEY).
      CONTEXT_KEY = :koderift_context

      # On the ActionDispatch::Request, never in request.env: env dumps
      # (exception_notification) print every value with to_s, and controller
      # ivars are copied into views. Rails builds a Request per dispatch, so a
      # second controller on the same env never sees it, and the handler that
      # reads it removes it, so neither does a controller the router falls
      # through to (X-Cascade) with the same Request.
      KEPT_SCOPE_IVAR  = :@koderift_rescue_scope
      KEPT_CRUMBS_IVAR = :@koderift_rescue_crumbs

      ENV_TRACE_ID = 'koderift.trace_id'
      ENV_SPAN_ID  = 'koderift.span_id'

      EMPTY_CONTEXT = {}.freeze

      class << self
        # The ambient context for a request, as the around_action publishes it
        # and as a handler's view rebuilds it.
        def context_for(controller)
          request = controller.request
          {
            component:           controller.class.name,
            action:              controller.action_name,
            request_id:          request.request_id,
            path:                request.path,
            http_method:         request.request_method,
            controller_instance: controller
          }
        end

        # From the around_action's ensure, only when the action raised, and
        # before the scope is reset. crumbs: the trail the request line
        # carries, which stops at the raise.
        def keep(request, crumbs = nil)
          request.instance_variable_set(KEPT_SCOPE_IVAR, Thread.current[Scope::STACK_KEY])
          request.instance_variable_set(KEPT_CRUMBS_IVAR, crumbs) if crumbs
          nil
        rescue StandardError
          nil
        end

        # Runs the block (the handler) with the view open. The view is not
        # opened when one is already open for this controller (a handler that
        # calls rescue_with_handler itself), or when this controller's own
        # context is live (an explicit call from inside the action). Every
        # value it replaces is put back afterwards. A failure part-way puts
        # them back at once, so the handler runs as it did before 2.3.1, and
        # the clean-up still runs when it ends. Nothing is allocated.
        def around(controller)
          opened = false
          begin
            if opens?(controller)
              thread         = Thread.current
              below          = TraceContext::Current.frame
              scope_before   = thread[Scope::STACK_KEY]
              crumbs_before  = thread[Breadcrumbs::KEY]
              view_before    = thread[VIEW_KEY]
              vbelow_before  = thread[VIEW_BELOW_KEY]
              context_before = thread[VIEW_CONTEXT_KEY]
              vcrumbs_before = thread[VIEW_CRUMBS_KEY]
              outer          = !below.nil? || !thread[CONTEXT_KEY].nil? || !view_before.nil?
              opened         = true
              publish(controller, below)
            end
          rescue StandardError
            if opened
              close(scope_before, crumbs_before, view_before, vbelow_before, context_before, vcrumbs_before, outer)
            end
          end
          yield
        ensure
          close(scope_before, crumbs_before, view_before, vbelow_before, context_before, vcrumbs_before, outer) if opened
        end

        # Whether this call comes from inside the controller's own action (its
        # context is live), as an app's explicit rescue_with_handler does.
        def inside_action?(controller)
          live = Thread.current[CONTEXT_KEY]
          live.is_a?(Hash) && live[:controller_instance].equal?(controller) ? true : false
        rescue StandardError
          false
        end

        # For the `rescued` marker only: the call comes from inside this
        # controller's action, also under a transaction or an inline job the
        # action started (their own context is on top). opens? keeps the
        # narrower inside_action?, so a handler called there still pairs.
        def inside_own_request?(controller)
          return true if inside_action?(controller)

          TraceContext::Current::STACK.any? do |frame|
            frame.kind == :request && frame.context.is_a?(Hash) &&
              frame.context[:controller_instance].equal?(controller)
          end
        rescue StandardError
          false
        end

        # The controller whose handler is running, while nothing started in
        # the handler (a transaction) is on top of it. nil otherwise.
        def current
          thread     = Thread.current
          controller = thread[VIEW_KEY]
          return nil if controller.nil?

          TraceContext::Current.frame.equal?(thread[VIEW_BELOW_KEY]) ? controller : nil
        rescue StandardError
          nil
        end

        # The view's context, built on the first capture that needs it.
        def context
          thread = Thread.current
          thread[VIEW_CONTEXT_KEY] ||= context_for(thread[VIEW_KEY])
        rescue StandardError
          EMPTY_CONTEXT
        end

        def trace_id(controller)
          controller.request.env[ENV_TRACE_ID]
        rescue StandardError
          nil
        end

        def span_id(controller)
          controller.request.env[ENV_SPAN_ID]
        rescue StandardError
          nil
        end

        # The action's crumbs while the view is in force, else nil.
        def crumbs
          current ? Thread.current[VIEW_CRUMBS_KEY] : nil
        rescue StandardError
          nil
        end

        # Breadcrumbs.clear in a handler clears the action's crumbs too.
        def clear_crumbs
          list = Thread.current[VIEW_CRUMBS_KEY]
          list.clear if list.is_a?(Array)
          nil
        rescue StandardError
          nil
        end

        # Specs only.
        def clear!
          thread = Thread.current
          thread[VIEW_KEY]         = nil
          thread[VIEW_BELOW_KEY]   = nil
          thread[VIEW_CONTEXT_KEY] = nil
          thread[VIEW_CRUMBS_KEY]  = nil
        end

        private

        # Not for a call re-entered from this controller's handler, nor one
        # made from inside its action (its context is live), nor inside a
        # Sidekiq job (see the module comment).
        def opens?(controller)
          thread = Thread.current
          return false if thread[VIEW_KEY].equal?(controller)

          return false if inside_action?(controller)

          frame = TraceContext::Current.frame
          !(frame && frame.kind == :job)
        end

        # The view key is written last: current reads nothing until it is set.
        def publish(controller, below)
          thread  = Thread.current
          request = controller.request
          if request.instance_variable_defined?(KEPT_SCOPE_IVAR)
            thread[Scope::STACK_KEY] = request.remove_instance_variable(KEPT_SCOPE_IVAR)
          end
          thread[VIEW_CRUMBS_KEY] = if request.instance_variable_defined?(KEPT_CRUMBS_IVAR)
                                      request.remove_instance_variable(KEPT_CRUMBS_IVAR)
                                    end
          # With no capture open, a crumb added in the handler would land in a
          # plain thread-local nothing else clears. Start it empty; close puts
          # back what was there.
          thread[Breadcrumbs::KEY]  = nil unless capturing?
          thread[VIEW_CONTEXT_KEY]  = nil
          thread[VIEW_BELOW_KEY]    = below
          thread[VIEW_KEY]          = controller
        end

        # Instrumentation is loaded with the gem (koderift/rails.rb). It is not
        # required here, so SentryBridge, which reads the view, still loads
        # without ActiveSupport.
        def capturing?
          defined?(Instrumentation) && !Instrumentation.current_frame.nil? ? true : false
        end

        # Inside another unit (a controller run in a transaction, or a
        # handler's handler) the scope stack the thread had when the handler
        # started comes back, and anything left open is that unit's to drop
        # when it ends. (The request's own end has already reset the scope by
        # then, so a scope an outer unit set before running the controller is
        # gone, as it was before 2.3.1.)
        #
        # Otherwise nothing was live when the handler started, so whatever is
        # on the trace or capture stacks now was started in the handler and
        # abandoned (a non-block start_transaction never finished). It is
        # dropped, as a request's end drops what its action left open, and the
        # scope is reset. A transaction holds what the thread published when
        # it started as `outside`; left here, a later finish would publish it
        # again into whatever request runs then.
        def close(scope_before, crumbs_before, view_before, vbelow_before, context_before, vcrumbs_before, outer)
          thread = Thread.current
          thread[VIEW_KEY]         = view_before
          thread[VIEW_BELOW_KEY]   = vbelow_before
          thread[VIEW_CONTEXT_KEY] = context_before
          thread[VIEW_CRUMBS_KEY]  = vcrumbs_before
          unless outer
            TraceContext::Current.clear! unless TraceContext::Current.frame.nil?
            Instrumentation.clear_captures! if capturing?
          end
          thread[Breadcrumbs::KEY] = crumbs_before
          if outer
            thread[Scope::STACK_KEY] = scope_before
          else
            Scope.reset!
          end
          nil
        rescue StandardError
          nil
        end
      end
    end
  end
end
