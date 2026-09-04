class EventIngestionService

  # The app's REDIS is redis-rb; Sidekiq 7 enqueues over redis-client. An outage raises either.
  ENQUEUE_ERRORS = [Redis::BaseError, RedisClient::Error].freeze

  class << self

    def log(type, project, device, data, link, engagement_time = nil,
            created_at: nil, event_name: nil, session_id: nil, tags: nil, ch_meta: nil)
      # Stamped here, not at save time: CH identity hashes it, so it must match the frozen LPUSH instant.
      occurred_at = created_at || Time.current
      event = event_for_params(type, project, device, data, link, engagement_time,
                                created_at: occurred_at, event_name: event_name, session_id: session_id, tags: tags)
      # Replays carry the original frozen meta; the link may have been mutated or deleted since.
      ch_meta = normalize_ch_meta(ch_meta, link) ||
                frozen_ch_fields(type, project.id, device&.id, link, occurred_at,
                                 event.event_name.to_s, event.session_id.to_s, engagement_time, data)

      update_event_visitor_if_needed(device, project)
      # Before the txn: keeps enrichment out of it, and pins inviter_id pre-referral like the batch path.
      spill = prepare_spill(event, ch_meta)

      referral = nil
      ActiveRecord::Base.transaction do
        referral = add_invited_by_event_if_needed(type, device, link, event, project, ch_meta)
        event.save!
        store_spill(spill)
      end

      # process_event swallows DB errors, so it must not run where one could poison a live transaction.
      # Ids, not instances: never dispatch on a caller's uncommitted edits to these records.
      dispatch_ids = [event.id, referral&.id].compact
      ActiveRecord.after_all_transactions_commit { dispatch_committed(dispatch_ids) }

      event
    end

    def log_event_without_view_duplicates(type, project, device, data, link, engagement_time = nil,
                                          created_at: nil, event_name: nil, session_id: nil, tags: nil, ch_meta: nil)
      new_event = event_for_params(type, project, device, data, link, engagement_time,
                                    created_at: created_at, event_name: event_name, session_id: session_id, tags: tags)

      if new_event.event == Grovs::Events::VIEW
        # 5s dedup window: matches the Redis-based dedup in BatchEventProcessorJob.
        # This is the synchronous fallback path (used when Redis LPUSH fails);
        # same window ensures consistent dedup behavior regardless of code path.
        old_event = Event.where(event: new_event.event, device_id: new_event.device_id,
                                project_id: new_event.project_id)
                        .where("created_at >= ?", 5.seconds.ago)
                        .order(created_at: :desc)
                        .first
        if old_event
          # we have an old invited by event update created at
          old_event.update_column(:created_at, Time.current)
          return old_event
        end
      end

      log(type, project, device, data, link, engagement_time,
          created_at: created_at, event_name: event_name, session_id: session_id, tags: tags, ch_meta: ch_meta)
    end

    # sidekiq_fallback: false → Redis failure goes straight to sync (no Sidekiq loop)
    def log_async(type, project, device, data, link, engagement_time = nil,
                  created_at: nil, event_name: nil, session_id: nil, tags: nil, sidekiq_fallback: true, ch_meta: nil)
      update_visitor_last_visit(project, device, link)
      enqueue_event(type, project, device, data, link, engagement_time,
                    created_at: created_at, event_name: event_name, session_id: session_id, tags: tags,
                    sidekiq_fallback: sidekiq_fallback, ch_meta: ch_meta)
    end

    # Bulk-enqueue pre-built payload hashes into the events:pending Redis list.
    # Uses a single LPUSH call for all payloads. Falls back to individual Sidekiq
    # jobs if Redis is unavailable.
    #
    # NOTE: Unlike log_async, this does NOT call update_visitor_last_visit upfront.
    # VisitorLastVisit is updated later by BatchEventProcessorJob#bulk_upsert_visitor_last_visits.
    # This is intentional — doing N synchronous DB writes would negate the batching benefit.
    def enqueue_events(payloads)
      return if payloads.empty?

      # Every enqueued payload must carry a frozen event_id (backstop against content-hash fallback collapse).
      payloads.each { |payload| ensure_frozen_event_id!(payload) }

      json_payloads = payloads.map(&:to_json)
      REDIS.lpush(BatchEventProcessorJob::REDIS_KEY, json_payloads)
    rescue Redis::BaseError => e
      Rails.logger.warn("EventIngestionService: batch LPUSH failed, falling back to Sidekiq: #{e.message}")
      payloads.each do |payload|
        LogEventJob.perform_async(
          payload_value(payload, :type), payload_value(payload, :project_id), payload_value(payload, :device_id),
          payload_value(payload, :data), payload_value(payload, :link_id), payload_value(payload, :engagement_time),
          payload_value(payload, :created_at), payload_value(payload, :event_name), payload_value(payload, :session_id),
          payload_value(payload, :tags), payload_ch_meta(payload).stringify_keys
        )
      rescue *ENQUEUE_ERRORS => inner
        Rails.logger.error("EventIngestionService: Sidekiq fallback also failed: #{inner.message}")
        fallback_payload_to_sync(payload)
      end
    end

    # Phase 1: freeze attribution source + event identity at ingest time, before any
    # later visitor/device merge can rewrite links.visitor_id or events.device_id.
    # build_clickhouse_row reads these frozen values instead of re-joining the link,
    # so CH attribution is deterministic across merges and replays.
    #
    # event_id is the DETERMINISTIC content hash (not a random UUID): a byte-identical
    # retry collapses, while engagement_time keeps same-ms events with different
    # durations distinct. engagement_time is normalized identically
    # (Event.clamp_engagement_time -> to_i) in the live, backfill, and archive paths, so
    # the frozen id equals the backfill/fallback id for the same event.
    def frozen_ch_fields(type, project_id, device_id, link, created_at_time, event_name, session_id, engagement_time, data, sdk_event_id: nil)
      sdk_id = ClickhouseWriteService.normalize_sdk_event_id(sdk_event_id)
      {
        link_id: link&.id,
        campaign_id: link&.campaign_id,
        sdk_generated: link&.sdk_generated || false,
        link_visitor_id: link&.visitor_id,
        event_id: ClickhouseWriteService.generate_event_id(
          project_id: project_id, device_id: device_id, event_type: type,
          created_at: created_at_time, event_name: event_name.to_s, session_id: session_id.to_s,
          link_id: link&.id || 0, engagement_time: Event.clamp_engagement_time(engagement_time).to_i,
          properties: data, sdk_event_id: sdk_id
        )
      }
    end

    # A key absent from an in-flight payload was never frozen: resolve it against the link, or the
    # present-but-nil value reads downstream as deliberate organic attribution.
    def normalize_ch_meta(meta, link)
      return unless meta

      meta = meta.symbolize_keys
      {
        event_id: meta[:event_id],
        link_id: meta.key?(:link_id) ? meta[:link_id] : link&.id,
        campaign_id: meta.key?(:campaign_id) ? meta[:campaign_id] : link&.campaign_id,
        sdk_generated: meta.key?(:sdk_generated) ? meta[:sdk_generated] : (link&.sdk_generated || false),
        link_visitor_id: meta.key?(:link_visitor_id) ? meta[:link_visitor_id] : link&.visitor_id
      }
    end

    # Inherits the causal install's frozen source and id, so both writers agree and a replay collapses.
    # No link_id: the referral is credited to the referrer, not to the install's link.
    def referral_ch_meta(install_ch_meta)
      install_event_id = install_ch_meta[:event_id]
      {
        event_id: install_event_id ? Digest::MD5.hexdigest("#{install_event_id}:user_referred") : nil,
        campaign_id: install_ch_meta[:campaign_id],
        sdk_generated: install_ch_meta[:sdk_generated],
        link_visitor_id: install_ch_meta[:link_visitor_id]
      }
    end

    private

    # dev/test: raise on a missing event_id (catch a producer that forgot to freeze).
    # prod: recompute the SAME deterministic id the producer should have frozen — never
    # a random UUID, which would stop this event deduping against its retries.
    def ensure_frozen_event_id!(payload)
      return if payload[:event_id].present? || payload["event_id"].present?

      if Rails.env.local?
        raise ArgumentError, "enqueue_events: payload missing event_id (type=#{payload[:type] || payload['type']})"
      end

      payload[:event_id] = backstop_event_id(payload)
      Rails.logger.error("EventIngestionService: payload missing event_id — backstop-recomputed; producer should freeze it via frozen_ch_fields")
      Grovs::Metrics.increment("events.missing_event_id")
    end

    # Rebuild the deterministic id from the Redis payload (created_at is an iso8601(3)
    # STRING here — the builder parses it back to the same ms). Mirrors frozen_ch_fields
    # exactly, including the engagement_time clamp, so the recomputed id matches.
    def backstop_event_id(payload)
      ClickhouseWriteService.generate_event_id(
        project_id: payload_value(payload, :project_id),
        device_id: payload_value(payload, :device_id),
        event_type: payload_value(payload, :type),
        created_at: payload_value(payload, :created_at),
        event_name: payload_value(payload, :event_name).to_s,
        session_id: payload_value(payload, :session_id).to_s,
        link_id: payload_value(payload, :link_id).to_i,
        engagement_time: Event.clamp_engagement_time(payload_value(payload, :engagement_time)).to_i,
        properties: payload_value(payload, :data)
      )
    end

    # The sync path never reaches the batch processor, the only live CH writer.
    def prepare_spill(event, ch_meta)
      return unless Clickhouse.enabled?

      device = event.device
      return unless device

      visitor = device.visitor_for_project_id(event.project_id)
      return park_visitorless(event, device) unless visitor

      row = ClickhouseEventRowBuilder.new.build_row(sync_pg_row(event, ch_meta), device, visitor, event.link)
      ClickhouseWriteService.prepare_canonical_rows([row])
    rescue StandardError => e
      # Enrichment failed, not CH storage: a PG-only row is backfillable, a dropped one is not.
      Rails.logger.error("EventIngestionService: CH row build failed, PG keeps the event: #{e.class} - #{e.message}")
      Grovs::Metrics.increment("clickhouse.spill.sync_failed")
      nil
    end

    # Primary: the spill is the event's only home. Otherwise savepoint it — PG owns the truth.
    def store_spill(prepared)
      return if prepared.blank?
      return ClickhouseSpillRepository.store(prepared) if Clickhouse.primary?

      ActiveRecord::Base.transaction(requires_new: true) { ClickhouseSpillRepository.store(prepared) }
    rescue StandardError => e
      raise if Clickhouse.primary?

      Rails.logger.error("EventIngestionService: CH spill failed, PG keeps the event: #{e.class} - #{e.message}")
      Grovs::Metrics.increment("clickhouse.spill.sync_failed")
      nil
    end

    # Mirrors the batch integrity guard: a visitorless row must never reach CH.
    def park_visitorless(event, device)
      Rails.logger.error(
        "EventIngestionService: INTEGRITY visitor missing, event not spilled to CH — " \
        "project_id=#{event.project_id} device_id=#{device.id} type=#{event.event}"
      )
      Grovs::Metrics.increment("events.sync_spill_visitorless", tags: { event_type: event.event })
      nil
    end

    def sync_pg_row(event, ch_meta)
      {
        project_id: event.project_id,
        event: event.event,
        device_id: event.device_id,
        link_id: event.link_id,
        data: event.data,
        engagement_time: event.engagement_time,
        ip: event.ip,
        remote_ip: event.remote_ip,
        vendor_id: event.vendor_id,
        platform: event.platform,
        app_version: event.app_version,
        build: event.build,
        path: event.path,
        created_at: event.created_at,
        event_name: event.event_name.to_s,
        session_id: event.session_id.to_s,
        tags: Array(event.tags),
        ch_meta: ch_meta
      }
    end

    def update_visitor_last_visit(project, device, link)
      return unless link && device

      visitor = device.visitor_for_project_id(project.id)
      return unless visitor

      # on_duplicate, not update_only: must refresh updated_at too (merge picks by recency).
      VisitorLastVisit.upsert(
        { project_id: project.id, visitor_id: visitor.id, link_id: link.id,
          created_at: Time.current, updated_at: Time.current },
        unique_by: :index_vlv_on_project_and_visitor,
        on_duplicate: Arel.sql("link_id = excluded.link_id, updated_at = excluded.updated_at")
      )
    rescue StandardError => e
      Rails.logger.error("update_visitor_last_visit failed: #{e.message}")
    end

    def enqueue_event(type, project, device, data, link, engagement_time,
                      created_at: nil, event_name: nil, session_id: nil, tags: nil, sidekiq_fallback: true, ch_meta: nil)
      created_at_time = created_at || Time.current
      max_len = Grovs::Enrichment::MAX_STRING_LENGTH
      trunc_event_name = event_name.to_s.truncate(max_len, omission: "")
      trunc_session_id = session_id.to_s.truncate(max_len, omission: "")
      timestamp = created_at_time.iso8601(3)
      sanitized_tags = Array(tags).first(Grovs::Enrichment::MAX_TAGS).map { |t| t.to_s.truncate(max_len, omission: "") }
      ch_fields = ch_meta || frozen_ch_fields(type, project.id, device.id, link, created_at_time,
                                              trunc_event_name, trunc_session_id, engagement_time, data)
      payload = {
        type: type,
        project_id: project.id,
        device_id: device.id,
        data: data,
        link_id: link&.id,
        engagement_time: engagement_time,
        created_at: timestamp,
        event_name: trunc_event_name,
        session_id: trunc_session_id,
        tags: sanitized_tags
      }.merge(ch_fields).to_json

      REDIS.lpush(BatchEventProcessorJob::REDIS_KEY, payload)
    rescue Redis::BaseError => e
      if sidekiq_fallback
        Rails.logger.error("log_async Redis LPUSH failed, falling back to Sidekiq: #{e.class} - #{e.message}")
        fallback_to_sidekiq(type, project, device, data, link, engagement_time, timestamp,
                            created_at: created_at_time, event_name: event_name, session_id: session_id, tags: tags,
                            ch_meta: ch_fields)
      else
        Rails.logger.error("log_async Redis LPUSH failed, falling back to sync (no Sidekiq re-enqueue): #{e.class} - #{e.message}")
        # created_at_time + ch_fields: an ambiguous LPUSH may have queued the payload, and only the frozen
        # values re-hash to its event_id.
        fallback_to_sync(type, project, device, data, link, engagement_time,
                         created_at: created_at_time, event_name: event_name, session_id: session_id, tags: tags,
                         ch_meta: ch_fields)
      end
    end

    def fallback_to_sidekiq(type, project, device, data, link, engagement_time, timestamp,
                            created_at: nil, event_name: nil, session_id: nil, tags: nil, ch_meta: nil)
      max_len = Grovs::Enrichment::MAX_STRING_LENGTH
      LogEventJob.perform_async(
        type,
        project.id,
        device.id,
        data,
        link&.id,
        engagement_time,
        timestamp,
        event_name.to_s.truncate(max_len, omission: ""),
        session_id.to_s.truncate(max_len, omission: ""),
        Array(tags).first(Grovs::Enrichment::MAX_TAGS).map { |t| t.to_s.truncate(max_len, omission: "") },
        ch_meta&.stringify_keys
      )
    rescue *ENQUEUE_ERRORS => e
      Rails.logger.error("log_async Sidekiq fallback failed, falling back to sync: #{e.class} - #{e.message}")
      fallback_to_sync(type, project, device, data, link, engagement_time,
                       created_at: created_at, event_name: event_name, session_id: session_id, tags: tags,
                       ch_meta: ch_meta)
    end

    def fallback_to_sync(type, project, device, data, link, engagement_time,
                         created_at: nil, event_name: nil, session_id: nil, tags: nil, ch_meta: nil)
      # Reaches CH via the spill, not the batch writer — keep the detour observable
      Grovs::Metrics.increment("events.sync_pg_fallback") if Clickhouse.primary?
      log_event_without_view_duplicates(type, project, device, data, link, engagement_time,
                                         created_at: created_at, event_name: event_name, session_id: session_id,
                                         tags: tags, ch_meta: ch_meta)
    rescue StandardError => e
      Rails.logger.error("log_async sync fallback also failed, event lost: #{e.class} - #{e.message}")
      # Every path failed (Redis + Sidekiq + sync DB) — the event is gone. Emit a
      # metric so dropped events are observable, not buried in logs.
      Grovs::Metrics.increment("events.dropped", tags: { event_type: type })
    end

    def fallback_payload_to_sync(payload)
      type = payload_value(payload, :type)
      project = Project.find_by(id: payload_value(payload, :project_id))
      device = Device.find_by(id: payload_value(payload, :device_id))

      unless project && device
        Grovs::Metrics.increment("events.dropped", tags: { event_type: type })
        return
      end

      link_id = payload_value(payload, :link_id)
      link = link_id.present? ? Link.find_by(id: link_id) : nil
      created_at = parse_payload_created_at(payload_value(payload, :created_at))

      fallback_to_sync(
        type,
        project,
        device,
        payload_value(payload, :data),
        link,
        payload_value(payload, :engagement_time),
        created_at: created_at,
        event_name: payload_value(payload, :event_name),
        session_id: payload_value(payload, :session_id),
        tags: payload_value(payload, :tags),
        ch_meta: payload_ch_meta(payload)
      )
    rescue StandardError => e
      Rails.logger.error("EventIngestionService: sync batch fallback failed: #{e.class} - #{e.message}")
      Grovs::Metrics.increment("events.dropped", tags: { event_type: type })
    end

    def payload_value(payload, key)
      payload[key] || payload[key.to_s]
    end

    # Only keys the payload actually froze: resolve_ch_source reads a present-but-nil key as organic.
    def payload_ch_meta(payload)
      %i[event_id link_id campaign_id sdk_generated link_visitor_id].each_with_object({}) do |key, meta|
        meta[key] = payload_value(payload, key) if payload.key?(key) || payload.key?(key.to_s)
      end
    end

    def parse_payload_created_at(value)
      return if value.blank?
      return value if value.is_a?(Time) || value.is_a?(ActiveSupport::TimeWithZone)
      return value.to_time if value.respond_to?(:to_time) && !value.is_a?(String)

      Time.zone.parse(value.to_s)
    rescue ArgumentError
      nil
    end

    # Reloads committed state; a rolled-back or purged row simply has no stats to dispatch.
    def dispatch_committed(event_ids)
      by_id = Event.includes(:device).where(id: event_ids).index_by(&:id)
      event_ids.each { |id| process_event(by_id[id]) if by_id[id] }
    end

    def process_event(event)
      
      EventStatDispatchService.call_normal_event(event)
    rescue StandardError => e
      Rails.logger.error("Failed to process event #{event.id}: #{e.class} - #{e.message}")
      Rails.logger.error(e.backtrace.join("\n"))
      # Retry it on another queue
      ProcessNormalEventJob.perform_async(event.id)
      
    end

    def add_invited_by_event_if_needed(type, device, link, event, project, install_ch_meta)
      if type != Grovs::Events::INSTALL && type != Grovs::Events::REINSTALL
        return
      end

      return unless device && link

      visitor = device.visitor_for_project_id(project.id)
      return unless visitor && link.visitor

      unless visitor.inviter_id
        visitor.inviter_id = link.visitor.id
        visitor.save!
      end

      event.event = type
      event.project = project
      event.device = device
      event.link = link

      if link.visitor
        create_user_referred_event(project, link.visitor, install_ch_meta, event.created_at)
      end
    end

    def create_user_referred_event(project, visitor, install_ch_meta, occurred_at)
      return unless visitor.device

      event = event_for_params(Grovs::Events::USER_REFERRED, project, visitor.device, nil, nil, nil,
                               created_at: occurred_at)

      # Caller's transaction: the referral commits with its causal install or not at all.
      spill = prepare_spill(event, referral_ch_meta(install_ch_meta))
      event.save!
      store_spill(spill)

      # Caller dispatches stats after commit: process_event swallows DB errors, poisoning this txn.
      event
    end

    def update_event_visitor_if_needed(device, project)
      visitor = device&.visitor_for_project_id(project.id)
      if visitor
        visitor.touch
      end
    end

    def event_for_params(type, project, device, data, link, engagement_time = nil,
                         created_at: nil, event_name: nil, session_id: nil, tags: nil)
      event = Event.new()
      event.event = type
      event.project = project
      event.device = device
      event.data = data
      event.link = link
      event.engagement_time = Event.clamp_engagement_time(engagement_time)
      event.created_at = created_at if created_at
      max_len = Grovs::Enrichment::MAX_STRING_LENGTH
      event.event_name = event_name.to_s.truncate(max_len, omission: "") if event_name.present?
      event.session_id = session_id.to_s.truncate(max_len, omission: "") if session_id.present?
      if tags.present?
        event.tags = Array(tags).first(Grovs::Enrichment::MAX_TAGS).map { |t| t.to_s.truncate(max_len, omission: "") }
      end

      if device
        event.ip = device.ip
        event.remote_ip = device.remote_ip
        event.vendor_id = device.vendor
        event.platform = device.platform
        event.app_version = device.app_version
        event.build = device.build
      end

      if link
        event.path = link.path
      end

      event
    end

  end

end
