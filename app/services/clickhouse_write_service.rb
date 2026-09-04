# frozen_string_literal: true

require 'digest/md5'

module ClickhouseWriteService
  # DateTime64(3, 'UTC') columns need 'YYYY-MM-DD HH:MM:SS' strings.
  TIMESTAMP_KEYS = %i[created_at purchase_date first_seen last_seen ingested_at updated_at].freeze

  # Durable (bounded retry -> DLQ) delivery hardening. Shared by canonical, purchase, and
  # events-table dual-writes so a CH hiccup parks rows for replay instead of dropping them.
  # NOTE: this does NOT move the PG processing-tray ack (PG stays source of truth); it only
  # makes the CH side recoverable. Moving the ack is the cutover restructure (needs a PG
  # event_id unique index first — see deliver_canonical).
  CANONICAL_MAX_ATTEMPTS = 3                  # bounded retry — never an infinite repush/storm
  CANONICAL_RETRY_SLEEP_SECONDS = 0.2         # tiny backoff between attempts
  CANONICAL_DLQ_KEY = "clickhouse:canonical:dlq"
  PURCHASE_DLQ_KEY = "clickhouse:purchase:dlq"
  CANONICAL_DLQ_MAX = 10_000                  # cap DLQ size so a sustained CH outage can't OOM Redis
  # Bounded per-request HTTP read timeout for the canonical insert so a hung CH
  # connection can't block for attempts × the 120s default import timeout. Env-overridable.
  CANONICAL_INSERT_TIMEOUT_SECONDS = Integer(ENV.fetch('CLICKHOUSE_CANONICAL_INSERT_TIMEOUT', 5))
  # When CH is source of truth, fail fast: a slow insert must not freeze the batch worker.
  # One bounded attempt with a short timeout — the processing-tray replay is the retry.
  CANONICAL_PRIMARY_MAX_ATTEMPTS = 1
  CANONICAL_PRIMARY_INSERT_TIMEOUT_SECONDS = Integer(ENV.fetch('CLICKHOUSE_PRIMARY_INSERT_TIMEOUT', 2))

  # Deterministic event identity for replay/backfill dedup.
  # MD5 is NOT used for security here — it's a fast, compact hash for
  # identifying duplicate event inserts. Collisions at this cardinality
  # are astronomically unlikely (~2^64 events needed for 50% collision).
  #
  # All call sites (live freeze in frozen_ch_fields, PG-row fallback in
  # resolve_ch_source, backfill build_canonical_row, and the A3 backstop) MUST
  # funnel through this one method so the hashed input is byte-identical across
  # them — otherwise the same logical event gets two ids and stops deduping.
  def self.generate_event_id(project_id:, device_id:, event_type:, created_at:, event_name:, session_id:, link_id: 0, engagement_time: 0, properties: nil,
                             sdk_event_id: nil)
    Digest::MD5.hexdigest(event_id_canonical_input(
      project_id: project_id, device_id: device_id, event_type: event_type,
      created_at: created_at, event_name: event_name, session_id: session_id,
      link_id: link_id, engagement_time: engagement_time, properties: properties,
      sdk_event_id: sdk_event_id
    ))
  end

  # Opaque, never case-folded: device_id namespaces the hash and a case-sensitive id scheme must stay usable.
  def self.normalize_sdk_event_id(value)
    return nil unless value.is_a?(String) || value.is_a?(Numeric)

    # Strip AFTER truncating too: truncation can expose trailing space, and this must be idempotent.
    id = value.to_s.strip.truncate(Grovs::Enrichment::MAX_STRING_LENGTH, omission: "").strip
    id.empty? ? nil : id
  end

  # The one typed builder for the hashed input. Normalizes every field identically
  # and emits an INJECTIVE JSON-array encoding so no free-form field (event_name,
  # session_id) can imitate a delimiter and collide with a different event — e.g.
  # event_name "a:b"/session "c" must NOT hash the same as "a"/"b:c".
  # Properties join the identity only when present (same-ms same-name events with
  # different payloads are distinct); absent/empty keeps the legacy id.
  def self.event_id_canonical_input(project_id:, device_id:, event_type:, created_at:, event_name:, session_id:, link_id: 0, engagement_time: 0,
                                    properties: nil, sdk_event_id: nil)
    fields = [
      project_id.to_i, device_id.to_i, event_type.to_s, created_at_to_ms(created_at),
      event_name.to_s, session_id.to_s, link_id.to_i, engagement_time.to_i
    ]
    canon = canonical_properties(properties)
    fields << canon if canon
    # Array tail, never a bare String: a String would collide with the properties tail above.
    sdk = normalize_sdk_event_id(sdk_event_id)
    fields << ["sdk", sdk] if sdk
    JSON.generate(fields)
  end
  private_class_method :event_id_canonical_input

  # Deep-sorted, string-keyed, capped like the CH row (cap_property_keys), so
  # freeze-time (uncapped payload) and row-time (capped row) hash identically.
  def self.canonical_properties(properties)
    hash = properties.is_a?(String) ? safe_parse_json(properties) : properties
    return nil unless hash.is_a?(Hash) && hash.any?

    sorted = deep_sort_properties(hash)
    capped = sorted.first(Analytics::Config::MAX_PROPERTY_KEYS_PER_EVENT).to_h
    JSON.generate(capped)
  end
  private_class_method :canonical_properties

  def self.safe_parse_json(str)
    JSON.parse(str)
  rescue JSON::ParserError
    nil
  end
  private_class_method :safe_parse_json

  def self.deep_sort_properties(obj)
    case obj
    when Hash then obj.map { |k, v| [k.to_s, deep_sort_properties(v)] }.sort_by(&:first).to_h
    when Array then obj.map { |v| deep_sort_properties(v) }
    else obj
    end
  end
  private_class_method :deep_sort_properties

  # created_at arrives as a Time (live freeze / backfill) or an iso8601(3) STRING
  # (the A3 backstop recomputes from the Redis payload). Both must map to the SAME
  # integer millisecond or a retry/replay would stop deduping. to_r keeps it exact
  # and floors to ms, matching how iso8601(3) truncates the sub-ms tail.
  def self.created_at_to_ms(created_at)
    t = case created_at
        when Time, ActiveSupport::TimeWithZone then created_at
        else (Time.zone.parse(created_at.to_s) if created_at.present?)
        end
    return 0 if t.nil? # malformed/blank created_at (last-resort backstop) — never crash the batch
    (t.to_r * 1000).to_i
  end
  private_class_method :created_at_to_ms

  # Single-attempt insert into the deduped `events` store. Stamps ingested_at so
  # the ReplacingMergeTree version column collapses duplicate deliveries by
  # event_id. Used directly by tests; production goes through deliver_canonical.
  def self.insert_canonical_events(ch_rows)
    insert_to_table('events', stamp_ingested_at(ensure_event_ids(ch_rows)))
  end

  # Timestamps stringified so a JSONB round-trip stays CH-parseable.
  def self.prepare_canonical_rows(ch_rows)
    stamp_ingested_at(ensure_event_ids(ch_rows)).map { |r| format_timestamps(r) }
  end

  # Single attempt, no DLQ — the caller spills on false.
  def self.insert_prepared_events(rows, timeout: CANONICAL_PRIMARY_INSERT_TIMEOUT_SECONDS)
    return true if rows.empty?

    Clickhouse.with_request_timeout(timeout) { raw_insert('events', rows) }
    true
  rescue StandardError => e
    Rails.logger.error("ClickhouseWriteService: primary insert failed (#{rows.size} rows): #{e.class} - #{e.message}")
    false
  end

  # No rescue — the drain job records the raw error.
  def self.insert_spilled(rows)
    return if rows.empty?

    Clickhouse.with_request_timeout(CANONICAL_INSERT_TIMEOUT_SECONDS) { raw_insert('events', rows) }
  end

  # Guard: every canonical row MUST carry a non-blank event_id — it is BOTH the
  # ReplacingMergeTree dedup key (FINAL collapses replays/re-ingests to one) AND
  # the sessionization/explorer dedup key. Upstream builders (frozen_ch_fields,
  # resolve_ch_source, backfill) always set it, but a blank id slipping through
  # here would (a) defeat FINAL dedup and (b) let genuinely-distinct blank rows
  # collapse under FINAL (silent loss). Recompute deterministically from the
  # row's own fields so a byte-identical event still hashes to the same id.
  def self.ensure_event_ids(rows)
    rows.map do |r|
      next r if r[:event_id].present?

      r.merge(event_id: generate_event_id(
        project_id: r[:project_id], device_id: r[:device_id], event_type: r[:event_type],
        created_at: r[:created_at], event_name: r[:event_name], session_id: r[:session_id],
        link_id: r[:link_id].to_i, engagement_time: r[:engagement_time].to_i,
        properties: r[:properties]
      ))
    end
  end
  private_class_method :ensure_event_ids

  # Durable, bounded delivery of canonical rows. Retries a transient CH failure
  # a bounded number of times, then routes the batch to a Redis DLQ instead of
  # repushing forever (no storm). Always emits a delivery-latency metric so lag
  # is observable. ReplacingMergeTree dedups on event_id (a deterministic content hash), so any
  # byte-identical event — crash replay OR independent same-content re-ingest — collapses to one.
  #
  # NOTE on PG-as-source-of-truth: this is a SEPARATE durable path from the PG
  # processing-tray ack. It does NOT move the PG ack, so it cannot cause a PG
  # double-insert. Moving the ack to after CH confirm is deferred to cutover
  # (Phase 6) — see plan; doing it now would re-drive the single PG recovery
  # handle and duplicate PG rows (PG events has no event_id unique constraint).
  def self.deliver_canonical(ch_rows, before_attempt: nil)
    fast = Clickhouse.primary?
    deliver_with_dlq('events', stamp_ingested_at(ensure_event_ids(ch_rows)), CANONICAL_DLQ_KEY,
                     metric: "clickhouse.canonical.delivery_ms", before_attempt: before_attempt,
                     max_attempts: fast ? CANONICAL_PRIMARY_MAX_ATTEMPTS : CANONICAL_MAX_ATTEMPTS,
                     timeout: fast ? CANONICAL_PRIMARY_INSERT_TIMEOUT_SECONDS : CANONICAL_INSERT_TIMEOUT_SECONDS)
  end

  # Durable delivery of purchase rows (revenue is business-critical — never silently dropped).
  # purchase_events is ReplacingMergeTree(created_at), so a replay/retry of the same
  # (project_id, transaction_id, event_type) collapses; bounded retry then DLQ.
  def self.deliver_purchase_events(ch_rows)
    # Guarded here (unlike deliver_canonical, whose batch-processor call site is already
    # gated by ch_enabled): the purchase job calls this unconditionally, so a disabled-CH
    # run must no-op rather than spuriously DLQ.
    return true unless Clickhouse.enabled?

    deliver_with_dlq('purchase_events', ch_rows, PURCHASE_DLQ_KEY, metric: "clickhouse.purchase.delivery_ms")
  end

  # NOTE: `events` is the single CH events table (ReplacingMergeTree deduped by event_id),
  # DLQ-backed above so a CH hiccup parks rows for replay. Explorer, sessions, and the
  # rebuilt breakdown rollups all read it. PG remains the source of truth (this path does
  # not move the PG processing-tray ack).

  # The shared bounded-retry -> DLQ engine. Returns true on insert success, false once the
  # batch is parked in the DLQ (caller-observable). A before_attempt hook (e.g. heartbeat
  # refresh) runs each attempt and may never escape the DLQ/metric path.
  def self.deliver_with_dlq(table, rows, dlq_key, metric:, before_attempt: nil,
                            max_attempts: CANONICAL_MAX_ATTEMPTS, timeout: CANONICAL_INSERT_TIMEOUT_SECONDS)
    return true if rows.empty?

    started = monotonic_ms
    attempt = 0
    last_error = nil

    while attempt < max_attempts
      attempt += 1
      begin
        before_attempt&.call
      rescue StandardError => e
        Rails.logger.warn("ClickhouseWriteService: before_attempt hook raised: #{e.class} - #{e.message}")
      end
      begin
        Clickhouse.with_request_timeout(timeout) do
          raw_insert(table, rows)
        end
        emit_delivery_metric(started, attempt, "ok", metric)
        return true
      rescue StandardError => e
        last_error = e
        sleep(CANONICAL_RETRY_SLEEP_SECONDS) if attempt < max_attempts
      end
    end

    route_to_dlq(table, rows, dlq_key, last_error)
    emit_delivery_metric(started, attempt, "dlq", metric)
    false
  end
  private_class_method :deliver_with_dlq

  def self.insert_purchase_events(ch_rows)
    insert_to_table('purchase_events', ch_rows)
  end

  # Visitor identity-map aliases (merged -> survivor). ReplacingMergeTree on
  # (project_id, from_visitor_id) by updated_at, so re-inserting an alias is an
  # idempotent upsert. Used by ClickhouseIdentityMapService during visitor merge.
  def self.insert_identity_rows(rows)
    insert_to_table('visitor_identity_map', rows)
  end

  def self.upsert_user_profile(row)
    upsert_user_profiles([row])
  end

  def self.upsert_user_profiles(rows)
    insert_to_table('user_profiles', rows)
  end

  # Replay DLQ'd batches once CH is back. drain_*_dlq wrappers select the queue; the entry's
  # stored `table` selects the insert target (default keeps old canonical entries working).
  # Idempotent (ReplacingMergeTree on each table), so replaying an already-delivered batch is safe.
  def self.drain_canonical_dlq(limit: 100)
    drain_dlq(CANONICAL_DLQ_KEY, default_table: 'events', limit: limit)
  end

  def self.drain_purchase_dlq(limit: 100)
    drain_dlq(PURCHASE_DLQ_KEY, default_table: 'purchase_events', limit: limit)
  end

  # Combined parked-batch backlog across both DLQs, for depth monitoring/alerting.
  def self.dlq_depth
    REDIS.with { |conn| conn.llen(CANONICAL_DLQ_KEY).to_i + conn.llen(PURCHASE_DLQ_KEY).to_i }
  rescue Redis::BaseError => e
    Rails.logger.warn("ClickhouseWriteService.dlq_depth failed: #{e.class} - #{e.message}")
    0
  end

  # Pops up to `limit` entries; a batch that still fails is re-parked (tail) so it doesn't
  # block the queue or spin. Returns the number of batches successfully drained.
  def self.drain_dlq(dlq_key, default_table:, limit: 100)
    drained = 0
    limit.times do
      raw = REDIS.with { |conn| conn.rpop(dlq_key) }
      break if raw.nil?

      begin
        # Parse inside the per-entry begin so a malformed entry is skipped (dropped,
        # not re-parked forever) and the drain keeps going on the next entry.
        parsed = JSON.parse(raw)
        table = parsed["table"].presence || default_table
        # Drop rows for projects deleted since this batch was parked — replaying them
        # would resurrect a GDPR-erased project's CH data. The batch is still consumed.
        rows = ClickhouseDeleteService.reject_tombstoned(parsed["rows"].map(&:symbolize_keys))
        raw_insert(table, rows) unless rows.empty?
        drained += 1
      rescue JSON::ParserError => e
        Rails.logger.warn("ClickhouseWriteService: DLQ drain skipping unparseable entry: #{e.class} - #{e.message}")
        next
      rescue StandardError => e
        REDIS.with { |conn| conn.lpush(dlq_key, raw) }
        Rails.logger.warn("ClickhouseWriteService: DLQ drain re-parked a batch: #{e.class} - #{e.message}")
        break
      end
    end
    drained
  rescue Redis::BaseError => e
    Rails.logger.warn("ClickhouseWriteService: DLQ drain failed: #{e.class} - #{e.message}")
    drained
  end
  private_class_method :drain_dlq

  def self.format_timestamps(row)
    formatted = row.dup
    TIMESTAMP_KEYS.each do |key|
      v = formatted[key]
      formatted[key] = v.utc.strftime(Analytics::QueryHelpers::CH_DATETIME_FMT) if v.is_a?(Time) || v.is_a?(ActiveSupport::TimeWithZone)
    end
    formatted
  end
  private_class_method :format_timestamps

  def self.insert_to_table(table, rows)
    return true unless Clickhouse.enabled?
    return true if rows.empty?

    raw_insert(table, rows)
    true
  rescue StandardError => e
    log_failure(table, rows.size, e)
    false
  end
  private_class_method :insert_to_table

  # The bare CH insert (no rescue) — the seam tests stub to simulate CH failure.
  def self.raw_insert(table, rows)
    return if rows.empty?

    Clickhouse.with { |conn| conn.insert(table, rows.map { |r| format_timestamps(r) }) }
  end
  private_class_method :raw_insert

  def self.stamp_ingested_at(rows)
    now = Time.current
    rows.map { |r| r.key?(:ingested_at) ? r : r.merge(ingested_at: now) }
  end
  private_class_method :stamp_ingested_at

  def self.monotonic_ms
    Process.clock_gettime(Process::CLOCK_MONOTONIC) * 1000.0
  end
  private_class_method :monotonic_ms

  def self.emit_delivery_metric(started_ms, attempts, status, metric)
    Grovs::Metrics.histogram(metric, monotonic_ms - started_ms,
      tags: { status: status, attempts: attempts })
  rescue StandardError => e
    # A metrics-client failure must never break delivery.
    Rails.logger.warn("ClickhouseWriteService: delivery metric emit failed: #{e.class} - #{e.message}")
  end
  private_class_method :emit_delivery_metric

  # Park a permanently-failing batch in a bounded Redis list for later replay. The `table`
  # is stored in the entry so the drainer re-inserts into the right table. Bounded (LTRIM)
  # so a sustained CH outage can't grow Redis without limit.
  def self.route_to_dlq(table, rows, dlq_key, error)
    # Pre-format timestamps to CH's 'YYYY-MM-DD HH:MM:SS.mmm' so a JSON round-trip
    # through Redis doesn't leave ISO8601 strings that JSONEachRow can't parse.
    formatted = rows.map { |r| format_timestamps(r) }
    payload = { table: table, rows: formatted, error: error&.message, at: Time.current.utc.iso8601 }.to_json
    REDIS.with do |conn|
      new_len = conn.lpush(dlq_key, payload)
      conn.ltrim(dlq_key, 0, CANONICAL_DLQ_MAX - 1)
      # ltrim silently drops the oldest parked batches once the list is full. Each is
      # ~500 events, so an eviction is real data loss — surface it, don't hide it.
      evicted = new_len - CANONICAL_DLQ_MAX
      if evicted.positive?
        Grovs::Metrics.increment("clickhouse.dlq.evicted", by: evicted, tags: { table: table })
        Rails.logger.error(
          "ClickhouseWriteService: CRITICAL — DLQ full (#{CANONICAL_DLQ_MAX}), evicted " \
          "#{evicted} oldest batch(es) permanently, table=#{table}"
        )
      end
    end
    Rails.logger.error(
      "ClickhouseWriteService: #{table} batch (#{rows.size} rows) sent to DLQ after " \
      "#{CANONICAL_MAX_ATTEMPTS} attempts — #{error&.class}: #{error&.message}"
    )
    Grovs::Metrics.increment("clickhouse.dlq", by: rows.size, tags: { table: table })
  rescue StandardError => e
    # Broad rescue: formatting/metrics/Redis can all raise here. Nothing must escape
    # silently — always log the CRITICAL "rows lost" line so the loss is observable.
    Rails.logger.error("ClickhouseWriteService: CRITICAL — DLQ write failed, #{rows.size} rows lost: #{e.class} - #{e.message}")
  end
  private_class_method :route_to_dlq

  def self.log_failure(table, count, error)
    Rails.logger.error(
      "ClickhouseWriteService: failed to write #{count} rows to #{table} — " \
      "#{error.class}: #{error.message}"
    )
    # Surfaces PG↔CH drift (fire-and-forget writes are never retried). Counts rows lost.
    Grovs::Metrics.increment("clickhouse.write.failed", by: count, tags: { table: table })
  end
  private_class_method :log_failure
end
