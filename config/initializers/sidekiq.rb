require 'sidekiq/scheduler'

if ENV['SIDEKIQ_INLINE'] == 'true'
  require 'sidekiq/testing'
  Sidekiq::Testing.inline!
end

Sidekiq.configure_server do |config|
  config.redis = { url: ENV["REDIS_URL"], ssl_params: Grovs::RedisSsl.params }

  config.death_handlers << lambda { |job, ex|
    Rails.logger.error "SIDEKIQ DLQ: #{job['class']} died after all retries. Args: #{job['args']}. Error: #{ex&.message}"
  }
end

Sidekiq.configure_client do |config|
  config.redis = { url: ENV["REDIS_URL"], ssl_params: Grovs::RedisSsl.params }
end