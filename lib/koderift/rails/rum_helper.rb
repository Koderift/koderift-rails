# frozen_string_literal: true

module Koderift
  module Rails
    module RumHelper
      MISSING_RUM_TOKEN_WARNING =
        '[Koderift] Browser RUM is off: koderift_rum_meta_tag renders nothing until ' \
        'config.rum_token is set. Since koderift-rails 2.1 the tag no longer publishes ' \
        'config.project_token, which is a secret. Copy the public RUM token (it starts ' \
        "with rum_) from your project's Log Analytics setup page in Koderift, or set " \
        'config.rum_enabled = false.'

      SECRET_RUM_TOKEN_WARNING =
        '[Koderift] Browser RUM is off: config.rum_token is set to your project token, ' \
        'which is a secret and must not appear in page HTML. Use the public RUM token ' \
        "(it starts with rum_) from your project's Log Analytics setup page in Koderift."

      # Renders the meta tag that rum.js reads for initialisation.
      # Place once inside <head> in your application layout.
      #
      # Example:
      #   <%= koderift_rum_meta_tag %>
      #
      # Renders:
      #   <meta name="koderift-rum-token"
      #         content="rum_abc123"
      #         data-rum-sampling-rate="0.1"
      #         data-environment="production">
      #
      # Publishes config.rum_token only, never config.project_token. Returns an
      # empty string when RUM is disabled or there is no publishable token.
      def koderift_rum_meta_tag
        config = Koderift::Rails.configuration
        return ''.html_safe unless config.rum_enabled

        token = RumHelper.publishable_rum_token(config)
        return ''.html_safe unless token

        tag.meta(
          name:    'koderift-rum-token',
          content: token,
          data: {
            rum_sampling_rate: config.rum_sampling_rate.to_f,
            environment:       (defined?(::Rails) && ::Rails.respond_to?(:env) ? ::Rails.env.to_s : 'production')
          }
        )
      end

      class << self
        # The token the meta tag may publish, or nil. Up to 2.0 the tag published
        # project_token, the log agent's ingest secret. It never does now, and a
        # rum_token equal to it is refused for the same reason. There is
        # deliberately no fallback: an app that set up RUM before 2.1 and has
        # not set rum_token gets one warning per process instead.
        def publishable_rum_token(config)
          token  = config.rum_token.to_s
          secret = config.project_token.to_s

          if token.empty?
            warn_once(MISSING_RUM_TOKEN_WARNING) unless secret.empty?
            return nil
          end

          if token == secret
            warn_once(SECRET_RUM_TOKEN_WARNING)
            return nil
          end

          token
        end

        def reset_warnings!
          @warned = false
        end

        private

        def warn_once(message)
          return if @warned

          @warned = true
          logger = defined?(::Rails) && ::Rails.respond_to?(:logger) ? ::Rails.logger : nil
          logger&.warn(message)
        rescue StandardError
          nil
        end
      end
    end
  end
end
