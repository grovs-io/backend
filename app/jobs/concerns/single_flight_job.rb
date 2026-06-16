# Sidekiq-job mixin: SETNX with a unique owner token + Lua CAS-unlock. Prevents the
# classic plain-SETNX-DEL ownership bug where a TTL-expired job stomps a successor's lock.
#
# Usage:
#   include SingleFlightJob
#   def perform
#     single_flight!(key: "my_job", ttl: 5.minutes) do |deadline|
#       items.find_each do |item|
#         break if Time.current >= deadline
#         process(item)
#       end
#     end
#   end
module SingleFlightJob
  extend ActiveSupport::Concern

  # Lua program body for Redis EVAL (not Ruby Kernel#eval). Returns 1 on owned-delete, 0 otherwise.
  RELEASE_LUA = <<~LUA
    if redis.call("get", KEYS[1]) == ARGV[1] then
      return redis.call("del", KEYS[1])
    else
      return 0
    end
  LUA

  private

  def single_flight!(key:, ttl:)
    lock_key = "sidekiq:single_flight:#{key}"
    token = SecureRandom.hex(16)
    ttl_seconds = ttl.to_i

    acquired = REDIS.with { |c| c.set(lock_key, token, nx: true, ex: ttl_seconds) }
    unless acquired
      Rails.logger.info("[#{self.class.name}] skipped: another run holds #{lock_key}")
      return
    end

    deadline = Time.current + ttl_seconds
    begin
      yield deadline
    ensure
      # CAS unlock: no-op if our TTL expired and another worker took over. Rescue Redis
      # errors so a transient blip on release doesn't mark the whole Sidekiq job failed —
      # that would trigger a retry and duplicate the side effects we just performed. The
      # lock auto-expires via the SETNX TTL regardless.
      begin
        REDIS.with { |conn| conn.eval(RELEASE_LUA, keys: [lock_key], argv: [token]) }
      rescue Redis::BaseError, StandardError => e
        Rails.logger.warn(message: "single_flight_release_failed",
                          key: lock_key, error: e.message)
      end
    end
  end
end
