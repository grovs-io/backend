Rpush.configure do |config|
  config.client = :active_record

  # batch_size / push_poll caps one daemon: 4,000/s at 0.25 s (see docs/push-load-testing.md).
  config.push_poll = Float(ENV.fetch("RPUSH_PUSH_POLL", 0.25))
  config.batch_size = 1000
  config.pid_file = ENV.fetch("RPUSH_PID_FILE", "tmp/rpush.pid") # bin/rpush-cluster gives each daemon its own
  config.log_file = "log/rpush.log"
  config.log_level = defined?(Rails) && Rails.logger ? Rails.logger.level : ::Logger::Severity::INFO
end

require "rpush/daemon"

# One bookkeeping call per rpush batch: per-notification reflections ran a transaction per push.
module RpushBatchOutcomes
  def self.install!
    Rpush::Daemon::Batch.prepend(self) unless Rpush::Daemon::Batch.ancestors.include?(self)
  end

  def settled_ids
    @mutex.synchronize { [@delivered, *@failed.values, *@retryable.values].flatten.to_set(&:id) }
  end

  private

  def complete_delivered
    Rpush::Daemon.store.mark_batch_delivered(@delivered)
    borrow { PushOutcomes.delivered_batch(@delivered) }
  end

  def complete_failed
    failed_groups.each do |(code, description), notifications|
      Rpush::Daemon.store.mark_batch_failed(notifications, code, description)
      borrow { PushOutcomes.failed_batch(notifications, code, description) }
    end
  end

  # FCM descriptions embed the notification id, which would make every failure its own group.
  def failed_groups
    @failed.each_with_object(Hash.new { |h, k| h[k] = [] }) do |((code, description), notifications), groups|
      groups[[code, description.to_s.sub(/\AUnable to deliver notification \d+, /, "")]].concat(notifications)
    end
  end

  # A lease on a dispatcher thread is permanent; a busy pool is retried, the rest left to reconcile.
  def borrow(&)
    attempts = 0
    begin
      ActiveRecord::Base.connection_pool.with_connection(prevent_permanent_checkout: true, &)
    rescue ActiveRecord::ConnectionTimeoutError
      raise if (attempts += 1) >= 3

      sleep 0.5
      retry
    end
  end
end

# rpush 9.2 calls ActiveRecord::Base.clear_all_connections! (gone in Rails 8) and dies.
module RpushDatabaseRetry
  POOL_BUSY_PAUSE = 0.5

  def self.install!
    require "rpush/daemon/store/active_record"
    store = Rpush::Daemon::Store::ActiveRecord
    store.prepend(self) unless store.ancestors.include?(self)
  end

  def with_database_reconnect_and_retry(&)
    ::ActiveRecord::Base.connection_pool.with_connection(&)
  rescue ::ActiveRecord::ConnectionTimeoutError => e
    Rpush.logger.warn("Database pool busy, retrying (#{e.message})")
    sleep POOL_BUSY_PAUSE
    retry
  rescue ::ActiveRecord::ConnectionNotEstablished, ::ActiveRecord::ConnectionFailed => e
    Rpush.logger.error(e)
    sleep_to_avoid_thrashing
    database_connection_lost
    retry
  rescue *Rpush::Daemon::Store::ActiveRecord::Reconnectable::ADAPTER_ERRORS => e
    Rpush.logger.error(e)
    sleep_to_avoid_thrashing
    retry
  end

  def reconnect_database
    ::ActiveRecord::Base.connection_handler.clear_all_connections!
    ::ActiveRecord::Base.establish_connection
  end
end

# rpush never releases a dead daemon's claims; at-least-once, a push accepted pre-crash goes again.
module RpushStaleProcessing
  AFTER = 1.hour
  BOOT_GRACE = 5.minutes

  def self.release!(now: Time.current, after: AFTER)
    release(unsent.where(updated_at: ...(now - after)), now)
  end

  def self.release(scope, now = Time.current)
    PushOutcomes.withdraw_cancelled(scope.pluck(:id))
    scope.update_all(processing: false, updated_at: now)
  end

  def self.unsent = Rpush::Client::ActiveRecord::Notification.where(processing: true, delivered: false, failed: false)
end

# A stopping daemon hands back what it fetched but never started; Docker kills it before it drains.
module RpushReleaseOnStop
  def self.install!
    Rpush::Daemon::AppRunner.prepend(self) unless Rpush::Daemon::AppRunner.ancestors.include?(self)
  end

  def stop
    release_queued
    super
  end

  private

  def release_queued
    payloads = []
    while (payload = queue.pop(timeout: 0))
      payloads << payload
    end
    stops, payloads = payloads.partition { |p| p.is_a?(Array) }
    stops.each { |p| queue.push(p) }
    return if payloads.empty?

    release(payloads.flat_map { |p| p.notification ? [p.notification.id] : p.batch.notifications.map(&:id) })
    payloads.each { |p| p.batch.notification_processed if p.notification }
  end

  def release(ids)
    ActiveRecord::Base.connection_pool.with_connection { RpushStaleProcessing.release(RpushStaleProcessing.unsent.where(id: ids)) }
    Rpush.logger.info("[#{app.name}] Released #{ids.size} unsent notifications on stop")
  rescue StandardError => e
    Rpush.logger.error("[#{app.name}] Release on stop failed, the boot release frees them: #{e.class}: #{e.message}")
  end
end

# The daemon syncs apps only at start or on HUP; push configs are re-created on upload, so poll.
module RpushAppSync
  class << self
    attr_reader :thread

    def start(interval: 60)
      @thread = Thread.new do
        release_on_boot
        loop do
          sleep interval
          tick
        end
      end
    end

    def tick
      sync_fcm_connections
      Rpush::Daemon::Synchronizer.sync
      purged = RpushService.purge_orphans
      Rails.logger.warn("rpush.orphans.purged count=#{purged}") if purged.positive?
      released = RpushStaleProcessing.release!
      Rails.logger.warn("rpush.stale_processing.released count=#{released}") if released.positive?
    rescue StandardError => e
      Rails.logger.error("rpush.app_sync.failed #{e.class}: #{e.message}")
    end

    # Kamal stops the old daemon only once this one is healthy, so its live claims must age out.
    def release_on_boot
      released = RpushStaleProcessing.release!(after: RpushStaleProcessing::BOOT_GRACE)
      Rails.logger.warn("rpush.stale_processing.released_on_boot count=#{released}") if released.positive?
    rescue StandardError => e
      Rails.logger.error("rpush.release_on_boot.failed #{e.class}: #{e.message}")
    end

    # Applies RPUSH_FCM_CONNECTIONS to older apps; the sync then resizes their dispatchers.
    def sync_fcm_connections
      wanted = ENV["RPUSH_FCM_CONNECTIONS"].presence&.to_i
      Rpush::Fcm::App.where.not(connections: wanted).update_all(connections: wanted) if wanted&.positive?
    end

    def stop
      @thread&.kill
      @thread = nil
    end
  end
end

# rpush looks up an unknown app outside its rescue, stranding the fetch; purge_orphans clears it.
module RpushOrphanGuard
  def self.install!
    runner = Rpush::Daemon::AppRunner.singleton_class
    runner.prepend(self) unless runner.ancestors.include?(self)
  end

  def start_app_with_id(app_id)
    super
  rescue ActiveRecord::RecordNotFound
    Rpush.logger.warn("Skipping notifications of deleted app #{app_id}")
  end
end

# http-2 1.x refuses the 101st outgoing stream; rpush opens up to APNs' 1000, so big batches loop.
module RpushStreamCap
  def self.install!
    Rpush::Daemon::Apnsp8::Delivery.prepend(self) unless Rpush::Daemon::Apnsp8::Delivery.ancestors.include?(self)
  end

  private

  def remote_max_concurrent_streams
    [super, Rpush::Daemon::Apnsp8::Delivery::DEFAULT_MAX_CONCURRENT_STREAMS].min
  end
end

# Retries what the batch never settled: lost connections forever, other errors MAX_RETRIES times.
module RpushRetryUnanswered
  FIRST_RETRY_AFTER = 1.second # Apple may have shown the first copy; a fast retry lands before it is dismissed
  RETRY_AFTER = 10.seconds
  MAX_RETRIES = 8
  CONNECTION_ERRORS = [NetHttp2::AsyncRequestTimeout, SystemCallError, IOError, SocketError, OpenSSL::SSL::SSLError,
                       HTTP2::Error::ConnectionClosed, HTTP2::Error::StreamLimitExceeded].freeze

  private

  # The batch is the only truth: a socket thread killed by close may have recorded nothing it read.
  def retry_unanswered(error = nil)
    settled = @batch.settled_ids
    unanswered = []
    @batch.each_notification { |notification| unanswered << notification unless settled.include?(notification.id) }
    spent, retried = unanswered.partition { |notification| gives_up?(error, notification) }
    spent.each { |notification| @batch.mark_failed(notification, nil, error.to_s) }
    now = Time.now # one timestamp per batch: rpush writes one UPDATE per distinct deliver_after
    retried.each { |notification| retry_soon(notification, now) }
    return if unanswered.empty?

    log_warn("Unanswered notifications: #{retried.size} retried, #{spent.size} failed (#{error&.class || 'connection lost'})")
  end

  def retry_soon(notification, now = Time.now)
    mark_retryable(notification, now + (notification.retries.to_i.zero? ? FIRST_RETRY_AFTER : RETRY_AFTER))
  end

  def gives_up?(error, notification)
    error && CONNECTION_ERRORS.none? { |klass| error.is_a?(klass) } && notification.retries.to_i >= MAX_RETRIES
  end
end

# On a reset net-http2 drops streams unanswered and rpush leaves them claimed; retry them instead.
module RpushApnsUnanswered
  include RpushRetryUnanswered

  def self.install!
    Rpush::Daemon::Apnsp8::Delivery.prepend(self) unless Rpush::Daemon::Apnsp8::Delivery.ancestors.include?(self)
  end

  def perform
    @batch.each_notification { |notification| prepare_async_post(notification) }
    @client.join(timeout: Rpush::Daemon::Apnsp8::Delivery::CLIENT_JOIN_TIMEOUT)
    retry_unanswered
  rescue StandardError => e
    @client.close
    retry_unanswered(e)
    raise
  ensure
    @batch.all_processed
  end

  protected

  # Runs on the socket thread; raising there would kill the connection and all its streams.
  def handle_response(notification, response)
    return retry_soon(notification) if response[:code].nil? # stream reset, no answer

    super
  rescue StandardError => e
    log_error(e)
    @batch.mark_failed(notification, nil, e.message)
  end

  # rpush waits for a free stream forever; a connection that went silent would hang the dispatcher.
  def delayed_push_async(http_request)
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + Rpush::Daemon::Apnsp8::Delivery::CLIENT_JOIN_TIMEOUT
    until streams_available?
      raise NetHttp2::AsyncRequestTimeout if Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline

      sleep 0.001
    end
    @client.call_async(http_request)
  end
end

# NATs drop idle connections without a FIN; reconnect rather than write into a dead one.
module RpushIdleReconnect
  IDLE = 5.minutes

  def self.install!
    dispatcher = Rpush::Daemon::Dispatcher::Apnsp8Http2
    dispatcher.prepend(self) unless dispatcher.ancestors.include?(self)
  end

  def dispatch(payload)
    @client.close if @last_dispatch_at && monotonic_now - @last_dispatch_at > IDLE
    super
  ensure
    @last_dispatch_at = monotonic_now
  end

  private

  def monotonic_now = Process.clock_gettime(Process::CLOCK_MONOTONIC)
end

# rpush 9.2 fails an FCM 429 for good; Google asks senders to back off and retry, so do, boundedly.
module RpushFcmThrottleRetry
  MAX_RETRIES = 8

  def self.install!
    Rpush::Daemon::Fcm::Delivery.prepend(self) unless Rpush::Daemon::Fcm::Delivery.ancestors.include?(self)
  end

  protected

  def handle_response(response)
    return super unless response.code.to_i == 429 && @notification.retries.to_i < MAX_RETRIES

    retry_delivery(@notification, response)
    log_warn("FCM throttled notification #{@notification.id}; retry #{@notification.retries.to_i + 1}")
  end
end

# bin/rpush-cluster runs several daemons on one table: claim past each other's locked rows.
module RpushSkipLocked
  def self.install!
    require "rpush/daemon/store/active_record"
    store = Rpush::Daemon::Store::ActiveRecord
    store.prepend(self) unless store.ancestors.include?(self)
  end

  def deliverable_notifications(limit)
    with_database_reconnect_and_retry do
      Rpush::Client::ActiveRecord::Notification.transaction do
        ids = ready_for_delivery.limit(limit).lock("FOR UPDATE SKIP LOCKED").ids
        next [] if ids.empty?

        claimed = Rpush::Client::ActiveRecord::Notification.where(id: ids)
        claimed.update_all(processing: true, updated_at: Time.now)
        claimed.to_a
      end
    end
  end
end

RpushBatchOutcomes.install!
RpushSkipLocked.install!
RpushStreamCap.install!
RpushApnsUnanswered.install!
RpushIdleReconnect.install!
RpushFcmThrottleRetry.install!
RpushDatabaseRetry.install!
RpushOrphanGuard.install!
RpushReleaseOnStop.install!
Rails.application.config.after_initialize do
  next unless ENV["GROVS_ROLE"] == "rpush"

  RpushAppSync.start
end
