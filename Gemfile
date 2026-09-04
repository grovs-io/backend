source 'https://rubygems.org'
git_source(:github) { |repo| "https://github.com/#{repo}.git" }

ruby '~> 3.4'

# Bundle edge Rails instead: gem 'rails', github: 'rails/rails', branch: 'main'
gem 'rails', '~> 8.1.0'

# Use Puma as the app server
gem 'puma', '~> 7.0'
# Dropped from Ruby's default gems in 4.0; lib/clickhouse/migrator.rb requires it.
gem 'benchmark'
# Rack 3 breaks the app (968 errors): Rails reloads classes differently and
# middleware contracts changed. Pinned until that migration is done deliberately.
gem 'rack', '~> 2.2'

gem 'pg', '~> 1.5'
gem 'rack-cors', '~> 2.0'
gem 'devise', '~> 5.0'
gem 'doorkeeper', '~> 5.8'
gem 'devise_invitable', '~> 2.0.0'
gem 'dotenv-rails', '~> 3.1'
gem 'sendgrid-actionmailer', '~> 3.2'


gem 'sprockets-rails', '~> 3.5'

gem 'nokogiri', '~> 1.16'
gem 'httparty', '~> 0.22'

gem 'redis', '~> 4.0'
gem 'connection_pool', '~> 2.5'
gem "rqrcode", "~> 2.0"
gem "browser", "~> 5.3"
gem 'devise-two-factor', '~> 6.0'


gem 'aws-sdk-s3', '~> 1'

gem "hashid-rails", '~> 1.0'
gem 'remote_ip_proxy_scrubber', '~> 0.1'
gem 'public_suffix'

gem 'stripe', '~> 12.4'

# gem 'will_paginate', '~> 4.0'
gem 'chunky_png', '~> 1.4'
gem 'sidekiq', '~> 7.3'
gem 'rpush', '~> 9.2'
gem 'activerecord-import', '~> 1.8'
gem 'kaminari', '~> 1.2'
gem 'app_store_server_api', '~> 0.1'

gem 'omniauth', '~> 2.1'
gem 'omniauth-microsoft_graph'
gem 'omniauth-rails_csrf_protection', '~> 2.0'
gem 'omniauth-google-oauth2', '~> 1.2.1'
gem 'omniauth_openid_connect', '~> 0.8'
gem 'scimitar', '~> 2.15'
gem 'sidekiq-scheduler', '~> 5.0'

gem 'click_house-client', '~> 0.8'  # GitLab's ClickHouse HTTP client
gem 'maxminddb', '~> 0.1'      # GeoIP resolution from MaxMind GeoLite2 database

# Reduces boot times through caching; required in config/boot.rb
gem 'bootsnap', '>= 1.4.4', require: false

gem 'lograge', '~> 0.14'
gem 'kamal', '~> 2.2'
gem 'newrelic_rpm', '~> 9.18'
gem 'rack-attack', '~> 6.7'

gem 'google-apis-androidpublisher_v3', '~> 0.95'
gem 'googleauth', '~> 1.11'

gem 'opentelemetry-sdk', '~> 1.8'
gem 'opentelemetry-exporter-otlp', '~> 0.30'
gem 'opentelemetry-instrumentation-all', '~> 0.78'

# Use Rack CORS for handling Cross-Origin Resource Sharing (CORS), making cross-origin AJAX possible
# gem 'rack-cors'

group :development, :test do
  gem 'brakeman', require: false
  gem 'bundler-audit', require: false
  # Call 'byebug' anywhere in the code to stop execution and get a debugger console
  gem 'byebug', '~> 11.1', platforms: [:mri, :mingw, :x64_mingw]
  gem 'minitest-mock', '~> 5.0'
  gem 'rubocop', '~> 1.85', require: false
  gem 'rubocop-rails', '~> 2.34', require: false
  gem 'bullet', '~> 8.1'
  # Strict API request/response contract validation in tests (see test/support/api_contracts.rb)
  gem 'json-schema', '~> 6.2', require: false
  gem 'webmock', '~> 3.23', require: false
  # Coverage reports: COVERAGE=1 bundle exec rails test:full (see test/test_helper.rb)
  gem 'simplecov', '~> 0.22', require: false
end

group :development do
  gem 'listen', '~> 3.3'
  # Spring speeds up development by keeping your application running in the background. Read more: https://github.com/rails/spring
  gem 'spring', '~> 4.2'
  gem 'letter_opener', '~> 1.10'
end

# Windows does not include zoneinfo files, so bundle the tzinfo-data gem
gem 'tzinfo-data', platforms: [:mingw, :mswin, :x64_mingw, :jruby]
