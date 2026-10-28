# rpush 9.2 sends FCM over HTTP/1.1, one request per connection; this multiplexes a batch on HTTP/2.
module RpushFcmHttp2
  HOST = "https://fcm.googleapis.com".freeze
  SCOPE = "https://www.googleapis.com/auth/firebase.messaging".freeze
  MAX_STREAMS = 100 # http-2 1.x refuses more outgoing streams than its local default
  JOIN_TIMEOUT = 60
  FAILURES = {
    400 => "FCM failed to handle the JSON request.",
    401 => "Unauthorized, Bearer token could not be validated.",
    403 => "The sender ID was mismatched. It seems the device token is wrong.",
    404 => "Client was not registered for your app.", # PushDelivery.dead_token_error? matches this wording
    429 => "Slow down. Too many requests were sent!"
  }.freeze

  # On unless RPUSH_FCM_HTTP2=false, which falls back to rpush's HTTP/1.1 sender.
  def self.enabled? = ActiveModel::Type::Boolean.new.cast(ENV.fetch("RPUSH_FCM_HTTP2", "true"))

  def self.install!
    require "rpush/daemon"
    Rpush::Daemon::ServiceConfigMethods::DISPATCHERS[:fcm_http2] = Dispatcher
    Rpush::Daemon::Fcm.batch_deliveries(true)
    Rpush::Daemon::Fcm.dispatcher(:fcm_http2)
  end

  def self.endpoint(_app) = HOST

  # A bare SSLContext skips cert checks; without ALPN (net-http2 offers only NPN) Google hangs up.
  def self.ssl_context
    OpenSSL::SSL::SSLContext.new.tap do |ctx|
      ctx.set_params(verify_mode: OpenSSL::SSL::VERIFY_PEER)
      ctx.alpn_protocols = ["h2"]
    end
  end
  def self.access_token(app) = Rpush::Daemon::GoogleCredentialCache.instance.access_token(SCOPE, app.json_key)["access_token"]

  class Dispatcher
    include Rpush::Daemon::Loggable
    include Rpush::Reflectable
    prepend RpushIdleReconnect

    def initialize(app, _delivery_class, _options = {})
      @app = app
      @client = NetHttp2::Client.new(RpushFcmHttp2.endpoint(app), ssl_context: RpushFcmHttp2.ssl_context, connect_timeout: JOIN_TIMEOUT)
      @client.on(:error) do |error|
        log_error(error)
        reflect(:error, error)
      end
    end

    def dispatch(payload) = Delivery.new(@app, @client, payload.batch).perform

    def cleanup = @client.close
  end

  class Delivery < Rpush::Daemon::Delivery
    include RpushRetryUnanswered

    def initialize(app, client, batch)
      @app = app
      @client = client
      @batch = batch
    end

    def perform
      token = access_token_or_retry
      return if token.nil?

      path = "/v1/projects/#{@app.firebase_project_id}/messages:send"
      @batch.each_notification { |notification| post(notification, path, token) }
      @client.join(timeout: JOIN_TIMEOUT)
      retry_unanswered
    rescue StandardError => e
      @client.close
      retry_unanswered(e)
      raise
    ensure
      @batch.all_processed
    end

    # Runs on the client's socket thread, so it must never raise.
    def handle(notification, response)
      case response[:status]
      when 200 then @batch.mark_delivered(notification)
      when 429 then throttled(notification, response)
      when nil then retry_soon(notification) # stream reset, no answer
      when 500..599 then retry_later(notification, response)
      else fail_with(notification, response)
      end
    rescue StandardError => e
      log_error(e)
      @batch.mark_failed(notification, nil, e.message)
    end

    private

    # A short OAuth outage retries like a throttle; a key that never works fails after MAX_RETRIES.
    def access_token_or_retry
      RpushFcmHttp2.access_token(@app)
    rescue StandardError => e
      log_error(e)
      @batch.each_notification do |notification|
        next mark_retryable_exponential(notification) if notification.retries.to_i < RpushFcmThrottleRetry::MAX_RETRIES

        @batch.mark_failed(notification, nil, "FCM access token unavailable: #{e.message}")
      end
      nil
    end

    def post(notification, path, token)
      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + JOIN_TIMEOUT
      until streams_available?
        raise NetHttp2::AsyncRequestTimeout if Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline

        sleep 0.001
      end
      request = @client.prepare_request(:post, path, body: notification.as_json.to_json,
                                                     headers: { "content-type" => "application/json", "authorization" => "Bearer #{token}" })
      response = { body: +"" }
      request.on(:headers) do |headers|
        response[:status] = headers[":status"].to_i
        response[:retry_after] = headers["retry-after"]
      end
      request.on(:body_chunk) { |chunk| response[:body] << chunk.to_s }
      request.on(:close) { handle(notification, response) }
      @client.call_async(request)
    end

    def streams_available?
      [@client.remote_settings[:settings_max_concurrent_streams], MAX_STREAMS].min > @client.stream_count
    end

    def throttled(notification, response)
      return retry_later(notification, response) if notification.retries.to_i < RpushFcmThrottleRetry::MAX_RETRIES

      fail_with(notification, response)
    end

    def retry_later(notification, response)
      at = Rpush::Daemon::RetryHeaderParser.parse(response[:retry_after])
      at ? mark_retryable(notification, at) : mark_retryable_exponential(notification)
    end

    def fail_with(notification, response)
      detail = error_detail(response[:body])
      text = [FAILURES.fetch(response[:status], "FCM responded with HTTP #{response[:status]}."), detail && "(#{detail})"].compact.join(" ")
      error = Rpush::DeliveryError.new(response[:status], notification.id, text)
      @batch.mark_failed(notification, error.code, error.to_s)
    end

    def error_detail(body)
      error = JSON.parse(body.to_s)["error"]
      error && "#{error['status']}: #{error['message']}"
    rescue JSON::ParserError
      nil
    end
  end
end

RpushFcmHttp2.install! if RpushFcmHttp2.enabled?
