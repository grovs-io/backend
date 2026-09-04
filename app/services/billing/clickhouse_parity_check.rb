# frozen_string_literal: true

module Billing
  class ClickhouseParityCheck
    Result = Struct.new(
      :instance_id,
      :start_date,
      :end_date,
      :postgres_count,
      :clickhouse_count,
      :delta,
      :percent_delta,
      :status,
      keyword_init: true
    ) do
      # STRICT parity: exact count equality only. Never conflated with the accepted
      # redelivery delta below — a caller reading match? gets true parity, nothing softer.
      def match?
        status == "match"
      end

      # CH legitimately below PG because the content-hash event_id collapses client
      # retransmits PG counted individually. NOT a match — a deliberately accepted,
      # separately-reported product delta. The gate treats it as non-blocking (passing?)
      # but surfaces it loudly; it must never read as ordinary parity.
      def accepted_redelivery_delta?
        status == "accepted_redelivery_delta"
      end

      # The check did not run — NOT a divergence.
      def unavailable?
        status == "clickhouse_unavailable"
      end

      # Non-blocking for the gate: exact parity OR an accepted redelivery delta.
      def passing?
        match? || accepted_redelivery_delta?
      end
    end

    # CH reads below legacy PG here: the content-hash event_id collapses redeliveries PG
    # counted individually. Evidence per metric in docs/plans/2026-08-07-redelivery-evidence.md.
    REDELIVERY_TOLERANT_METRICS = %i[app_opens time_spent reactivations].freeze
    REDELIVERY_MAX_SHORTFALL = 0.15

    def self.compare(instance:, start_date:, end_date:, postgres_count:, clickhouse_count:)
      pg = postgres_count.to_i

      if clickhouse_count.nil?
        return Result.new(
          instance_id: instance.id,
          start_date: start_date.to_date,
          end_date: end_date.to_date,
          postgres_count: pg,
          clickhouse_count: nil,
          delta: nil,
          percent_delta: nil,
          status: "clickhouse_unavailable"
        )
      end

      ch = clickhouse_count.to_i
      delta = ch - pg

      Result.new(
        instance_id: instance.id,
        start_date: start_date.to_date,
        end_date: end_date.to_date,
        postgres_count: pg,
        clickhouse_count: ch,
        delta: delta,
        percent_delta: percent_delta(pg, ch, delta),
        status: status(pg, delta)
      )
    end

    # A parity report makes COVERAGE explicit: `covered` is { metric => Result } for
    # every metric checked on BOTH sides; `uncovered` is { pg_column => reason } for
    # PG columns the rollup deliberately does NOT replace yet. Reading
    # `report.all_match?` as "the rollup is a complete replacement" is impossible —
    # `uncovered` is always present and lists exactly what is NOT covered. Hash-like
    # accessors (`[]`, `each`, `values`, `keys`) proxy `covered` for back-compat.
    ParityReport = Struct.new(:rollup, :covered, :uncovered, :oracle_unavailable, keyword_init: true) do
      include Enumerable

      delegate :[], :values, :keys, to: :covered

      def each(&) = covered.each(&)
      # STRICT: every covered metric is an exact count match.
      def all_match? = covered.values.all?(&:match?)
      # Gate-level pass: exact matches AND/OR accepted redelivery deltas (no hard mismatch).
      def all_passing? = covered.values.all?(&:passing?)
      # The accepted, separately-reported deltas in this report (app_opens redelivery dedup).
      def accepted_deltas = covered.select { |_m, r| r.accepted_redelivery_delta? }
      # Sentinel for the both-sides-empty case, where `covered` is {} and leaves no trace.
      def unavailable? = oracle_unavailable == true || covered.values.any?(&:unavailable?)
    end

    # Evidence for all three: docs/plans/2026-08-07-dpm-staleness.md
    DPM_STALE = "daily_project_metrics misses late-arriving in-app events (3-day refresh window)"
    PROJECT_GRAIN_VISITORLESS = "project rollup counts visitorless events that VDS drops"
    REDELIVERY_UNBOUNDED_SUM = "PG sums every redelivery of the same event; inflation is unbounded"

    # Trusted cutover oracle: both sides recomputed exactly, never sampled.
    ROLLUP_PARITY = {
      project: {
        ch_table: "project_metrics_daily", pg_table: "daily_project_metrics",
        # Everything DPM-sourced is uncovered below, not compared.
        metrics: %i[],
        first_seen_metrics: %i[],
        # In other CH tables than ch_table, so ch_metric_sums can't reach them.
        derived_metrics: %i[organic_users link_views],
        # Range-DISTINCT, so it cannot be compared per day: summing daily distincts is the
        # very double-count this metric was corrected away from.
        range_metrics: %i[referred_users],
        uncovered: {
          views: PROJECT_GRAIN_VISITORLESS,
          opens: PROJECT_GRAIN_VISITORLESS,
          installs: DPM_STALE,
          reinstalls: DPM_STALE,
          app_opens: DPM_STALE,
          new_users: DPM_STALE,
          first_time_visitors: DPM_STALE,
          returning_users: "derived/attribution — Phase 5",
          revenue: "purchase pipeline, not events (purchase_* rollups)",
          units_sold: "purchase pipeline, not events",
          cancellations: "purchase pipeline, not events",
          first_time_purchases: "purchase pipeline, not events"
        }
      },
      link: {
        ch_table: "link_metrics_daily", pg_table: "link_daily_statistics",
        # time_spent uncovered here only; the visitor grain stays covered.
        metrics: %i[views opens installs reinstalls reactivations app_opens user_referred],
        uncovered: {
          time_spent: REDELIVERY_UNBOUNDED_SUM,
          revenue: "purchase pipeline, not events (purchase_* rollups)"
        }
      },
      visitor: {
        ch_table: "visitor_metrics_daily", pg_table: "visitor_daily_statistics",
        metrics: %i[views opens installs reinstalls time_spent reactivations app_opens user_referred],
        uncovered: { revenue: "purchase pipeline, not events (purchase_* rollups)" }
      },
      # Serves both EventMetricsQuery link surfaces, so it needs its own check: the counter
      # rollup being green says nothing about this table.
      link_events: {
        ch_table: "link_daily", pg_table: "link_daily_statistics",
        metrics: %i[views opens installs reinstalls reactivations app_opens user_referred],
        ch_sums: :link_daily_event_sums,
        uncovered: {
          revenue: "purchase pipeline, not events (purchase_* rollups)",
          time_spent: "PG sums engagement seconds here; link_daily counts events (both correct)",
          custom: "no PG counter column exists (Grovs::Events::MAPPING omits it)",
          screen_view: "no PG counter column exists (Grovs::Events::MAPPING omits it)"
        }
      }
    }.freeze

    # PG column => the event_type whose count it mirrors.
    LINK_EVENT_COLUMNS = {
      views: "view", opens: "open", installs: "install", reinstalls: "reinstall",
      reactivations: "reactivation", app_opens: "app_open", user_referred: "user_referred"
    }.freeze

    # Phase 5 — per-model attribution parity. Compares the CH attribution breakdown
    # (read via ClickhouseAttributionReadService over the rollups) against a TRUSTED
    # recompute straight from the deduped events (identity-map applied,
    # FINAL dedup), per source bucket. Zero delta on every covered bucket ⇒ the rollups
    # faithfully represent canonical and the model is safe to cut over.
    #
    # `covered` is { source_bucket => Result } for every bucket appearing on EITHER side.
    # `uncovered` lists the time-varying dimensions (version/country/platform) — they have
    # their OWN per-day definition and are NOT part of the source-attribution model, so a
    # green source parity must not be read as covering them.
    ATTRIBUTION_UNCOVERED = {
      version: "time-varying per-day dimension, not the source model — checked separately",
      country: "time-varying per-day dimension, not the source model — checked separately",
      platform: "time-varying per-day dimension, not the source model — checked separately"
    }.freeze

    def self.attribution_parity(project_id:, start_date:, end_date:, model:)
      # A failed SERVING read must not read as zeros against a working oracle.
      checked = begin
        breakdown_to_hash(
          ClickhouseAttributionReadService.source_breakdown(
            project_id, start_date: start_date, end_date: end_date, model: model, raise_on_error: true
          )
        )
      rescue StandardError => e
        Rails.logger.error("ClickhouseParityCheck#attribution_parity(checked): #{e.class}: #{e.message}")
        nil
      end
      trusted = attribution_trusted_recompute(project_id, start_date, end_date, model)

      buckets = ((checked&.keys || []) | (trusted&.keys || [])).sort
      covered = buckets.index_with do |source|
        compare_counts(project_id, start_date, end_date, trusted&.fetch(source, 0).to_i,
                       trusted && checked&.fetch(source, 0))
      end
      ParityReport.new(rollup: :"attribution_#{model}", covered: covered,
                       uncovered: ATTRIBUTION_UNCOVERED,
                       oracle_unavailable: trusted.nil? || checked.nil?)
    end

    def self.breakdown_to_hash(rows)
      rows.to_h { |r| [r["source"].to_s, r["visitors"].to_i] }
    end
    private_class_method :breakdown_to_hash

    # Trusted recompute: distinct active visitors in range (from canonical) resolved to one
    # source per the model, straight from canonical — no acquisition/snapshot intermediary.
    # Returns { source => uniqExact } or nil if CH reads are unavailable.
    def self.attribution_trusted_recompute(project_id, start_date, end_date, model)
      return nil unless Clickhouse.read_enabled?

      sql = ClickhouseAttributionReadService.trusted_recompute_sql(model)
      query = ClickHouse::Client::Query.new(
        raw_query: sql,
        placeholders: {
          project_id: Integer(project_id),
          start_date: start_date.to_date.strftime("%Y-%m-%d"),
          end_date: end_date.to_date.strftime("%Y-%m-%d")
        }
      )
      rows = Clickhouse.with { |conn| conn.select_all(query) }
      rows.to_h { |r| [r["source"].to_s, r["visitors"].to_i] }
    rescue StandardError => e
      Rails.logger.error("ClickhouseParityCheck#attribution_trusted_recompute: #{e.class}: #{e.message}")
      nil
    end
    private_class_method :attribution_trusted_recompute

    # Phase 6 GO/NO-GO gate. Runs every rollup parity (project/link/visitor) AND every
    # attribution model (install/first/last) for one project over a date range, and
    # returns a single PASS/FAIL verdict plus the per-report breakdown and the union of
    # all explicitly-uncovered dimensions. A human runs this BEFORE ever flipping a read
    # flag — pass:false means at least one covered metric/bucket diverged from the
    # trusted oracle, so the cutover is unsafe.
    # `inconclusive` is true when there is NO data to compare on either side — every
    # covered metric/bucket reads zero on BOTH Postgres and ClickHouse across the range.
    # An all-zero comparison "matches" trivially, so pass would be a SPURIOUS green; the
    # gate marks it inconclusive instead so an operator can't cut over on an empty range.
    # Set difference, not count difference: disjoint equal-sized sets must not read as complete.
    AcquisitionCoverage = Struct.new(:acquisition_visitors, :event_visitors, :missing, keyword_init: true) do
      def complete? = missing.zero?
      def percent_missing
        return 0.0 if event_visitors.to_i.zero?

        (missing.to_f / event_visitors) * 100
      end
    end

    COVERAGE_MAX_MEMORY_BYTES =
      Integer(ENV.fetch("CLICKHOUSE_COVERAGE_MAX_MEMORY_BYTES", 8_000_000_000))
    COVERAGE_MAX_EXECUTION_SECONDS =
      Integer(ENV.fetch("CLICKHOUSE_COVERAGE_MAX_EXECUTION_SECONDS", 120))

    # Scoped to the gate's range: acquisition trails ingestion, so an all-history check FAILs
    # any live project — and the range is what the attribution read joins against anyway.
    # link_session_daily has NO Postgres equivalent, so it cannot be parity-checked. This is
    # the next best thing: links with activity in range vs links with session rows. An empty
    # session rollup would otherwise serve avg_engagement_time 0.0 through a green gate.
    # nil on a failed read; :not_applicable when the range genuinely has no link activity.
    def self.session_coverage(project_id, start_date:, end_date:)
      return nil unless Clickhouse.read_enabled?

      query = ClickHouse::Client::Query.new(
        raw_query: <<~SQL,
          SELECT
            (SELECT uniqExact(link_id) FROM link_daily
             WHERE project_id = {project_id:UInt64}
               AND event_date >= {start_date:Date} AND event_date <= {end_date:Date}) AS active_links,
            (SELECT uniqExact(link_id) FROM link_session_daily
             WHERE project_id = {project_id:UInt64}
               AND event_date >= {start_date:Date} AND event_date <= {end_date:Date}) AS session_links
        SQL
        placeholders: {
          project_id: Integer(project_id),
          start_date: start_date.to_date.strftime("%Y-%m-%d"),
          end_date: end_date.to_date.strftime("%Y-%m-%d")
        }
      )
      row = Clickhouse.with { |conn| conn.select_all(query).first }
      return :not_applicable if row.nil? || row["active_links"].to_i.zero?

      { active_links: row["active_links"].to_i, session_links: row["session_links"].to_i }
    rescue StandardError => e
      Rails.logger.error("ClickhouseParityCheck#session_coverage: #{e.class}: #{e.message}")
      nil
    end

    def self.acquisition_coverage(project_id, start_date:, end_date:)
      return nil unless Clickhouse.read_enabled?

      rb = ClickhouseRollupRebuildService
      eff = rb.effective_visitor_id_expr
      # Mirrors the SERVED join: active side post-map, acquisition RAW. Mapping acquisition too
      # would let a stale pre-merge row cover a survivor whose row is missing.
      query = ClickHouse::Client::Query.new(
        raw_query: <<~SQL,
          WITH acq_visitors AS (
            SELECT DISTINCT visitor_id FROM visitor_acquisition
            WHERE project_id = {project_id:UInt64}
          )
          SELECT
            uniqExact(#{eff}) AS event_visitors,
            uniqExactIf(#{eff}, #{eff} NOT IN (SELECT visitor_id FROM acq_visitors)) AS missing,
            (SELECT count() FROM acq_visitors) AS acquisition_visitors
          #{rb::FROM_WITH_IDENTITY_MAP}
          WHERE events.project_id = {project_id:UInt64}
            AND toDate(events.created_at) >= {start_date:Date}
            AND toDate(events.created_at) <= {end_date:Date}
            AND #{eff} > 0
          SETTINGS max_memory_usage = #{COVERAGE_MAX_MEMORY_BYTES},
                   max_bytes_before_external_group_by = #{COVERAGE_MAX_MEMORY_BYTES / 4},
                   max_execution_time = #{COVERAGE_MAX_EXECUTION_SECONDS}
        SQL
        placeholders: {
          project_id: Integer(project_id),
          start_date: start_date.to_date.strftime("%Y-%m-%d"),
          end_date: end_date.to_date.strftime("%Y-%m-%d")
        }
      )
      row = Clickhouse.with { |conn| conn.select_all(query) }.first
      return nil if row.nil?

      AcquisitionCoverage.new(acquisition_visitors: row["acquisition_visitors"].to_i,
                              event_visitors: row["event_visitors"].to_i,
                              missing: row["missing"].to_i)
    rescue StandardError => e
      Rails.logger.error("ClickhouseParityCheck#acquisition_coverage: #{e.class}: #{e.message}")
      nil
    end

    GateResult = Struct.new(:project_id, :start_date, :end_date, :pass, :inconclusive,
                            :reports, :uncovered, :coverage, :session_coverage, keyword_init: true) do
      # Hard mismatches only — accepted deltas pass, and an unavailable oracle never ran.
      def mismatches
        reports.flat_map do |name, report|
          report.covered
                .reject { |_k, r| r.passing? || r.unavailable? }
                .map { |metric, r| [name, metric, r] }
        end
      end

      # Accepted, non-blocking redelivery deltas across all reports — surfaced LOUDLY by the
      # gate output so a green run is never mistaken for exact parity on these metrics.
      def accepted_deltas
        reports.flat_map do |name, report|
          report.accepted_deltas.map { |metric, r| [name, metric, r] }
        end
      end

      # Checks that never ran — kept out of mismatches so a broken oracle reads as INCONCLUSIVE.
      def unavailable
        reports.flat_map do |name, report|
          entries = report.covered.select { |_k, r| r.unavailable? }.map { |metric, r| [name, metric, r] }
          entries << [name, :oracle, nil] if report.unavailable? && entries.empty?
          entries
        end
      end

      def status
        return "inconclusive" if inconclusive
        pass ? "pass" : "fail"
      end
    end

    def self.gate(project_id:, start_date:, end_date:, rollups: ROLLUP_PARITY.keys,
                  attribution_models: ClickhouseAttributionReadService::MODELS)
      reports = {}
      uncovered = {}

      Array(rollups).each do |rollup|
        report = rollup_parity(rollup: rollup, project_id: project_id,
                               start_date: start_date, end_date: end_date)
        reports[:"rollup_#{rollup}"] = report
        report.uncovered.each { |col, reason| uncovered[:"#{rollup}.#{col}"] = reason }
      end

      Array(attribution_models).each do |model|
        report = attribution_parity(project_id: project_id, start_date: start_date,
                                    end_date: end_date, model: model)
        reports[:"attribution_#{model}"] = report
        report.uncovered.each { |dim, reason| uncovered[:"attribution.#{dim}"] = reason }
      end

      # Pass = no HARD mismatch (exact matches and accepted redelivery deltas both allowed).
      # Accepted deltas are non-blocking but reported separately via GateResult#accepted_deltas.
      all_passing = reports.values.all?(&:all_passing?)
      no_data = reports.values.all? { |report| all_zero?(report) }

      # Incomplete acquisition history is a hard FAIL; an unreadable one is INCONCLUSIVE.
      coverage = acquisition_coverage(project_id, start_date: start_date, end_date: end_date)

      unverifiable = coverage.nil? || reports.values.any?(&:unavailable?)
      coverage_complete = coverage&.complete? || false

      # Anything PROVEN wrong outranks anything merely unknown.
      hard_mismatch = reports.values.any? do |report|
        report.covered.values.any? { |r| !r.passing? && !r.unavailable? }
      end
      proven_failure = hard_mismatch || (!coverage.nil? && !coverage_complete)

      # Sessions can't be parity-checked; zero session links against real link activity is
      # a stale/unbuilt rollup, which would serve avg_engagement_time 0.0 behind a green gate.
      sessions = session_coverage(project_id, start_date: start_date, end_date: end_date)
      sessions_empty = sessions.is_a?(Hash) && sessions[:session_links].zero?

      GateResult.new(
        project_id: project_id, start_date: start_date.to_date, end_date: end_date.to_date,
        pass: all_passing && coverage_complete && !no_data && !unverifiable && !sessions_empty,
        inconclusive: !proven_failure && (unverifiable || no_data || sessions.nil?),
        reports: reports, uncovered: uncovered, coverage: coverage, session_coverage: sessions
      )
    end

    # Every covered Result reads zero on BOTH sides — nothing to compare.
    def self.all_zero?(report)
      report.covered.values.all? { |r| r.postgres_count.to_i.zero? && r.clickhouse_count.to_i.zero? }
    end
    private_class_method :all_zero?

    def self.rollup_parity(rollup:, project_id:, start_date:, end_date:)
      config = ROLLUP_PARITY.fetch(rollup)
      pg = pg_metric_sums(config[:pg_table], config[:metrics], project_id, start_date, end_date)
      ch = if config[:ch_sums]
             send(config[:ch_sums], config[:metrics], project_id, start_date, end_date)
           else
             ch_metric_sums(config[:ch_table], config[:metrics], project_id, start_date, end_date)
           end
      # PG DPM.installs is folded (installs+reinstalls); CH is pure — fold for comparison
      ch[:installs] = ch[:installs].to_i + ch[:reinstalls].to_i if rollup == :project && ch

      covered = config[:metrics].index_with do |metric|
        compare_counts(project_id, start_date, end_date, pg[metric].to_i, ch && ch[metric]&.to_i,
                       tolerant: REDELIVERY_TOLERANT_METRICS.include?(metric))
      end

      if (fs_metrics = config[:first_seen_metrics])
        fs_pg = pg_metric_sums(config[:pg_table], fs_metrics, project_id, start_date, end_date)
        fs_ch = first_seen_metric_sums(project_id, start_date, end_date)
        fs_metrics.each do |metric|
          covered[metric] = compare_counts(project_id, start_date, end_date,
                                           fs_pg[metric].to_i, fs_ch && fs_ch[metric])
        end
      end

      config[:derived_metrics]&.each do |metric|
        covered[metric] = derived_daily_parity(metric, project_id, start_date, end_date)
      end

      config[:range_metrics]&.each do |metric|
        covered[metric] = referred_users_parity(project_id, start_date, end_date)
      end

      ParityReport.new(rollup: rollup, covered: covered, uncovered: config.fetch(:uncovered))
    end

    # One grouped query per metric; organic has no day-grouped reader, so it stays per-day.
    DERIVED_DAILY_READERS = {
      link_views: ->(pid, sd, ed) { ClickhouseReadService.link_views_by_day(pid, start_date: sd, end_date: ed) },
      organic_users: lambda { |pid, sd, ed|
        (sd.to_date..ed.to_date).each_with_object({}) do |day, out|
          value = ClickhouseReadService.organic_users_total(pid, start_date: day, end_date: day)
          return nil if value.nil?

          out[day] = value
        end
      }
    }.freeze

    # Both sides count DISTINCT referred people over the range. Not daily_project_metrics:
    # that stores a per-day row count, which double-counts multi-day visitors AND is stale
    # (invited_by_id lands days later; only 3 days get recomputed).
    def self.referred_users_parity(project_id, start_date, end_date)
      pg = VisitorDailyStatistic.where(project_id: project_id, event_date: start_date..end_date)
                                .where.not(invited_by_id: nil)
                                .distinct.count(:visitor_id)
      ch = ClickhouseReadService.referred_users_total(
        project_id, start_date: start_date, end_date: end_date
      )
      compare_counts(project_id, start_date, end_date, pg, ch)
    end
    private_class_method :referred_users_parity

    # Per-day compare (range totals can cancel); reports first mismatching day, else totals.
    def self.derived_daily_parity(metric, project_id, start_date, end_date)
      reader = DERIVED_DAILY_READERS.fetch(metric)
      pg_by_day = pg_daily_for(metric, project_id, start_date, end_date)

      ch_by_day = reader.call(project_id, start_date, end_date)
      return compare_counts(project_id, start_date, end_date, pg_by_day.values.sum, nil) if ch_by_day.nil?

      total_pg = 0
      total_ch = 0
      (start_date.to_date..end_date.to_date).each do |day|
        pg = pg_by_day[day].to_i
        ch = ch_by_day[day].to_i
        return compare_counts(project_id, day, day, pg, ch) if pg != ch

        total_pg += pg
        total_ch += ch
      end
      compare_counts(project_id, start_date, end_date, total_pg, total_ch)
    end
    private_class_method :derived_daily_parity

    def self.pg_daily_for(metric, project_id, start_date, end_date)
      ActiveRecord::Base.connection.select_all(
        ActiveRecord::Base.sanitize_sql_array([
          "SELECT event_date, COALESCE(SUM(#{metric}), 0) AS value FROM daily_project_metrics " \
          "WHERE project_id = ? AND event_date BETWEEN ? AND ? GROUP BY event_date",
          project_id, start_date.to_date, end_date.to_date
        ])
      ).to_h { |r| [r["event_date"].to_date, r["value"].to_i] }
    end
    private_class_method :pg_daily_for

    # nil (clickhouse_unavailable) on a failed read.
    def self.first_seen_metric_sums(project_id, start_date, end_date)
      rows = ClickhouseReadService.first_seen_daily(
        project_id, start_date: start_date, end_date: end_date
      )
      return nil if rows.nil?

      {
        new_users: rows.sum { |r| r["new_users"].to_i },
        first_time_visitors: rows.sum { |r| r["first_time_visitors"].to_i }
      }
    end
    private_class_method :first_seen_metric_sums

    # link_daily is per event_type, so the PG counter columns are sumIf pivots.
    def self.link_daily_event_sums(metrics, project_id, start_date, end_date)
      return nil unless Clickhouse.read_enabled?

      sums = metrics.map do |m|
        "sumIf(cnt, event_type = '#{LINK_EVENT_COLUMNS.fetch(m)}') AS #{m}"
      end.join(", ")
      query = ClickHouse::Client::Query.new(
        raw_query: "SELECT #{sums} FROM link_daily " \
          "WHERE project_id = {project_id:UInt64} " \
          "AND event_date >= {start_date:Date} AND event_date <= {end_date:Date}",
        placeholders: {
          project_id: Integer(project_id),
          start_date: start_date.to_date.strftime("%Y-%m-%d"),
          end_date: end_date.to_date.strftime("%Y-%m-%d")
        }
      )
      row = Clickhouse.with { |conn| conn.select_all(query).first }
      metrics.index_with { |m| row ? row[m.to_s].to_i : 0 }
    rescue StandardError => e
      Rails.logger.error("ClickhouseParityCheck#link_daily_event_sums: #{e.class}: #{e.message}")
      nil
    end
    private_class_method :link_daily_event_sums

    def self.pg_metric_sums(table, metrics, project_id, start_date, end_date)
      sums = metrics.map { |m| "COALESCE(SUM(#{m}), 0) AS #{m}" }.join(", ")
      row = ActiveRecord::Base.connection.select_one(
        ActiveRecord::Base.sanitize_sql_array([
          "SELECT #{sums} FROM #{table} WHERE project_id = ? AND event_date BETWEEN ? AND ?",
          project_id, start_date.to_date, end_date.to_date
        ])
      )
      metrics.index_with { |m| row ? row[m.to_s].to_i : 0 }
    end
    private_class_method :pg_metric_sums

    def self.ch_metric_sums(table, metrics, project_id, start_date, end_date)
      return nil unless Clickhouse.read_enabled?

      sums = metrics.map { |m| "sum(#{m}) AS #{m}" }.join(", ")
      query = ClickHouse::Client::Query.new(
        raw_query: "SELECT #{sums} FROM `#{table}` " \
          "WHERE project_id = {project_id:UInt64} " \
          "AND event_date >= {start_date:Date} AND event_date <= {end_date:Date}",
        placeholders: {
          project_id: Integer(project_id),
          start_date: start_date.to_date.strftime("%Y-%m-%d"),
          end_date: end_date.to_date.strftime("%Y-%m-%d")
        }
      )
      row = Clickhouse.with { |conn| conn.select_all(query).first }
      metrics.index_with { |m| row ? row[m.to_s].to_i : 0 }
    rescue StandardError => e
      Rails.logger.error("ClickhouseParityCheck#ch_metric_sums(#{table}): #{e.class}: #{e.message}")
      nil
    end
    private_class_method :ch_metric_sums

    # Shared Result builder for both instance-level and per-metric parity.
    def self.compare_counts(scope_id, start_date, end_date, postgres_count, clickhouse_count, tolerant: false)
      pg = postgres_count.to_i

      if clickhouse_count.nil?
        return Result.new(instance_id: scope_id, start_date: start_date.to_date, end_date: end_date.to_date,
                          postgres_count: pg, clickhouse_count: nil, delta: nil, percent_delta: nil,
                          status: "clickhouse_unavailable")
      end

      ch = clickhouse_count.to_i
      delta = ch - pg
      Result.new(instance_id: scope_id, start_date: start_date.to_date, end_date: end_date.to_date,
                 postgres_count: pg, clickhouse_count: ch, delta: delta,
                 percent_delta: percent_delta(pg, ch, delta), status: status(pg, delta, tolerant: tolerant))
    end
    private_class_method :compare_counts

    def self.percent_delta(postgres_count, clickhouse_count, delta)
      return 0.0 if postgres_count.zero? && clickhouse_count.zero?
      return nil if postgres_count.zero?

      delta.to_f / postgres_count * 100.0
    end
    private_class_method :percent_delta

    def self.status(postgres_count, delta, tolerant: false)
      return "match" if delta.zero?
      return "clickhouse_only" if postgres_count.zero? && delta.positive?

      # Redelivery-prone metric reading below PG within the accepted band: an accepted,
      # separately-reported delta (NOT a match). CH above PG (delta positive) or below
      # beyond the band falls through to a hard mismatch.
      if tolerant && delta.negative? && postgres_count.positive? &&
         (-delta.to_f / postgres_count) <= REDELIVERY_MAX_SHORTFALL
        return "accepted_redelivery_delta"
      end

      "mismatch"
    end
    private_class_method :status
  end
end
