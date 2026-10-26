require "test_helper"

class PushSinkTest < ActiveSupport::TestCase
  KEYS = %w[PUSH_SINK_APNS_URL PUSH_SINK_FCM_URL].freeze

  setup { PushSink.install! }

  def with_env(overrides)
    saved = KEYS.index_with { |k| ENV[k] }
    overrides.each { |k, v| v.nil? ? ENV.delete(k) : ENV[k] = v }
    yield
  ensure
    saved.each { |k, v| v.nil? ? ENV.delete(k) : ENV[k] = v }
  end

  def apns_app(name) = Rpush::Apnsp8::App.new(name: name, environment: "production", bundle_id: "com.customer.app")
  def fcm_app(name) = Rpush::Fcm::App.new(name: name, firebase_project_id: PushSink::FIREBASE_PROJECT_ID, json_key: "{}")

  def apns_client_url(app)
    dispatcher = Rpush::Daemon::Dispatcher::Apnsp8Http2.allocate
    client = dispatcher.send(:create_http2_client, app)
    client.uri.to_s
  ensure
    client&.close
  end

  def fcm_delivery(app) = Rpush::Daemon::Fcm::Delivery.new(app, nil, Rpush::Fcm::Notification.new, nil)

  test "does nothing without a sink url" do
    with_env("PUSH_SINK_APNS_URL" => nil, "PUSH_SINK_FCM_URL" => nil) do
      assert_not PushSink.enabled?
      assert_equal "https://api.push.apple.com", apns_client_url(apns_app("push-load-ios-1-production")).chomp("/")
      assert_equal "fcm.googleapis.com", fcm_delivery(fcm_app("push-load-android-1")).instance_variable_get(:@uri).host
    end
  end

  test "reroutes only the marker apps" do
    with_env("PUSH_SINK_APNS_URL" => "http://localhost:4011", "PUSH_SINK_FCM_URL" => "http://localhost:4012") do
      assert_equal "http://localhost:4011", apns_client_url(apns_app("push-load-ios-1-production")).chomp("/")
      assert_equal "https://api.push.apple.com", apns_client_url(apns_app("ios_config_abc-production")).chomp("/")

      sink = fcm_delivery(fcm_app("push-load-android-1"))
      assert_equal "http://localhost:4012/v1/projects/#{PushSink::FIREBASE_PROJECT_ID}/messages:send", sink.instance_variable_get(:@uri).to_s
      assert_equal "fcm.googleapis.com", fcm_delivery(fcm_app("android_config_abc")).instance_variable_get(:@uri).host
    end
  end

  test "never asks Google for a token for the sink app" do
    with_env("PUSH_SINK_FCM_URL" => "http://localhost:4012") do
      Rpush::Daemon::GoogleCredentialCache.instance.stub(:access_token, ->(*) { flunk "Google was asked for a token" }) do
        token = fcm_delivery(fcm_app("push-load-android-1")).send(:obtain_access_token)
        assert_equal "push-sink", token["access_token"]
      end
    end
  end
end
