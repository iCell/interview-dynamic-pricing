require "json"
require "logger"
require "active_support/tagged_logging"

# Minimal JSON formatter so each Rails log line is greppable / parseable in
# log aggregation. We intentionally avoid lograge to keep the dependency
# surface small.
#
# We include ActiveSupport::TaggedLogging::Formatter to inherit the
# tagged/push_tags/current_tags API that Rails calls on the formatter —
# without those methods Rails.logger.tagged(...) raises NoMethodError.
# Our own #call wins over the module's because of MRO (class first, then
# included modules), so we control the actual output format.
class JsonLogFormatter < ::Logger::Formatter
  include ActiveSupport::TaggedLogging::Formatter

  def call(severity, time, progname, msg)
    payload = {
      ts: time.utc.iso8601(3),
      severity: severity,
      progname: progname
    }

    tags = current_tags
    payload[:tags] = tags.dup unless tags.empty?

    case msg
    when Hash
      payload.merge!(msg)
    when Exception
      payload[:message] = msg.message
      payload[:exception_class] = msg.class.name
      payload[:backtrace] = Array(msg.backtrace).first(5)
    else
      payload[:message] = msg.to_s
    end

    "#{payload.to_json}\n"
  end
end

Rails.application.configure do
  formatter = JsonLogFormatter.new

  # config.log_formatter only applies to loggers that Rails constructs after
  # this point — by the time this initializer runs, Rails.logger has already
  # been built in the :initialize_logger bootstrap step. So we also assign
  # the formatter onto the existing Rails.logger (and its broadcast
  # children, since Rails 7.1 wraps the logger in BroadcastLogger).
  config.log_formatter = formatter
  Rails.logger.formatter = formatter if Rails.logger
end
