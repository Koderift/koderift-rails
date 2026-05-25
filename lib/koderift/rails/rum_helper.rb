# frozen_string_literal: true

module Koderift
  module Rails
    module RumHelper
      # Renders the meta tag that rum.js reads for initialisation.
      # Place once inside <head> in your application layout.
      #
      # Example:
      #   <%= koderift_rum_meta_tag %>
      #
      # Renders:
      #   <meta name="koderift-rum-token"
      #         content="abc123"
      #         data-rum-sampling-rate="0.1">
      #
      # Returns an empty string when RUM is disabled or no token is configured.
      def koderift_rum_meta_tag
        config = Koderift::Rails.configuration
        return ''.html_safe unless config.rum_enabled && config.project_token.present?

        tag.meta(
          name:    'koderift-rum-token',
          content: config.project_token,
          data: {
            rum_sampling_rate: config.rum_sampling_rate.to_f
          }
        )
      end
    end
  end
end
