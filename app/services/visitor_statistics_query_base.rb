class VisitorStatisticsQueryBase
  SORTABLE_METRIC_FIELDS = VisitorDailyStatistic::METRIC_COLUMNS.map(&:to_s).freeze
  BIGINT_CAST_COLUMNS = %i[time_spent revenue].freeze
  # Revenue never moves to CH (ledger/stat table), so it is the one sort CH can't serve.
  CH_SORTABLE_METRICS = (SORTABLE_METRIC_FIELDS - %w[revenue]).freeze
  TERM_ID_CAP = Clickhouse::MAX_IN_LIST_IDS

  attr_reader :params, :project

  def initialize(params: nil, project: nil)
    @params = params
    @project = project
  end

  def call
    paginated = build_query.order(order_clause).page(page).per(per_page)

    {
      visitors: VisitorSerializer.serialize(paginated, slim: true),
      meta: {
        page: page,
        total_pages: paginated.total_pages,
        per_page: paginated.limit_value,
        total_entries: paginated.total_count
      }
    }
  end

  private

  def visitors = Visitor.arel_table
  def stats    = VisitorDailyStatistic.arel_table
  def devices  = Device.arel_table

  def build_query
    query = apply_joins(Visitor)
    query = query.where(visitor_daily_statistics: { event_date: date_range })
    query = apply_project_scope(query)
    query = query.where(visitors: { id: visitor_id }) if visitor_id

    if term.present?
      pat = "%#{term}%"
      query = query.where(
        visitors[:sdk_identifier].matches(pat)
          .or(Arel.sql("visitors.uuid::text").matches(pat))
      )
    end

    if platform
      lower_platform = Arel::Nodes::NamedFunction.new("LOWER", [devices[:platform]])
      query = query.where(lower_platform.eq(platform.downcase))
    end

    query.group(*group_columns)
         .select(select_fields)
  end

  def order_clause
    if sortable_visitor_fields.include?(sort_by)
      direction == "asc" ? visitors[sort_by.to_sym].asc : visitors[sort_by.to_sym].desc
    elsif SORTABLE_METRIC_FIELDS.include?(sort_by)
      metric_order_expression
    else
      visitors[:created_at].desc
    end
  end

  # created_at maps to the id proxy. Measured on staging 2026-07-28: ids disagree with
  # created_at on 0.33% of adjacent pairs (near-simultaneous inserts), so order differs
  # locally from PG. Routing it through pg_ordered_fields instead would put the DEFAULT
  # sort behind the candidate id cap, which 8-9M-visitor projects never clear — a worse trade.
  def ch_orderable?
    return true if CH_SORTABLE_METRICS.include?(sort_by)
    return true if ch_identity_fields.include?(sort_by)
    return true if sort_by == "created_at" || pg_ordered_fields.include?(sort_by)

    !(sortable_visitor_fields + SORTABLE_METRIC_FIELDS).include?(sort_by)
  end

  # CH decides population + order, PG hydrates metadata/revenue; nil → PG fallback.
  def ch_call
    return nil unless project
    return ch_call_identity_ordered if ch_identity_fields.include?(sort_by)
    return ch_call_pg_ordered if pg_ordered_fields.include?(sort_by)

    ids = nil
    if visitor_id || term.present? || restrict_to_candidate_ids?
      ids = term_candidate_ids
      return nil if ids.nil?
    end

    metric_order = CH_SORTABLE_METRICS.include?(sort_by)
    order = metric_order ? sort_by : "visitor_id"
    dir = metric_order || sort_by == "created_at" ? direction : "desc"

    result = ch_metrics_page(order: order, direction: dir, limit: per_page,
                             offset: (page - 1) * per_page, ids: ids)
    return nil if result.nil?

    ch_page(result[:rows], result[:total])
  end

  # CH owns order + term + population: identity lives in user_profiles, so no candidate id cap applies.
  def ch_call_identity_ordered
    return nil unless ch_identity_coverage?

    ids = visitor_id ? [visitor_id.to_i] : nil
    result = ch_identity_page(order: sort_by, direction: direction, limit: per_page,
                              offset: (page - 1) * per_page, ids: ids)
    return nil if result.nil?

    ch_page(result[:rows], result[:total])
  end

  # PG owns the ORDER (its columns aren't in CH); CH still owns population + metrics.
  def ch_call_pg_ordered
    ordered_ids = sorted_candidate_ids
    return nil if ordered_ids.nil?
    return ch_page([], 0) if ordered_ids.empty?

    active = candidate_scope_from_ch? ? ordered_ids : ch_active_ids(ordered_ids)
    return nil if active.nil?

    active_set = active.to_set
    matching = ordered_ids.select { |id| active_set.include?(id) }
    page_ids = matching[(page - 1) * per_page, per_page] || []
    return ch_page([], matching.size) if page_ids.empty?

    # Offset 0: the page ids ARE the page; PG order is re-imposed below.
    result = ch_metrics_page(order: "visitor_id", direction: "asc",
                             limit: page_ids.size, offset: 0, ids: page_ids)
    return nil if result.nil?

    by_id = result[:rows].index_by { |r| r["visitor_id"].to_i }
    ch_page(page_ids.filter_map { |id| by_id[id] }, matching.size)
  end

  def ch_page(rows, total)
    {
      visitors: hydrate_page(rows),
      meta: {
        page: page,
        total_pages: (total / per_page.to_f).ceil,
        per_page: per_page,
        total_entries: total
      }
    }
  end

  def hydrate_page(rows)
    page_ids = rows.map { |r| r["visitor_id"].to_i }
    visitors_by_id = ch_hydration_scope.where(id: page_ids).index_by(&:id)
    revenue = ch_page_revenue(page_ids)

    rows.filter_map do |row|
      visitor = visitors_by_id[row["visitor_id"].to_i]
      next unless visitor # PG-deleted/merged but still in CH until next rebuild; totals briefly overcount

      h = VisitorSerializer.serialize(visitor, slim: true)
      decorate_ch_row(h, visitor)
      CH_SORTABLE_METRICS.each { |k| h["#{ch_metric_prefix}#{k}"] = row[k].to_i }
      h["#{ch_metric_prefix}revenue"] = revenue.fetch(visitor.id, 0).to_i
      h
    end
  end

  # Term matches resolve in PG and feed the CH IN clause; bail to PG beyond the cap.
  def term_candidate_ids
    scope = term_scope
    return nil if scope.nil?

    ids = scope.limit(term_id_cap + 1).pluck(:id)
    return Clickhouse.id_cap_exceeded!(:visitor_term_candidates, term_id_cap) if ids.size > term_id_cap

    ids
  end

  # Unordered probe first: the ORDER BY is unindexed, so an over-cap project would sort twice.
  def sorted_candidate_ids
    scope = term_scope
    return nil if scope.nil?
    return Clickhouse.id_cap_exceeded!(:visitor_sorted_candidates, term_id_cap) if scope.limit(term_id_cap + 1).count > term_id_cap

    column = visitors[sort_by.to_sym]
    scope.order(direction == "asc" ? column.asc : column.desc, visitors[:id].asc)
         .limit(term_id_cap).pluck(:id)
  end

  # nil when the grain's population could not be resolved → caller falls back to PG.
  def term_scope
    scope = candidate_scope
    return nil if scope.nil?

    scope = scope.where(id: visitor_id) if visitor_id
    return scope if term.blank?

    pat = "%#{term}%"
    scope.where(
      visitors[:sdk_identifier].matches(pat).or(Arel.sql("visitors.uuid::text").matches(pat))
    )
  end

  # Method (not constant ref) so tests can stub the cap.
  def term_id_cap = TERM_ID_CAP

  def decorate_ch_row(_row, _visitor) = nil

  # The population the candidate id cap is measured against; narrowed per grain.
  def candidate_scope = Visitor.where(project_id: project.id)

  # True when CH must page/count only ids that still exist in PG.
  def restrict_to_candidate_ids? = false

  # Identity sorts CH can serve; the referral grain keeps [] (no CH updated_at) and stays capped.
  def ch_identity_fields = [].freeze

  def ch_identity_coverage? = ClickhouseReadService.visitor_identity_coverage?(project.id)

  def ch_identity_page(order:, direction:, limit:, offset:, ids:)
    raise NotImplementedError
  end

  # True when candidate_scope already came from CH, so re-asking CH is a wasted query.
  def candidate_scope_from_ch? = false

  # --- Template methods for subclasses ---

  def pg_ordered_fields
    raise NotImplementedError
  end

  def ch_metric_prefix
    raise NotImplementedError
  end

  def ch_hydration_scope
    raise NotImplementedError
  end

  def ch_page_revenue(_page_ids)
    raise NotImplementedError
  end

  def ch_metrics_page(order:, direction:, limit:, offset:, ids:)
    raise NotImplementedError
  end

  def ch_active_ids(_ids)
    raise NotImplementedError
  end

  def apply_joins(_scope)
    raise NotImplementedError
  end

  def apply_project_scope(query)
    raise NotImplementedError
  end

  def group_columns
    raise NotImplementedError
  end

  def select_fields
    raise NotImplementedError
  end

  def metric_order_expression
    raise NotImplementedError
  end

  def sortable_visitor_fields
    raise NotImplementedError
  end

  # --- Params helpers ---

  def page        = [(params[:page] || 1).to_i, 1].max
  def per_page    = [(params[:per_page] || 20).to_i, 1].max
  def sort_by     = params[:sort_by].to_s
  def term        = params[:term]
  def start_date  = (params[:start_date] || 30.days.ago).to_date
  def end_date    = (params[:end_date] || Date.today).to_date
  def date_range  = start_date.beginning_of_day..end_date.end_of_day
  def visitor_id  = params[:visitor_id].presence
  def platform    = params[:platform].presence

  def direction
    ActiveModel::Type::Boolean.new.cast(params[:ascendent]) ? "asc" : "desc"
  end
end
