class Api::V1::DiagnosticsController < ApplicationController
  skip_before_action :verify_authenticity_token, raise: false
  before_action :authenticate_diagnostics_api

  DIAGNOSTICS_API_KEY = ENV.fetch('DIAGNOSTICS_API_KEY', '').freeze

  # Test endpoint for exceptions - triggers an error for Signoz exception tracking
  # Usage: GET/POST /api/v1/diagnostics/test_exception
  # Params:
  #   type: exception type (standard, runtime, argument, custom)
  #   message: custom error message
  def test_exception
    error_type = params[:type] || 'standard'
    message = params[:message] || 'Test exception from diagnostics'

    # Add some context to the current span (if OTEL is available)
    if defined?(OpenTelemetry::Trace)
      span = OpenTelemetry::Trace.current_span
      span.set_attribute('test.error_type', error_type)
      test_hostname = begin; Socket.gethostname; rescue SystemCallError; 'unknown'; end
      span.set_attribute('test.hostname', test_hostname)
      span.set_attribute('test.triggered_at', Time.current.iso8601)
    end

    case error_type
    when 'runtime'
      raise message.to_s
    when 'argument'
      raise ArgumentError, message
    when 'record_not_found'
      raise ActiveRecord::RecordNotFound, message
    when 'custom'
      raise StandardError, message
    else
      raise StandardError, message
    end
  end

  # Test endpoint for logging - generates various log levels for testing Signoz filtering
  # Usage: GET/POST /api/v1/diagnostics/test_logs
  # Params:
  #   level: log level (debug, info, warn, error, fatal)
  #   message: custom message
  #   count: number of logs to generate (1-100)
  def test_logs
    log_level = params[:level] || 'info'
    message = params[:message] || 'Test log message'
    count = (params[:count] || 1).to_i.clamp(1, 100)

    hostname = begin; Socket.gethostname; rescue SystemCallError; 'unknown'; end
    process_type = ENV['PROCESS_TYPE'] || detect_process_type
    rails_env = Rails.env

    results = []

    count.times do |i|
      log_data = {
        test_id: SecureRandom.uuid,
        message: "#{message} (#{i + 1}/#{count})",
        hostname: hostname,
        process_type: process_type,
        environment: rails_env,
        timestamp: Time.current.iso8601,
        request_ip: request.remote_ip,
        iteration: i + 1
      }

      case log_level.downcase
      when 'debug'
        Rails.logger.debug(log_data.to_json)
      when 'info'
        Rails.logger.info(log_data.to_json)
      when 'warn', 'warning'
        Rails.logger.warn(log_data.to_json)
      when 'error'
        Rails.logger.error(log_data.to_json)
      when 'fatal'
        Rails.logger.fatal(log_data.to_json)
      else
        Rails.logger.info(log_data.to_json)
      end

      results << log_data
    end

    render json: {
      status: 'ok',
      logs_generated: count,
      level: log_level,
      hostname: hostname,
      process_type: process_type,
      environment: rails_env,
      logs: results
    }
  end

  # Diagnostics endpoint - exercises PostgreSQL and Redis for metrics testing
  # Uses REAL database tables to generate actual PostgreSQL metrics
  # Usage: GET/POST /api/v1/diagnostics/test_diagnostics
  # Params:
  #   iterations: number of operations to perform (default: 10, max: 100)
  #   include_slow: include slow queries for testing (default: false)
  #   cleanup: delete test records after (default: true)
  def test_diagnostics
    iterations = (params[:iterations] || 10).to_i.clamp(1, 100)
    include_slow = params[:include_slow] == 'true'
    cleanup = params[:cleanup] != 'false'

    results = {
      timestamp: Time.current.iso8601,
      hostname: (begin; Socket.gethostname; rescue SystemCallError; 'unknown'; end),
      environment: Rails.env,
      iterations: iterations,
      postgresql: { operations: [], total_ms: 0, errors: [], records_created: 0, records_deleted: 0 },
      redis: { operations: [], total_ms: 0, errors: [] }
    }

    test_run_key = "diag_#{SecureRandom.hex(8)}"

    run_postgresql_diagnostics(results, iterations, test_run_key, include_slow, cleanup)
    run_redis_diagnostics(results, iterations, test_run_key)
    build_diagnostics_summary(results, iterations)

    render json: results
  rescue StandardError => e
    render json: {
      error: e.message,
      backtrace: e.backtrace.first(5),
      timestamp: Time.current.iso8601
    }, status: :internal_server_error
  end

  private

  def run_postgresql_diagnostics(results, iterations, test_run_key, include_slow, cleanup)
    pg_start = Process.clock_gettime(Process::CLOCK_MONOTONIC)

    iterations.times do |i|
      test_key = "#{test_run_key}_#{i}"
      op_results = run_pg_iteration(results, test_key, i, include_slow)
      results[:postgresql][:operations] << op_results
    end

    cleanup_pg_test_records(results, test_run_key) if cleanup
    results[:postgresql][:total_ms] = ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - pg_start) * 1000).round(2)
  end

  def run_pg_iteration(results, test_key, iteration, include_slow)
    op_results = {}

    op_results[:select_1] = timed_op(results, :postgresql, 'select_1') do
      ActiveRecord::Base.lease_connection.execute("SELECT 1 AS test")
    end

    op_results[:count_users] = timed_op(results, :postgresql, 'count_users') { User.count }

    op_results[:join_query] = timed_op(results, :postgresql, 'join_query') do
      Project.joins(:domain).limit(5).to_a
    end

    op_results[:insert] = timed_op(results, :postgresql, 'insert') do
      DiagnosticsLog.create!(
        test_key: test_key, operation: 'insert',
        payload: { iteration: iteration, timestamp: Time.current }.to_json,
        hostname: results[:hostname], duration_ms: 0
      )
      results[:postgresql][:records_created] += 1
    end

    op_results[:select_by_key] = timed_op(results, :postgresql, 'select_by_key') do
      DiagnosticsLog.find_by(test_key: test_key)
    end

    op_results[:update] = timed_op(results, :postgresql, 'update') do
      record = DiagnosticsLog.find_by(test_key: test_key)
      record&.update!(operation: 'updated', duration_ms: op_results[:insert] || 0)
    end

    if include_slow && iteration == 0
      op_results[:slow_query] = timed_op(results, :postgresql, 'slow_query') do
        ActiveRecord::Base.lease_connection.execute("SELECT pg_sleep(0.1)")
      end
    end

    op_results
  end

  def cleanup_pg_test_records(results, test_run_key)
    start = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    deleted_count = DiagnosticsLog.where("test_key LIKE ?", "#{test_run_key}%").delete_all
    results[:postgresql][:cleanup_ms] = ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - start) * 1000).round(2)
    results[:postgresql][:records_deleted] = deleted_count
  rescue StandardError => e
    results[:postgresql][:errors] << { operation: 'cleanup', error: e.message }
  end

  def run_redis_diagnostics(results, iterations, test_run_key)
    redis_start = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    redis = Redis.new(url: ENV['REDIS_URL'] || 'redis://localhost:6379/0')

    iterations.times do |i|
      test_key = "diagnostics:test:#{test_run_key}:#{i}"
      op_results = run_redis_iteration(redis, results, test_key, test_run_key, i)
      results[:redis][:operations] << op_results
    end

    results[:redis][:total_ms] = ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - redis_start) * 1000).round(2)
    redis.close
  end

  def run_redis_iteration(redis, results, test_key, test_run_key, iteration)
    op_results = {}

    op_results[:ping] = timed_op(results, :redis, 'ping') { redis.ping }

    op_results[:set] = timed_op(results, :redis, 'set') do
      redis.set(test_key, { iteration: iteration, timestamp: Time.current.to_s }.to_json, ex: 60)
    end

    op_results[:get] = timed_op(results, :redis, 'get') { redis.get(test_key) }

    op_results[:incr_3x] = timed_op(results, :redis, 'incr') do
      counter_key = "diagnostics:counter:#{test_run_key}:#{iteration}"
      3.times { redis.incr(counter_key) }
      redis.del(counter_key)
    end

    op_results[:hash_ops] = timed_op(results, :redis, 'hash_ops') do
      hash_key = "diagnostics:hash:#{test_run_key}:#{iteration}"
      redis.hset(hash_key, 'field1', 'value1')
      redis.hset(hash_key, 'field2', 'value2')
      redis.hgetall(hash_key)
      redis.del(hash_key)
    end

    op_results[:list_ops] = timed_op(results, :redis, 'list_ops') do
      list_key = "diagnostics:list:#{test_run_key}:#{iteration}"
      redis.lpush(list_key, ['item1', 'item2', 'item3'])
      redis.lrange(list_key, 0, -1)
      redis.del(list_key)
    end

    op_results[:del] = timed_op(results, :redis, 'del') { redis.del(test_key) }

    if iteration == 0
      op_results[:info] = timed_op(results, :redis, 'info') do
        info = redis.info
        results[:redis][:server_info] = {
          redis_version: info['redis_version'],
          connected_clients: info['connected_clients'],
          used_memory_human: info['used_memory_human'],
          total_commands_processed: info['total_commands_processed']
        }
      end
    end

    op_results
  end

  def timed_op(results, category, operation)
    start = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    yield
    ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - start) * 1000).round(2)
  rescue StandardError => e
    results[category][:errors] << { operation: operation, error: e.message }
    nil
  end

  def build_diagnostics_summary(results, iterations)
    results[:summary] = {
      postgresql: {
        total_ms: results[:postgresql][:total_ms],
        avg_ms_per_iteration: (results[:postgresql][:total_ms] / iterations).round(2),
        records_created: results[:postgresql][:records_created],
        records_deleted: results[:postgresql][:records_deleted],
        errors: results[:postgresql][:errors].size
      },
      redis: {
        total_ms: results[:redis][:total_ms],
        avg_ms_per_iteration: (results[:redis][:total_ms] / iterations).round(2),
        errors: results[:redis][:errors].size
      },
      status: results[:postgresql][:errors].empty? && results[:redis][:errors].empty? ? 'healthy' : 'degraded'
    }

    Rails.logger.info({
      event: 'diagnostics_test',
      summary: results[:summary],
      hostname: results[:hostname]
    }.to_json)
  end

  def authenticate_diagnostics_api
    api_key = request.headers['X-Diagnostics-Key'] ||
              request.headers['Authorization']&.gsub(/^Bearer\s+/, '') ||
              params[:api_key]

    unless api_key.present? && ActiveSupport::SecurityUtils.secure_compare(api_key, DIAGNOSTICS_API_KEY)
      render json: { error: 'Unauthorized', message: 'Invalid or missing API key' }, status: :unauthorized
    end
  end

  def detect_process_type
    if defined?(Sidekiq) && Sidekiq.server?
      'worker'
    elsif $PROGRAM_NAME.include?('sidekiq')
      'worker'
    elsif $PROGRAM_NAME.include?('puma') || $PROGRAM_NAME.include?('rails')
      'web'
    else
      'unknown'
    end
  end
end
