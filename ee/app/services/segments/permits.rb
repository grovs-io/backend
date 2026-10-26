module Segments
  module Permits
    GLOBAL_KEY = "segments:permits:global".freeze
    GLOBAL_LIMIT = Integer(ENV.fetch("SEGMENT_GLOBAL_PERMITS", 4))
    PROJECT_LIMIT = Integer(ENV.fetch("SEGMENT_PROJECT_PERMITS", 2))
    CAMPAIGN_GLOBAL_LIMIT = Integer(ENV.fetch("SEGMENT_CAMPAIGN_GLOBAL_PERMITS", 2))
    CAMPAIGN_PROJECT_LIMIT = Integer(ENV.fetch("SEGMENT_CAMPAIGN_PROJECT_PERMITS", 1))
    IN_APP_GLOBAL_LIMIT = Integer(ENV.fetch("SEGMENT_IN_APP_GLOBAL_PERMITS", 4))
    IN_APP_PROJECT_LIMIT = Integer(ENV.fetch("SEGMENT_IN_APP_PROJECT_PERMITS", 1))
    JOURNEY_GLOBAL_LIMIT = Integer(ENV.fetch("SEGMENT_JOURNEY_GLOBAL_PERMITS", 2))
    JOURNEY_PROJECT_LIMIT = Integer(ENV.fetch("SEGMENT_JOURNEY_PROJECT_PERMITS", 1))
    MCP_GLOBAL_LIMIT = Integer(ENV.fetch("SEGMENT_MCP_GLOBAL_PERMITS", 2))
    MCP_PROJECT_LIMIT = Integer(ENV.fetch("SEGMENT_MCP_PROJECT_PERMITS", 1))
    SERVER_GLOBAL_LIMIT = Integer(ENV.fetch("SEGMENT_SERVER_GLOBAL_PERMITS", 2))
    SERVER_PROJECT_LIMIT = Integer(ENV.fetch("SEGMENT_SERVER_PROJECT_PERMITS", 1))
    LANES = {
      dashboard: { global_key: GLOBAL_KEY, project_prefix: "segments:permits:project", limits: %i[GLOBAL_LIMIT PROJECT_LIMIT] },
      campaigns: { global_key: "segments:permits:campaigns:global", project_prefix: "segments:permits:campaigns:project",
                   limits: %i[CAMPAIGN_GLOBAL_LIMIT CAMPAIGN_PROJECT_LIMIT] },
      in_app: { global_key: "segments:permits:in_app:global", project_prefix: "segments:permits:in_app:project",
                limits: %i[IN_APP_GLOBAL_LIMIT IN_APP_PROJECT_LIMIT] },
      journeys: { global_key: "segments:permits:journeys:global", project_prefix: "segments:permits:journeys:project",
                  limits: %i[JOURNEY_GLOBAL_LIMIT JOURNEY_PROJECT_LIMIT] },
      mcp: { global_key: "segments:permits:mcp:global", project_prefix: "segments:permits:mcp:project",
             limits: %i[MCP_GLOBAL_LIMIT MCP_PROJECT_LIMIT] },
      server: { global_key: "segments:permits:server:global", project_prefix: "segments:permits:server:project",
                limits: %i[SERVER_GLOBAL_LIMIT SERVER_PROJECT_LIMIT] }
    }.freeze

    # Expired leases are swept before counting, so a crashed worker frees its slot by itself.
    ACQUIRE_LUA = <<~LUA.freeze
      redis.call('ZREMRANGEBYSCORE', KEYS[1], '-inf', ARGV[1])
      redis.call('ZREMRANGEBYSCORE', KEYS[2], '-inf', ARGV[1])
      if redis.call('ZCARD', KEYS[1]) >= tonumber(ARGV[2]) then return 0 end
      if redis.call('ZCARD', KEYS[2]) >= tonumber(ARGV[3]) then return 0 end
      redis.call('ZADD', KEYS[1], ARGV[4], ARGV[5])
      redis.call('ZADD', KEYS[2], ARGV[4], ARGV[5])
      redis.call('EXPIRE', KEYS[1], 3600)
      redis.call('EXPIRE', KEYS[2], 3600)
      return 1
    LUA

    def self.project_key(project_id, lane: :dashboard) = "#{LANES.fetch(lane)[:project_prefix]}:#{Integer(project_id)}"

    # lane: :campaigns is a separate, smaller pool so sends never queue behind dashboard estimates or vice versa.
    def self.with(project_id, ttl:, lane: :dashboard)
      cfg = LANES.fetch(lane) { raise ArgumentError, "unknown permit lane #{lane}" }
      global_limit, project_limit = cfg[:limits].map { |name| const_get(name) }
      keys = [cfg[:global_key], project_key(project_id, lane: lane)]
      token = SecureRandom.hex(16)
      now = Time.now.to_f
      argv = [now.to_s, global_limit.to_s, project_limit.to_s, (now + ttl).to_s, token]
      got = REDIS.with { |c| c.eval(ACQUIRE_LUA, keys: keys, argv: argv) }.to_i
      raise Busy, "no segment permit free for project #{project_id} (#{lane})" unless got == 1

      begin
        yield
      ensure
        REDIS.with { |c| keys.each { |k| c.zrem(k, token) } }
      end
    end
  end
end
