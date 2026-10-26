class JourneyStepJob
  include Sidekiq::Job
  sidekiq_options queue: :journeys, retry: 0

  LOOP_SECONDS = 55
  SLOT_TTL = 90
  RELEASE_LUA = "if redis.call('get', KEYS[1]) == ARGV[1] then return redis.call('del', KEYS[1]) end return 0".freeze

  def self.slot_key(journey_id, slot) = "journeys:step:#{Integer(journey_id)}:#{Integer(slot)}"
  def self.worker_key(index) = "journeys:step:worker:#{Integer(index)}"

  # Loops running at once across every journey, so many journeys never hold every worker thread.
  def self.max_workers = Integer(ENV.fetch("JOURNEY_STEP_MAX_WORKERS", 4)).clamp(1, 64)

  # One loop per slot and journey; a full batch means more is due, so the loop goes on or hands over.
  def perform(journey_id, slot = 0)
    return unless Journeys.running?

    key = self.class.slot_key(journey_id, slot)
    marker = SecureRandom.hex(8)
    return unless REDIS.with { |c| c.set(key, marker, nx: true, ex: SLOT_TTL) }

    # Over the global cap the job just stops: the tick enqueues the journey again within a minute.
    worker = lease(marker)
    more = false
    begin
      more = run(journey_id, key, worker) if worker
    ensure
      REDIS.with do |c|
        c.eval(RELEASE_LUA, keys: [key], argv: [marker])
        c.eval(RELEASE_LUA, keys: [worker], argv: [marker]) if worker
      end
    end
    self.class.perform_async(journey_id, slot) if more
  end

  private

  def lease(marker)
    self.class.max_workers.times.map { |i| self.class.worker_key(i) }.find { |k| REDIS.with { |c| c.set(k, marker, nx: true, ex: SLOT_TTL) } }
  end

  def run(journey_id, key, worker)
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    loop do
      journey = Journey.find_by(id: journey_id)
      return false if journey.nil?

      full = Journeys::Stepper.new(journey).run == Journeys::Stepper::BATCH
      return false unless full
      return true if Process.clock_gettime(Process::CLOCK_MONOTONIC) - started >= LOOP_SECONDS

      REDIS.with do |c|
        c.expire(key, SLOT_TTL)
        c.expire(worker, SLOT_TTL)
      end
    end
  end
end
