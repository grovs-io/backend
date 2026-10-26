module Segments
  module Runner
    ESTIMATE_TIMEOUT = Integer(ENV.fetch("SEGMENT_ESTIMATE_TIMEOUT_SEC", 30))
    MAX_MEMORY = Integer(ENV.fetch("SEGMENT_MAX_MEMORY_BYTES", 4_000_000_000))
    MAX_THREADS = Integer(ENV.fetch("SEGMENT_MAX_THREADS", 4))
    ESTIMATE_CACHE_TTL = 60.seconds
    MATERIALIZE_TIMEOUT = Integer(ENV.fetch("SEGMENT_MATERIALIZE_TIMEOUT_SEC", 40))
    READ_TIMEOUT = 10

    def self.estimate(project:, definition:, list_generation: nil, segment_id: nil, lane: :dashboard)
      compiler = compiler_for(project: project, definition: definition, list_generation: list_generation, segment_id: segment_id)
      key = ["segments:estimate", project.id, definition.digest, list_generation.to_s, Date.current.iso8601].join(":")
      Rails.cache.fetch(key, expires_in: ESTIMATE_CACHE_TTL) do
        row = run(project.id, compiler.estimate_sql, timeout: ESTIMATE_TIMEOUT, lane: lane).first || {}
        { persons: row["persons"].to_i, devices: row["devices"].to_i, approximate: false, incomplete: compiler.incomplete? }
      end
    end

    # Too-heavy falls back to the plain estimate and reports the split as unavailable, not an error.
    def self.estimate_with_platforms(project:, definition:, list_generation: nil, segment_id: nil)
      compiler = compiler_for(project: project, definition: definition, list_generation: list_generation, segment_id: segment_id)
      key = ["segments:estimate_platforms", project.id, definition.digest, list_generation.to_s, Date.current.iso8601].join(":")
      Rails.cache.fetch(key, expires_in: ESTIMATE_CACHE_TTL) do
        row = run(project.id, compiler.estimate_with_platforms_sql, timeout: ESTIMATE_TIMEOUT).first || {}
        devices = row["devices"].to_i
        ios, android = clamp_platform_split(devices, row["ios_devices"].to_i, row["android_devices"].to_i)
        { persons: row["persons"].to_i, devices: devices, ios_devices: ios, android_devices: android,
          approximate: false, incomplete: compiler.incomplete? }
      rescue Analytics::QueryTooHeavy
        estimate(project: project, definition: definition, list_generation: list_generation, segment_id: segment_id)
          .merge(ios_devices: nil, android_devices: nil)
      end
    end

    # uniqCombinedIf is approximate, so ios + android can overshoot devices.
    def self.clamp_platform_split(devices, ios, android)
      ios = ios.clamp(0, devices)
      [ios, android.clamp(0, devices - ios)]
    end
    private_class_method :clamp_platform_split

    def self.compiler_for(project:, definition:, list_generation:, segment_id:)
      raise Clickhouse::Unavailable, "segments" unless Segments.available?
      if definition.uses?("purchase") && !project.instance.revenue_collection_enabled
        raise InvalidDefinition, "purchase conditions need revenue collection to be enabled"
      end

      cutoff = Analytics::RetentionPolicy.for(project.instance).queryable_cutoff_date
      Compiler.new(definition, project_id: project.id, cutoff_date: cutoff, segment_id: segment_id, list_generation: list_generation)
    end
    private_class_method :compiler_for

    # ClickHouse stops 2s before the HTTP read gives up, so a permit never outlives its query.
    def self.run(project_id, sql, timeout:, lane: :dashboard)
      guarded do
        Permits.with(project_id, ttl: timeout + 5, lane: lane) do
          Clickhouse.with_request_timeout(timeout + 2) do
            Clickhouse.with { |conn| conn.select_all("#{sql}\n#{settings(timeout)}") }
          end
        end
      end
    end

    def self.materialize(project_id, sql, timeout: MATERIALIZE_TIMEOUT, lane: :dashboard)
      guarded do
        Permits.with(project_id, ttl: timeout + 5, lane: lane) do
          Clickhouse.with_request_timeout(timeout + 2) do
            Clickhouse.with { |conn| conn.execute("#{sql}\n#{settings(timeout)}") }
          end
        end
      end
    end

    def self.read(sql, timeout: READ_TIMEOUT)
      guarded do
        Clickhouse.with_request_timeout(timeout + 2) do
          Clickhouse.with { |conn| conn.select_all("#{sql}\nSETTINGS max_execution_time = #{Integer(timeout)}") }
        end
      end
    end

    def self.guarded
      yield
    rescue Net::ReadTimeout => e
      raise Analytics::QueryTooHeavy, e.message
    rescue ClickHouse::Client::DatabaseError, *Clickhouse::TRANSPORT_ERRORS => e
      raise Analytics::QueryTooHeavy, e.message if e.message.to_s.match?(Analytics::QueryHelpers::HEAVY)
      raise Clickhouse::Unavailable, "segments" if Clickhouse.availability_error?(e)

      raise
    end
    private_class_method :guarded

    def self.settings(timeout)
      "SETTINGS max_execution_time = #{Integer(timeout)}, max_memory_usage = #{MAX_MEMORY}, max_threads = #{MAX_THREADS}, " \
        "max_bytes_before_external_group_by = #{MAX_MEMORY / 4}, join_use_nulls = 0"
    end
  end
end
