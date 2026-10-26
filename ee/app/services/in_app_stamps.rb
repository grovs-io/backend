# Two values a device compares with its own to learn that it must sync again.
module InAppStamps
  USER_TTL = 30.days.to_i
  NEVER = "0".freeze

  module_function

  def campaigns(project_id) = read("in_app:campaigns:#{project_id}")
  def user(visitor_id) = read("in_app:user:#{visitor_id}")

  def for(project_id, visitor_id)
    values = REDIS.with { |conn| conn.mget("in_app:campaigns:#{project_id}", "in_app:user:#{visitor_id}") }
    { "campaigns_changed_at" => values[0] || NEVER, "user_changed_at" => values[1] || NEVER }
  rescue Redis::BaseError
    nil
  end

  def touch_campaigns(project_id) = write("in_app:campaigns:#{project_id}", nil)
  def touch_user(visitor_id) = write("in_app:user:#{visitor_id}", USER_TTL)

  # One round trip for many visitors. Call it once their rows are committed, never before.
  def touch_users(visitor_ids)
    return if visitor_ids.empty?

    value = (Time.current.to_f * 1000).to_i.to_s
    REDIS.with { |conn| conn.pipelined { |pipe| visitor_ids.each { |id| pipe.set("in_app:user:#{id}", value, ex: USER_TTL) } } }
  rescue Redis::BaseError => e
    Rails.logger.warn("in_app.stamp_failed users #{e.class}")
    nil
  end

  def read(key)
    REDIS.with { |conn| conn.get(key) } || NEVER
  rescue Redis::BaseError
    nil
  end

  # A lost write costs freshness only: devices still sync at every session start.
  def write(key, ttl)
    REDIS.with { |conn| conn.set(key, (Time.current.to_f * 1000).to_i.to_s, ex: ttl) }
  rescue Redis::BaseError => e
    Rails.logger.warn("in_app.stamp_failed #{key} #{e.class}")
    nil
  end
end
