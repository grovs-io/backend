require "test_helper"

class RpushFcmHttp2Test < ActiveSupport::TestCase
  class RecordingBatch
    attr_reader :delivered, :failed, :retryable, :all_retryable

    def initialize(notifications)
      @notifications = notifications
      @delivered = []
      @failed = []
      @retryable = []
      @all_retryable = nil
    end

    def each_notification(&) = @notifications.each(&)
    def mark_delivered(note) = @delivered << note.id
    def mark_failed(note, code, description) = @failed << [note.id, code, description]
    def mark_retryable(note, at) = @retryable << [note.id, at]
    def mark_all_retryable(at, _error) = @all_retryable = at
    def mark_all_failed(*); end
    def all_processed; end
  end

  class FakeRequest
    attr_reader :path, :body, :headers

    def initialize(path, body, headers)
      @path = path
      @body = body
      @headers = headers
      @callbacks = {}
    end

    def on(event, &block) = @callbacks[event] = block

    def respond(status, body = "", headers = {})
      @callbacks[:headers]&.call({ ":status" => status.to_s }.merge(headers)) if status # a reset stream sends no headers
      @callbacks[:body_chunk]&.call(body) unless body.empty?
      @callbacks[:close]&.call
    end
  end

  # Answers the oldest request whenever the sender waits for a free stream, like a server would.
  class FakeClient
    attr_reader :requests, :peak

    def initialize(&responder)
      @responder = responder
      @open = []
      @requests = []
      @peak = 0
    end

    def remote_settings = { settings_max_concurrent_streams: 1000 }
    def prepare_request(_method, path, body:, headers:) = FakeRequest.new(path, body, headers)

    def stream_count
      answer(@open.shift) if @open.size >= RpushFcmHttp2::MAX_STREAMS
      @open.size
    end

    def call_async(request)
      @requests << request
      @open << request
      @peak = [@peak, @open.size].max
    end

    def join(timeout:)
      answer(@open.shift) until @open.empty?
    end

    def close; end

    private

    def answer(request) = @responder.call(request)
  end

  def app = Rpush::Fcm::App.new(name: "push-load-android-t", firebase_project_id: "proj", json_key: "{}")
  def notifications(count) = Array.new(count) { |i| Rpush::Fcm::Notification.new(id: i + 1, device_token: "tok#{i}", retries: 0) }

  def run_batch(count, &responder)
    batch = RecordingBatch.new(notifications(count))
    client = FakeClient.new(&responder)
    RpushFcmHttp2.stub(:access_token, "tkn") { RpushFcmHttp2::Delivery.new(app, client, batch).perform }
    [batch, client]
  end

  test "a batch is multiplexed, never past the stream cap, one authorized POST per notification" do
    batch, client = run_batch(250) { |r| r.respond(200) }

    assert_equal (1..250).to_a, batch.delivered.sort
    assert_operator client.peak, :<=, RpushFcmHttp2::MAX_STREAMS
    assert_equal ["/v1/projects/proj/messages:send"], client.requests.map(&:path).uniq
    assert_equal "Bearer tkn", client.requests.first.headers["authorization"]
    assert_equal "tok0", JSON.parse(client.requests.first.body).dig("message", "token")
  end

  test "an unregistered token fails with the wording the dead-token cleanup recognises" do
    body = { error: { status: "NOT_FOUND", message: "Requested entity was not found." } }.to_json
    batch, = run_batch(1) { |r| r.respond(404, body) }

    _, code, description = batch.failed.first
    assert_equal 404, code
    assert_match(/Client was not registered for your app\. \(NOT_FOUND: Requested entity was not found\.\)/, description)
    assert PushDelivery.dead_token_error?(code, description) if defined?(PushDelivery)
  end

  test "5xx and dropped streams are retried, after Retry-After when there is one" do
    responses = [[503, { "retry-after" => "30" }], [500, {}], [nil, {}]]
    batch, = run_batch(3) do |r|
      status, headers = responses.shift
      r.respond(status, "", headers)
    end

    assert_equal [1, 2, 3], batch.retryable.map(&:first)
    assert_in_delta 30, batch.retryable.first.last - Time.now, 2
    assert_empty batch.failed
  end

  test "429 is retried within the budget and fails after it" do
    fresh, = run_batch(1) { |r| r.respond(429) }
    assert_equal [1], fresh.retryable.map(&:first)

    batch = RecordingBatch.new([Rpush::Fcm::Notification.new(id: 9, device_token: "t", retries: RpushFcmThrottleRetry::MAX_RETRIES)])
    delivery = RpushFcmHttp2::Delivery.new(app, nil, batch)
    delivery.handle(batch.instance_variable_get(:@notifications).first, { status: 429, body: "" })
    assert_equal 429, batch.failed.first[1]
  end

  test "a request the provider refuses fails with its reason" do
    batch, = run_batch(1) { |r| r.respond(400, { error: { status: "INVALID_ARGUMENT", message: "bad token" } }.to_json) }
    assert_match(/FCM failed to handle the JSON request\. \(INVALID_ARGUMENT: bad token\)/, batch.failed.first.last)
  end

  test "a connection failure retries the whole batch" do
    batch = RecordingBatch.new(notifications(2))
    client = FakeClient.new { |r| r.respond(200) }
    client.define_singleton_method(:call_async) { |_| raise Errno::ECONNREFUSED }
    RpushFcmHttp2.stub(:access_token, "t") do
      assert_raises(Errno::ECONNREFUSED) { RpushFcmHttp2::Delivery.new(app, client, batch).perform }
    end
    assert_equal [1, 2], batch.retryable.map(&:first)
  end

  test "streams a socket error closed without an answer are retried, answered ones are not" do
    batch = RecordingBatch.new(notifications(3))
    client = FakeClient.new { |r| r.respond(200) }
    client.define_singleton_method(:join) do |**|
      answer(@open.shift)
      @open.clear
    end
    RpushFcmHttp2.stub(:access_token, "t") { RpushFcmHttp2::Delivery.new(app, client, batch).perform }

    assert_equal [1], batch.delivered
    assert_equal [2, 3], batch.retryable.map(&:first)
  end

  test "after a GOAWAY every push without an answer retries and the client reconnects" do
    batch = RecordingBatch.new(notifications(3))
    client = FakeClient.new { |r| r.respond(200) }
    sent = 0
    original = client.method(:call_async)
    client.define_singleton_method(:call_async) do |request|
      raise HTTP2::Error::ConnectionClosed if (sent += 1) > 2

      original.call(request)
    end
    closed = false
    client.define_singleton_method(:close) { closed = true }
    RpushFcmHttp2.stub(:access_token, "t") do
      assert_raises(HTTP2::Error::ConnectionClosed) { RpushFcmHttp2::Delivery.new(app, client, batch).perform }
    end
    assert_empty batch.delivered
    assert_equal [1, 2, 3], batch.retryable.map(&:first)
    assert_empty batch.failed
    assert closed
  end

  test "a failed token fetch retries the batch, and fails it once the retry budget is spent" do
    fresh = Rpush::Fcm::Notification.new(id: 1, device_token: "a", retries: 0)
    spent = Rpush::Fcm::Notification.new(id: 2, device_token: "b", retries: RpushFcmThrottleRetry::MAX_RETRIES)
    batch = RecordingBatch.new([fresh, spent])
    client = FakeClient.new { |r| r.respond(200) }
    RpushFcmHttp2.stub(:access_token, ->(_) { raise SocketError, "oauth down" }) do
      RpushFcmHttp2::Delivery.new(app, client, batch).perform
    end
    assert_equal [1], batch.retryable.map(&:first)
    assert_equal [2], batch.failed.map(&:first)
    assert_empty client.requests
  end

  test "an unexpected error fails only the pushes that got no answer" do
    batch = RecordingBatch.new(notifications(2))
    client = FakeClient.new { |r| r.respond(200) }
    original = client.method(:call_async)
    client.define_singleton_method(:call_async) do |request|
      original.call(request)
      answer(@open.shift)
      raise ArgumentError, "boom" if @requests.size == 2
    end
    RpushFcmHttp2.stub(:access_token, "t") do
      assert_raises(ArgumentError) { RpushFcmHttp2::Delivery.new(app, client, batch).perform }
    end
    assert_equal [1, 2], batch.delivered
    assert_empty batch.failed
  end

  test "the client verifies the certificate and offers h2 over ALPN" do
    ctx = RpushFcmHttp2.ssl_context
    assert_equal ["h2"], ctx.alpn_protocols
    assert_equal OpenSSL::SSL::VERIFY_PEER, ctx.verify_mode
    assert ctx.verify_hostname
  end

  test "HTTP/2 is on unless RPUSH_FCM_HTTP2=false" do
    saved = ENV["RPUSH_FCM_HTTP2"]
    ENV.delete("RPUSH_FCM_HTTP2")
    assert RpushFcmHttp2.enabled?
    ENV["RPUSH_FCM_HTTP2"] = "false"
    assert_not RpushFcmHttp2.enabled?
  ensure
    saved.nil? ? ENV.delete("RPUSH_FCM_HTTP2") : ENV["RPUSH_FCM_HTTP2"] = saved
  end

  test "the daemon sends FCM through batched HTTP/2 dispatch" do
    RpushFcmHttp2.install!
    assert Rpush::Daemon::Fcm.batch_deliveries?
    assert_equal RpushFcmHttp2::Dispatcher, Rpush::Daemon::Fcm.dispatcher_class
  end

  test "the load-test redirect points marker apps at the sink and skips Google auth" do
    PushSink.install!
    saved = ENV["PUSH_SINK_FCM_URL"]
    ENV["PUSH_SINK_FCM_URL"] = "http://localhost:4011"
    assert_equal "http://localhost:4011", RpushFcmHttp2.endpoint(app)
    assert_equal "push-sink", RpushFcmHttp2.access_token(app)
    assert_equal RpushFcmHttp2::HOST, RpushFcmHttp2.endpoint(Rpush::Fcm::App.new(name: "android_config_x"))
  ensure
    saved.nil? ? ENV.delete("PUSH_SINK_FCM_URL") : ENV["PUSH_SINK_FCM_URL"] = saved
  end
end
