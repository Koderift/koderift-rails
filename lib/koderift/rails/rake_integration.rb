# frozen_string_literal: true

module Koderift
  module Rails
    # Captures uncaught rake task failures.
    #
    # This closes the largest blind spot in the product for scheduled work. A
    # rake task that raises writes its backtrace to STDERR, which under cron
    # goes to a mail spool or /dev/null — never to production.log — so the log
    # agent has never seen it and Koderift has never reported it. The tasks
    # most likely to fail unnoticed are exactly the ones nobody has touched in
    # a year.
    #
    # Rake::Application#display_error_message is the hook Sentry uses for the
    # same purpose. We capture and then call super, so Rake's own error output
    # is completely unchanged — anything already scraping that output, or a
    # human reading the cron mail, sees exactly what it saw before.
    module RakeIntegration
      def display_error_message(exception)
        Koderift::Rails::RakeIntegration.report(exception)
        super
      end

      # A clean `exit` inside a task reaches this hook as a SystemExit. It is
      # the task finishing, not failing, and reporting it would file an error
      # for every well-behaved task that exits explicitly.
      def self.report(exception)
        return if exception.is_a?(SystemExit)

        Koderift.capture_exception(exception, component: task_name, action: 'rake')
      rescue StandardError
        nil
      end

      def self.task_name
        name = ::Rake.application.top_level_tasks.first.to_s
        name.empty? ? 'rake' : name
      rescue StandardError
        'rake'
      end
    end
  end
end
