# frozen_string_literal: true

module Analytics
  # sdk_identifier/uuid live only on the PG visitors row, so CH cannot aggregate them from events.
  module VisitorIdentitySyncService
    ConcurrentSyncError = Class.new(StandardError)
    LockLostError = Class.new(StandardError)

    module_function

    BATCH_SIZE = Integer(ENV.fetch('CLICKHOUSE_IDENTITY_SYNC_BATCH_SIZE', 20_000))
    GENERATION_MARKER_VISITOR_ID = 0

    LOCK_TTL = Integer(ENV.fetch('CLICKHOUSE_IDENTITY_SYNC_LOCK_TTL', 3600))

    # Serialized per project: allocation is read-then-write, so two runs could blend snapshots.
    def sync_project(project_id)
      pid = Integer(project_id)
      lock_key = "clickhouse:identity_sync:#{pid}"
      token = SecureRandom.hex(16)
      unless REDIS.with { |c| c.set(lock_key, token, nx: true, ex: LOCK_TTL) }
        raise ConcurrentSyncError, "identity sync already running for project #{pid}"
      end

      begin
        sync_project!(pid, lock_key, token)
      ensure
        release_lock(lock_key, token)
      end
    end

    def sync_project!(pid, lock_key = nil, token = nil)
      generation = next_generation(pid)
      total = 0

      Visitor.where(project_id: pid)
             .select(:id, :project_id, :sdk_identifier, :uuid)
             .find_in_batches(batch_size: batch_size) do |batch|
        rows = batch.map do |v|
          {
            project_id: pid,
            visitor_id: v.id,
            sdk_identifier: v.sdk_identifier.to_s,
            uuid: v.uuid.to_s,
            synced_at: generation
          }
        end
        insert_batch(rows)
        total += rows.size
        refresh_lock(lock_key, token)
      end

      publish_generation(pid, generation)
      prune_superseded(pid, generation)
      total
    end

    # Post-publish only, so an async mutation can never race the live snapshot; failure is inert.
    def prune_superseded(project_id, generation)
      Clickhouse.with do |conn|
        conn.execute("DELETE FROM visitor_identities WHERE project_id = #{Integer(project_id)} " \
                     "AND synced_at < toDateTime64('#{generation}', 9, 'UTC')")
      end
    rescue StandardError => e
      Rails.logger.warn("VisitorIdentitySyncService: prune failed for #{project_id}: #{e.class} - #{e.message}")
    end

    # Raises on lost ownership rather than publishing an interleave.
    def refresh_lock(lock_key, token)
      return if lock_key.nil?

      renewed = REDIS.with do |c|
        c.eval("if redis.call('get', KEYS[1]) == ARGV[1] then return redis.call('expire', KEYS[1], ARGV[2]) else return 0 end",
               keys: [lock_key], argv: [token, LOCK_TTL.to_s])
      end
      return if renewed.to_i == 1

      raise LockLostError, "identity sync lost its lock mid-run (project lock #{lock_key})"
    end

    # CAS unlock so a TTL-expired holder can't delete a successor's lock.
    def release_lock(lock_key, token)
      REDIS.with do |c|
        c.eval("if redis.call('get', KEYS[1]) == ARGV[1] then return redis.call('del', KEYS[1]) else return 0 end",
               keys: [lock_key], argv: [token])
      end
    rescue StandardError => e
      Rails.logger.warn("VisitorIdentitySyncService: lock release failed: #{e.class} - #{e.message}")
    end

    # Strictly greater than any existing generation, so a clock rollback can't hide a newer sync.
    def next_generation(project_id)
      now = Time.current.utc.strftime('%Y-%m-%d %H:%M:%S.%9N')
      query = ClickHouse::Client::Query.new(
        raw_query: "SELECT toString(greatest(toDateTime64({now:String}, 9, 'UTC'), " \
                   "addNanoseconds(max(synced_at), 1))) FROM visitor_identities " \
                   'WHERE project_id = {project_id:UInt64}',
        placeholders: { now: now, project_id: Integer(project_id) }
      )
      Clickhouse.with { |conn| conn.select_value(query) }.presence || now
    end

    # Method, not constant ref, so tests can drive multi-batch failure paths.
    def batch_size = BATCH_SIZE

    # Raw insert: ClickhouseWriteService truncates synced_at to ms and the prune would eat it.
    def insert_batch(rows)
      Clickhouse.with { |conn| conn.insert('visitor_identities', rows) }
    end

    def publish_generation(project_id, generation)
      insert_batch([{ project_id: project_id, visitor_id: GENERATION_MARKER_VISITOR_ID,
                      sdk_identifier: '', uuid: '', synced_at: generation }])
    end

    # Readers must scope to this, or a half-written generation leaks in.
    def published_generation_sql(project_id)
      "(SELECT max(synced_at) FROM visitor_identities WHERE project_id = #{Integer(project_id)} " \
        "AND visitor_id = #{GENERATION_MARKER_VISITOR_ID})"
    end
  end
end
