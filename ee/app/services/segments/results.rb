module Segments
  module Results
    Manifest = Struct.new(:result_id, :project_id, :definition_hash, :list_generation,
                          :persons, :devices, :rows, :incomplete, keyword_init: true)
    MANIFEST_TTL = 150.minutes.to_i
    REUSE_TTL = 5.minutes.to_i
    WAIT_STEPS = 40
    # Outlives the slowest build (materialise + totals caps), so it never expires under its owner.
    LOCK_TTL = Runner::MATERIALIZE_TIMEOUT + Runner::READ_TIMEOUT + 10
    ID = /\A\h{32}\z/

    def self.manifest_key(result_id) = "segments:result:#{result_id}"

    def self.for(project:, definition:, list_generation: nil, segment_id: nil, lane: :dashboard)
      raise Clickhouse::Unavailable, "segments" unless Segments.available?
      if definition.uses?("purchase") && !project.instance.revenue_collection_enabled
        raise InvalidDefinition, "purchase conditions need revenue collection to be enabled"
      end

      reuse_key = ["segments:result_key", project.id, definition.digest, list_generation.to_s, Date.current.iso8601].join(":")
      reused(project.id, reuse_key) || single_flight(reuse_key, project.id) { build(project, definition, list_generation, segment_id, reuse_key, lane) }
    end

    def self.reused(project_id, reuse_key)
      cached = REDIS.with { |c| c.get(reuse_key) }
      cached && fetch!(project_id, cached)
    rescue ResultExpired
      nil
    end
    private_class_method :reused

    # One build per result at a time; a concurrent caller waits instead of repeating a 40s query.
    def self.single_flight(reuse_key, project_id)
      lock = "#{reuse_key}:lock"
      WAIT_STEPS.times do
        if REDIS.with { |c| c.set(lock, 1, nx: true, ex: LOCK_TTL) }
          begin
            return yield
          ensure
            REDIS.with { |c| c.del(lock) }
          end
        end
        pause
        found = reused(project_id, reuse_key)
        return found if found
      end
      raise Busy
    end
    private_class_method :single_flight

    def self.pause = sleep(0.5)

    def self.fetch!(project_id, result_id)
      raise ResultExpired, "malformed result id" unless result_id.to_s.match?(ID)

      raw = REDIS.with { |c| c.get(manifest_key(result_id)) }
      raise ResultExpired, "result expired" if raw.nil?

      manifest = Manifest.new(**JSON.parse(raw).symbolize_keys)
      raise ResultExpired, "result expired" unless manifest.project_id == Integer(project_id)

      manifest
    end

    def self.scope_sql(manifest)
      "project_id = #{Integer(manifest.project_id)} AND result_id = '#{manifest.result_id[ID]}'"
    end

    def self.build(project, definition, list_generation, segment_id, reuse_key, lane = :dashboard)
      cutoff = Analytics::RetentionPolicy.for(project.instance).queryable_cutoff_date
      compiler = Compiler.new(definition, project_id: project.id, cutoff_date: cutoff, segment_id: segment_id, list_generation: list_generation)
      result_id = SecureRandom.hex(16)
      Runner.materialize(project.id, compiler.insert_members_sql(result_id), lane: lane)
      manifest = Manifest.new(result_id: result_id, project_id: project.id, definition_hash: definition.digest,
                              list_generation: list_generation, incomplete: compiler.incomplete?, **totals(project.id, result_id))
      REDIS.with do |c|
        c.set(manifest_key(result_id), manifest.to_h.to_json, ex: MANIFEST_TTL)
        c.set(reuse_key, result_id, ex: REUSE_TTL)
      end
      manifest
    end
    private_class_method :build

    def self.totals(project_id, result_id)
      row = Runner.read("SELECT uniqExact(person_key) AS persons, uniqExact(eff_visitor_id) AS devices, count() AS rows " \
                        "FROM segment_results WHERE project_id = #{Integer(project_id)} AND result_id = '#{result_id}'").first || {}
      { persons: row["persons"].to_i, devices: row["devices"].to_i, rows: row["rows"].to_i }
    end
    private_class_method :totals
  end
end
