# frozen_string_literal: true

require_relative "scenario_input"
require_relative "matrix_generator"

module AnalyticsMatrix
  # Ingest harness + 3-pass reconciliation, mixed into the integration tests.
  # The test registers its fixtures via #register_matrix_world.
  module ScenarioDSL
    # Resolved fixtures for one scenario.
    ScenarioBinding = Struct.new(
      :project_id, :device, :visitor, :link, :headers,
      keyword_init: true
    ) do
      def device_id    = device&.id
      def link_id      = link&.id
      def link_path    = link&.path
      def campaign_id  = link&.campaign_id
      def sdk_generated = link&.sdk_generated == true
    end

    # PG Event column name for each logical shared field (CH uses the key as-is).
    PG_COL = { event_type: :event }.freeze

    # ---- world registration (called from the test's setup) -------------------

    # devices_by_platform: { "ios" => {device:, visitor:, headers:}, ... }
    # links_by_attribution: { no_link: nil, plain_link: <Link>, campaign_link: <Link>, inviter_link: <Link> }
    def register_matrix_world(project:, devices_by_platform:, links_by_attribution:)
      @matrix_project = project
      @matrix_devices = devices_by_platform
      @matrix_links   = links_by_attribution
    end

    def bind_scenario(scn)
      dev = @matrix_devices.fetch(scn.platform)
      link = @matrix_links.fetch(scn.attribution)
      visitor = scn.visitor == :with_visitor ? dev[:visitor] : nil
      ScenarioBinding.new(
        project_id: @matrix_project.id,
        device: dev[:device],
        visitor: visitor,
        link: link,
        headers: dev[:headers]
      )
    end

    # ---- ingest (real HTTP -> Redis -> job) ----------------------------------

    # Packs scenarios into <=50-event batches (one request per device, since the
    # endpoint authenticates as one device), then drains.
    def ingest_via_http(scenarios)
      scenarios.group_by(&:platform).each do |platform, group|
        dev = @matrix_devices.fetch(platform)
        group.each_slice(Api::V1::Sdk::EventsController::MAX_BATCH_SIZE) do |slice|
          post "#{AuthTestHelper::SDK_PREFIX}/events/batch",
               params: { events: slice.map { |scn| http_event_payload(scn) } },
               headers: dev[:headers]
          assert_response :ok
          # 200 is returned even if all events are rejected — assert acceptance.
          assert_equal slice.size, response.parsed_body["accepted"],
                       "batch endpoint rejected events: #{response.parsed_body["errors"]}"
        end
      end
      drain_event_queue!
    end

    # Direct process_batch (bypasses the 50/batch cap). raw_events are JSON strings.
    def ingest_via_process_batch(raw_events, chunk: 500)
      raw_events.each_slice(chunk) do |slice|
        job = BatchEventProcessorJob.new
        job.jid = "matrix-#{SecureRandom.hex(4)}"
        job.send(:process_batch, slice)
        @drained_jids << job.jid
      end
      rebuild_breakdowns_after_ingest!
    end

    # The breakdown rollups (project_daily/link_daily/visitor_daily/country/version/
    # source/property/billing) read by the Pass-B matrix tests are rebuilt from
    # canonical, not MV-fed. Rebuild every partition the pipeline just populated so
    # they are fresh when the read services are exercised.
    BREAKDOWN_ROLLUPS = %i[
      project_breakdown link_breakdown visitor_breakdown country version source property billing
    ].freeze

    def rebuild_breakdowns_after_ingest!
      rows = Clickhouse.with do |conn|
        conn.select_all("SELECT DISTINCT toYYYYMM(toDate(created_at)) AS p FROM events")
      end
      rows.map { |r| r["p"].to_s }.each do |p|
        ClickhouseRollupRebuildService.rebuild_partition_range(p, p, rollups: BREAKDOWN_ROLLUPS)
      end
    end

    def http_event_payload(scn)
      bind = bind_scenario(scn)
      base = {
        session_id: scn.token,
        engagement_time: ScenarioInput::ENGAGEMENT_TIME,
        tags: ScenarioInput::TAGS
      }
      base[:path] = bind.link.path if bind.link # resolve_link_from_event reads ev[:path]
      if scn.custom_kind?
        base.merge(event_name: scn.sdk_event_name)
      else
        base.merge(event: scn.event)
      end
    end

    # Drain Redis through a real job (same pattern as sdk_events_full_stack test).
    def drain_event_queue!
      job = BatchEventProcessorJob.new
      job.jid = "matrix-#{SecureRandom.hex(4)}"
      raw = REDIS.with { |c| c.lrange(BatchEventProcessorJob::REDIS_KEY, 0, -1) }
      REDIS.with { |c| c.del(BatchEventProcessorJob::REDIS_KEY) }
      job.send(:process_batch, raw) unless raw.empty?
      @drained_jids << job.jid
      rebuild_breakdowns_after_ingest!
      job
    end

    # ---- cleanup -------------------------------------------------------------

    def matrix_setup!
      skip_unless_clickhouse!
      @drained_jids = []
      @orig_ch_write = Rails.application.config.clickhouse_write_enabled
      @orig_ch_read  = Rails.application.config.clickhouse_read_enabled
      Rails.application.config.clickhouse_write_enabled = true
      Rails.application.config.clickhouse_read_enabled = true # SessionBuildJob gates on it
      Rails.cache.clear # DashboardMetrics is Rails.cache-wrapped
      truncate_clickhouse_tables # also pins this class's isolated CH DB
      flush_matrix_redis!
    end

    def matrix_teardown!
      Rails.application.config.clickhouse_write_enabled = @orig_ch_write if defined?(@orig_ch_write)
      Rails.application.config.clickhouse_read_enabled = @orig_ch_read if defined?(@orig_ch_read)
      flush_matrix_redis!
    end

    # Drop pending queue + CH_BATCH_DONE/VIEW-dedup/dev-update keys (a stale
    # CH_BATCH_DONE fingerprint would skip a re-insert).
    def flush_matrix_redis!
      REDIS.with do |c|
        c.del(BatchEventProcessorJob::REDIS_KEY, BatchEventProcessorJob::INTEGRITY_DLQ_KEY)
        %W[#{BatchEventProcessorJob::CH_BATCH_DONE_PREFIX}:* events:dedup:* events:processing:* events:heartbeat:* dev_upd_full:*].each do |pat|
          keys = c.keys(pat)
          c.del(*keys) if keys.any?
        end
      end
    end

    # ---- Pass A: reconciliation (PG <-> CH) ----------------------------------

    def assert_reconciles(scn)
      bind = bind_scenario(scn)

      # (1) EXACTLY ONE row per store (not first-of-many) — catches a double-write.
      pg_rows = Event.where(session_id: scn.token)
      assert_equal 1, pg_rows.count,
                   "expected exactly 1 PG row for #{scn.event}/#{scn.platform} (token #{scn.token}), got #{pg_rows.count}"
      pg = pg_rows.first

      ch_rows = ch_rows_for(scn.token, bind.project_id)
      assert_equal 1, ch_rows.size,
                   "expected exactly 1 CH row for #{scn.event}/#{scn.platform} (token #{scn.token}), got #{ch_rows.size}"
      ch = ch_rows.first

      # (2)(3) independent oracle per store — catches both-wrong-together.
      assert_pg_matches(pg, scn.expected_pg(bind))
      assert_ch_matches(ch, scn.expected_ch(bind))
      # (4) direct PG↔CH equality — catches drift on un-oracled shared columns.
      assert_shared_fields_equal(pg, ch)
      # (5) CH-only fields vs a projection derived from the PG side.
      assert_ch_matches_projection(ch, pg_projection(pg))

      assert_user_referred(scn, bind) if scn.derived_referral?
    end

    def assert_pg_matches(pg_event, expected)
      expected.each do |k, v|
        actual = pg_event.public_send(k)
        v.nil? ? assert_nil(actual, "PG #{k}") : assert_equal(v, actual, "PG #{k}")
      end
    end

    def assert_ch_matches(ch_row, expected)
      expected.each { |k, v| assert_equal v, ch_row[k.to_s], "CH #{k}" }
    end

    NUMERIC_SHARED = %i[link_id engagement_time].freeze
    ARRAY_SHARED   = %i[tags].freeze

    def assert_shared_fields_equal(pg_event, ch_row)
      ScenarioInput::SHARED_FIELDS.each do |f|
        pg_val = pg_event.public_send(PG_COL.fetch(f, f))
        ch_val = ch_row[f.to_s]
        if NUMERIC_SHARED.include?(f)
          assert_equal pg_val.to_i, ch_val.to_i, "shared #{f} PG<->CH" # PG nil <-> CH 0
        elsif ARRAY_SHARED.include?(f)
          assert_equal Array(pg_val).map(&:to_s).sort, Array(ch_val).map(&:to_s).sort,
                       "shared #{f} PG<->CH"
        else
          assert_equal pg_val.to_s, ch_val.to_s, "shared #{f} PG<->CH" # PG nil == CH ""
        end
      end
    end

    # CH-only fields derived from the PG link — never from CH. inviter_id is
    # excluded (it's captured pre-referral-assignment; expected_ch asserts 0).
    def pg_projection(pg_event)
      {
        campaign_id:   pg_event.link&.campaign_id.to_i,
        sdk_generated: pg_event.link&.sdk_generated == true ? 1 : 0
      }
    end

    def assert_ch_matches_projection(ch_row, projection)
      projection.each { |k, v| assert_equal v, ch_row[k.to_s].to_i, "CH<-PGproj #{k}" }
    end

    # Derived user_referred row is credited to the REFERRER's device, link_id 0,
    # and the installer's inviter_id is set. (batch_event_processor_job.rb:435,439)
    def assert_user_referred(scn, bind)
      referrer = bind.link.visitor
      rows = ch_rows_for_event(bind.project_id, Grovs::Events::USER_REFERRED, referrer.device_id)
      assert_operator rows.size, :>=, 1, "expected user_referred row for referrer"
      assert_equal 0, rows.first["link_id"].to_i, "user_referred link_id should be 0"
      assert_equal referrer.id, bind.visitor.reload.inviter_id, "installer inviter_id"
    end

    # ---- CH query helpers (lean on ClickhouseTestHelper) ---------------------

    def ch_rows_for(token, project_id)
      ch_query("events", project_id, extra_where: "session_id = '#{token}'")
    end

    def ch_rows_for_event(project_id, event_type, device_id)
      ch_query("events", project_id,
               extra_where: "event_type = '#{event_type}' AND device_id = #{device_id.to_i}")
    end
  end
end
