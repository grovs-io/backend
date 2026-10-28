require "test_helper"

# Real rpush delivery, real net-http2 client, real rows, against an HTTP/2 server that resets on cue.
class RpushApnsConnectionResetTest < ActiveSupport::TestCase
  self.use_transactional_tests = false # the client's socket thread and the dispatcher must see the same rows

  Payload = Struct.new(:batch)

  setup do
    Rpush::Daemon.init_store
    @server = FakeApnsServer.new
    @app = Rpush::Apnsp8::App.create!(name: "apns-reset-test-#{SecureRandom.hex(4)}", environment: "sandbox",
                                      apn_key: OpenSSL::PKey::EC.generate("prime256v1").to_pem, apn_key_id: "KEYID",
                                      team_id: "TEAMID", bundle_id: "com.grovs.test", connections: 1)
    @errors = []
    @client = client_for(@server)
    @token = Rpush::Daemon::Apnsp8::Token.new(@app)
  end

  teardown do
    @client.close
    @server.stop
    Rpush::Client::ActiveRecord::Notification.where(app_id: @app.id).delete_all
    @app.destroy
  end

  def client_for(server)
    NetHttp2::Client.new(server.url, connect_timeout: 5).tap { |c| c.on(:error) { |e| @errors << e } }
  end

  def claimed(count, app: @app, klass: Rpush::Apnsp8::Notification, **attrs)
    Array.new(count) do |i|
      n = klass.create!(app: app, device_token: format("%064x", i + 1), **attrs)
      n.update_columns(processing: true)
      n
    end
  end

  def deliver(notifications)
    Rpush::Daemon::Apnsp8::Delivery.new(@app, @client, @token, Rpush::Daemon::Batch.new(notifications)).perform
    nil
  rescue StandardError => e
    e
  end

  # What the daemon does next: claim the due retries and send them again.
  def redeliver(notifications)
    due = notifications.map(&:reload).reject { |n| n.delivered || n.failed }
    due.each { |n| n.update_columns(processing: true, deliver_after: nil) }
    deliver(due)
  end

  def state(notification)
    n = notification.reload
    return :delivered if n.delivered
    return :failed if n.failed
    return :stuck if n.processing

    :retrying
  end

  def states(notifications) = notifications.map { |n| state(n) }.tally

  def with_join_timeout(seconds)
    mod = Rpush::Daemon::Apnsp8::Delivery
    original = mod::CLIENT_JOIN_TIMEOUT
    silence_warnings { mod.const_set(:CLIENT_JOIN_TIMEOUT, seconds) }
    yield
  ensure
    silence_warnings { mod.const_set(:CLIENT_JOIN_TIMEOUT, original) }
  end

  test "a push sent on a connection that died while idle is retried, not left claimed" do
    @server.handler = ->(r) { r.connection == 1 && r.index == 1 ? :ok : :reset }
    first, second = claimed(2)

    deliver([first])
    deliver([second])

    assert_equal :delivered, state(first)
    assert_equal :retrying, state(second), "errors seen by the client: #{@errors.map(&:inspect)}"
    assert_in_delta 1, second.deliver_after - Time.now, 1
    assert_equal 1, second.retries
  end

  test "a push that keeps getting reset fails once it is past fail_after" do
    @server.handler = ->(_r) { :reset }
    push, = claimed(1, fail_after: 1.minute.ago)

    deliver([push])

    assert_equal :failed, state(push)
    assert_match(/failed to be delivered before/, push.error_description)
  end

  test "only the first retry is fast; later ones wait, so an outage is not hammered" do
    @server.handler = ->(_r) { :reset }
    push, = claimed(1)

    deliver([push])
    assert_in_delta 1, push.reload.deliver_after - Time.now, 1
    redeliver([push])
    assert_in_delta 10, push.reload.deliver_after - Time.now, 2
    assert_equal 2, push.retries
  end

  test "the retry goes out on a fresh connection with the same collapse id and is delivered once" do
    @server.handler = ->(r) { r.connection == 1 && r.index == 2 ? :reset : :ok }
    first, second = claimed(2, alert: "hi", data: { "headers" => { "apns-collapse-id" => "grovs-42" } })

    deliver([first])
    deliver([second])
    assert_equal :retrying, state(second)
    redeliver([second])

    assert_equal :delivered, state(second)
    sent = @server.requests.select { |r| r.device_token == second.device_token }
    assert_equal [1, 2], sent.map(&:connection)
    assert_equal ["grovs-42"], sent.map { |r| r.headers["apns-collapse-id"] }.uniq
    assert_not JSON.parse(sent.last.body).key?("headers"), "collapse id travels as a header, not in the payload"
  end

  test "a reset noticed while idle costs nothing: the next batch reconnects and delivers" do
    first, second = claimed(2)
    deliver([first])
    @server.reset_all
    sleep 0.2

    deliver([second])

    assert_equal %i[delivered delivered], [state(first), state(second)]
    assert_equal 2, @server.connections
  end

  test "a reset in the middle of a 1,000-push batch strands nothing and the retry completes it" do
    @server.handler = ->(r) { r.connection == 1 && r.index == 500 ? :reset : :ok }
    notifications = claimed(1000)

    deliver(notifications)
    after_first = states(notifications)
    retry_times = notifications.map(&:reload).reject(&:delivered).map(&:deliver_after).uniq
    redeliver(notifications)

    assert_equal 1000, after_first.values.sum
    assert_equal [], after_first.keys - %i[delivered retrying], "after the reset: #{after_first}"
    assert_operator after_first[:retrying], :>=, 1
    assert_equal 1, retry_times.size, "one retry time per batch, so rpush writes one UPDATE"
    assert_equal({ delivered: 1000 }, states(notifications))
    assert_equal notifications.map(&:device_token).sort, @server.requests.map(&:device_token).uniq.sort
  end

  test "a write error mid-batch retries the unanswered pushes instead of failing the batch" do
    notifications = claimed(3)
    calls = 0
    original = @client.method(:call_async)
    @client.define_singleton_method(:call_async) do |request|
      raise Errno::EPIPE if (calls += 1) == 2

      original.call(request)
    end

    error = deliver(notifications)

    assert_kind_of Errno::EPIPE, error
    tally = states(notifications)
    assert_equal [], tally.keys - %i[delivered retrying], "after the write error: #{tally}"
    assert_equal :retrying, state(notifications.last)
  end

  test "an unexpected error while sending retries the pushes instead of failing them" do
    notifications = claimed(2)
    @client.define_singleton_method(:call_async) { |_| raise NoMethodError, "undefined method 'write' for nil" }

    assert_kind_of NoMethodError, deliver(notifications)
    assert_equal({ retrying: 2 }, states(notifications))
  end

  test "an answer cut off by the reset is retried, then settled by Apple's real answer" do
    @server.handler = ->(r) { r.connection == 1 ? :headers_then_reset : [410, "Unregistered"] }
    push, = claimed(1)

    deliver([push])
    assert_equal :retrying, state(push)

    redeliver([push])
    assert_equal :failed, state(push)
    assert_equal 410, push.reload.error_code
  end

  test "a reset right after Apple's 200 keeps the push delivered and sends it once" do
    @server.handler = ->(_r) { :ok_then_reset }
    push, = claimed(1)

    deliver([push])
    sleep 0.2

    assert_equal :delivered, state(push)
    assert_equal 1, @server.requests.size
  end

  test "a connection that went silent times out into a retry and the next batch reconnects" do
    @server.handler = ->(r) { r.connection == 1 ? :hang : :ok }
    stalled = claimed(1)
    later = Rpush::Apnsp8::Notification.create!(app: @app, device_token: "f" * 64).tap { |n| n.update_columns(processing: true) }

    error = with_join_timeout(1) { deliver(stalled) }
    deliver([later])

    assert_kind_of NetHttp2::AsyncRequestTimeout, error
    assert_equal :retrying, state(stalled.first)
    assert_equal :delivered, state(later)
  end

  test "a silent connection cannot hang the sender waiting for a free stream" do
    @server.handler = ->(_r) { :hang }
    notifications = claimed(150)

    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    error = with_join_timeout(1) { deliver(notifications) }

    assert_kind_of NetHttp2::AsyncRequestTimeout, error
    assert_operator Process.clock_gettime(Process::CLOCK_MONOTONIC) - started, :<, 10
    assert_equal({ retrying: 150 }, states(notifications))
  end

  test "Apple's permanent errors still fail without a retry" do
    reasons = { 1 => [410, "Unregistered"], 2 => [400, "BadDeviceToken"] }
    @server.handler = ->(r) { reasons.fetch(r.index) }
    notifications = claimed(2)

    deliver(notifications)

    assert_equal({ failed: 2 }, states(notifications))
    assert_equal [0, 0], notifications.map { |n| n.reload.retries }
  end

  test "Apple's busy answers are retried once each, not counted twice" do
    codes = { 1 => [429, "TooManyRequests"], 2 => [500, "InternalServerError"], 3 => [503, "ServiceUnavailable"] }
    @server.handler = ->(r) { codes.fetch(r.index) }
    notifications = claimed(3)

    deliver(notifications)

    assert_equal({ retrying: 3 }, states(notifications))
    assert_equal [1, 1, 1], notifications.map { |n| n.reload.retries }
  end

  test "an idle dispatcher reconnects before sending instead of writing into a dead connection" do
    dispatcher = Rpush::Daemon::Dispatcher::Apnsp8Http2.new(@app, Rpush::Daemon::Apnsp8::Delivery)
    dispatcher.instance_variable_get(:@client).close
    dispatcher.instance_variable_set(:@client, @client)
    first, second, third = claimed(3)

    dispatcher.dispatch(Payload.new(Rpush::Daemon::Batch.new([first])))
    dispatcher.dispatch(Payload.new(Rpush::Daemon::Batch.new([second])))
    assert_equal 1, @server.connections, "a busy connection is reused"

    dispatcher.instance_variable_set(:@last_dispatch_at, Process.clock_gettime(Process::CLOCK_MONOTONIC) - RpushIdleReconnect::IDLE - 1)
    dispatcher.dispatch(Payload.new(Rpush::Daemon::Batch.new([third])))

    assert_equal 2, @server.connections
    assert_equal({ delivered: 3 }, states([first, second, third]))
  end

  test "Android: a reset in the middle of a batch is retried, then delivered" do
    fcm_server = FakeApnsServer.new(tls: false) { |r| r.connection == 1 && r.index == 3 ? :reset : :ok }
    fcm_app = Rpush::Fcm::App.create!(name: "fcm-reset-test-#{SecureRandom.hex(4)}", firebase_project_id: "proj", json_key: "{}", connections: 1)
    client = client_for(fcm_server)
    notifications = claimed(5, app: fcm_app, klass: Rpush::Fcm::Notification, notification: { "title" => "t", "tag" => "grovs-7" })
    send_fcm = lambda do |batch|
      RpushFcmHttp2.stub(:access_token, "tkn") { RpushFcmHttp2::Delivery.new(fcm_app, client, Rpush::Daemon::Batch.new(batch)).perform }
    rescue StandardError
      nil
    end

    send_fcm.call(notifications)
    after_first = states(notifications)
    due = notifications.map(&:reload).reject(&:delivered)
    due.each { |n| n.update_columns(processing: true, deliver_after: nil) }
    send_fcm.call(due)

    assert_equal [], after_first.keys - %i[delivered retrying], "after the reset: #{after_first}"
    assert_equal({ delivered: 5 }, states(notifications))
    tags = fcm_server.requests.map { |r| JSON.parse(r.body).dig("message", "android", "notification", "tag") }.uniq
    assert_equal ["grovs-7"], tags
  ensure
    client&.close
    fcm_server&.stop
    Rpush::Client::ActiveRecord::Notification.where(app_id: fcm_app.id).delete_all if fcm_app
    fcm_app&.destroy
  end
end
