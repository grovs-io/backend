class PushCampaignDeliverJob
  include Sidekiq::Job
  sidekiq_options queue: :push, retry: 5

  LOOP_SECONDS = 55
  SLOT_TTL = 90
  THROTTLE_PAUSE = 0.25
  # Loops running at once across campaigns; a shared egress worker keeps threads for event streams.
  SHARED_MAX_WORKERS = 4
  DEDICATED_MAX_WORKERS = 16
  TURN_SECONDS = 10
  WAIT_RETRY = 2
  WAITING_KEY = "push:deliver:waiting".freeze
  WAITING_WINDOW = 30
  # Threads a process never gives to loops, so a waiting job can still run and register.
  SPARE_THREADS = 2
  RELEASE_LUA = "if redis.call('get', KEYS[1]) == ARGV[1] then return redis.call('del', KEYS[1]) end return 0".freeze

  @local_loops = Concurrent::AtomicFixnum.new(0)
  class << self
    attr_reader :local_loops
  end

  def self.slot_key(campaign_id, slot) = "push:campaign:#{Integer(campaign_id)}:slot:#{Integer(slot)}"
  def self.worker_key(index) = "push:deliver:worker:#{Integer(index)}"

  def self.max_workers
    configured = ENV["PUSH_DELIVERY_MAX_WORKERS"].presence
    return Integer(configured).clamp(1, 64) if configured

    dedicated_worker? ? DEDICATED_MAX_WORKERS : SHARED_MAX_WORKERS
  end

  # Leases are global, so one process could otherwise be handed every lease and fill all its threads.
  def self.local_limit = [Sidekiq.default_configuration[:concurrency].to_i - SPARE_THREADS, 1].max

  # A config/sidekiq_push.yml process serves nothing else, so the loops can have its threads.
  def self.dedicated_worker?
    Sidekiq.server? && Sidekiq.default_configuration.queues.uniq == ["push"]
  rescue StandardError
    false
  end

  # held: a waiting job's slot marker; the tick's copies of that slot exit while it waits.
  def perform(campaign_id, slot = 0, held = nil)
    campaign = PushCampaign.sending.find_by(id: campaign_id)
    return forget_waiting(campaign_id, slot) if campaign.nil? || slot >= self.class.max_workers

    key = self.class.slot_key(campaign_id, slot)
    marker = held || SecureRandom.hex(8)
    return unless claim_slot(key, marker, held) # a waiter holds it; its entry must stay visible

    worker = take_thread && begin
      lease_worker(marker) || release_thread
    rescue StandardError
      release_thread
      raise
    end
    return wait_for_worker(campaign_id, slot, key, marker) unless worker

    more = yielded = false
    begin
      forget_waiting(campaign_id, slot)
      more, yielded = run(campaign, key, worker)
    ensure
      release_thread
      REDIS.with do |c|
        c.eval(RELEASE_LUA, keys: [worker], argv: [marker])
        c.eval(RELEASE_LUA, keys: [key], argv: [marker])
      end
    end
    # Enqueue only after the slot is released, or the successor exits on the held key.
    return unless more

    yielded ? self.class.perform_in(WAIT_RETRY + 1, campaign_id, slot) : self.class.perform_async(campaign_id, slot)
  end

  private

  def run(campaign, key, worker)
    deliverer = PushCampaigns::Deliverer.new(campaign)
    started = now
    more = true
    while more && now < started + LOOP_SECONDS
      more = deliverer.deliver_slice
      sleep THROTTLE_PAUSE if more == :throttled
      REDIS.with do |c|
        c.expire(key, SLOT_TTL)
        c.expire(worker, SLOT_TTL)
      end
      return [more, true] if more && now - started >= TURN_SECONDS && others_waiting?(campaign.id)
    end
    deliverer.finish_if_done unless more
    [more, false]
  end

  def take_thread
    return true if self.class.local_loops.increment <= self.class.local_limit

    release_thread
  end

  def release_thread
    self.class.local_loops.decrement
    false
  end

  def lease_worker(marker)
    self.class.max_workers.times.map { |i| self.class.worker_key(i) }.find { |k| REDIS.with { |c| c.set(k, marker, nx: true, ex: SLOT_TTL) } }
  end

  def claim_slot(key, marker, held)
    REDIS.with do |c|
      c.set(key, marker, nx: true, ex: SLOT_TTL) || (held.present? && c.get(key) == held && c.expire(key, SLOT_TTL))
    end
  end

  def wait_for_worker(campaign_id, slot, key, marker)
    REDIS.with do |c|
      c.expire(key, WAITING_WINDOW)
      c.zadd(WAITING_KEY, Time.now.to_f, member(campaign_id, slot))
    end
    self.class.perform_in(WAIT_RETRY, campaign_id, slot, marker)
  end

  def forget_waiting(campaign_id, slot) = REDIS.with { |c| c.zrem(WAITING_KEY, member(campaign_id, slot)) }

  # One loop yields per waiter: the first to claim it gives up its worker, the rest keep going.
  def others_waiting?(campaign_id)
    REDIS.with do |c|
      c.zremrangebyscore(WAITING_KEY, "-inf", Time.now.to_f - WAITING_WINDOW)
      waiters = c.zrange(WAITING_KEY, 0, -1).reject { |m| m.start_with?("#{campaign_id}:") }
      waiters.any? { |m| c.set("push:deliver:yield:#{m}", 1, nx: true, ex: WAIT_RETRY * 2) }
    end
  end

  def member(campaign_id, slot) = "#{Integer(campaign_id)}:#{Integer(slot)}"
  def now = Process.clock_gettime(Process::CLOCK_MONOTONIC)
end
