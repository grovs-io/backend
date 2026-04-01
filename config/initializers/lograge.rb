# Rails.application.configure do
#   # Send all logs to STDOUT
#   logger           = ActiveSupport::Logger.new(STDOUT)
#   logger.formatter = ::Logger::Formatter.new
#   config.logger    = ActiveSupport::TaggedLogging.new(logger)

#   config.log_level = :debug

#   # Lograge setup
#   config.lograge.enabled = true
#   config.lograge.base_controller_class = ['ActionController::Base', 'ActionController::API']

#   # Optional: JSON format
#   # config.lograge.formatter = Lograge::Formatters::Json.new

#   # Optional: custom payload (be careful with controller.params)
#   config.lograge.custom_payload do |controller|
#     {
#       request_id: controller.request.request_id,
#       user_agent: controller.request.user_agent,
#       remote_ip: controller.request.remote_ip,
#       time: Time.current
#     }
#   end
# end