# Load tests only: routes the marker apps' pushes to a fake APNs/FCM; real apps are never rerouted.
module PushSink
  APP_PREFIX = "push-load-".freeze
  FIREBASE_PROJECT_ID = "grovs-push-sink".freeze

  module_function

  def apns_url = ENV["PUSH_SINK_APNS_URL"].presence
  def fcm_url = ENV["PUSH_SINK_FCM_URL"].presence
  def enabled? = !!(apns_url || fcm_url)
  def marked?(app) = app.name.to_s.start_with?(APP_PREFIX)
  def apns?(app) = !!apns_url && marked?(app)
  def fcm?(app) = !!fcm_url && marked?(app)

  def install!
    require "rpush/daemon"
    Rpush::Daemon::Dispatcher::Apnsp8Http2.prepend(Apns) unless Rpush::Daemon::Dispatcher::Apnsp8Http2.ancestors.include?(Apns)
    Rpush::Daemon::Fcm::Delivery.prepend(Fcm) unless Rpush::Daemon::Fcm::Delivery.ancestors.include?(Fcm)
    RpushFcmHttp2.singleton_class.prepend(FcmHttp2) unless RpushFcmHttp2.singleton_class.ancestors.include?(FcmHttp2)
  end

  module FcmHttp2
    def endpoint(app) = PushSink.fcm?(app) ? PushSink.fcm_url : super
    def access_token(app) = PushSink.fcm?(app) ? "push-sink" : super
  end

  module Apns
    private

    def create_http2_client(app)
      return super unless PushSink.apns?(app)

      client = NetHttp2::Client.new(PushSink.apns_url, connect_timeout: Rpush::Daemon::Dispatcher::Apnsp8Http2::DEFAULT_TIMEOUT)
      client.on(:error) do |error|
        log_error(error)
        reflect(:error, error)
      end
      client
    end
  end

  module Fcm
    def initialize(app, http, notification, batch)
      super
      @uri = URI.parse("#{PushSink.fcm_url}/v1/projects/#{app.firebase_project_id}/messages:send") if PushSink.fcm?(app)
    end

    private

    # The sink ignores auth; never ask Google for a token with the fake service account.
    def obtain_access_token
      PushSink.fcm?(@app) ? { "access_token" => "push-sink" } : super
    end
  end
end

# With one URL, the other platform's load-test app would send fake credentials to Apple or Google.
raise "Set both PUSH_SINK_APNS_URL and PUSH_SINK_FCM_URL, or neither" if PushSink.enabled? && !(PushSink.apns_url && PushSink.fcm_url)

# After initialize: RpushFcmHttp2 is defined by a later initializer.
Rails.application.config.after_initialize { PushSink.install! if PushSink.enabled? }

if PushSink.enabled?
  Rails.logger.warn("push_sink.enabled apns=#{PushSink.apns_url.inspect} fcm=#{PushSink.fcm_url.inspect} (only #{PushSink::APP_PREFIX}* apps)")
end
