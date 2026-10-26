# What a campaign's groups did after exposure: people, clicks, conversions, and how sure the difference is.
class Experiments::Report
  class NotApplicable < InAppReport::Invalid; end

  TIMEOUT = 15
  CACHE = 60.seconds
  MIN_PEOPLE = 100
  # One-sided 95% and 80% power, the usual pair for "how many more people".
  Z_ALPHA = 1.645
  Z_BETA = 0.84
  PROJECT_CONTROL = "project_control".freeze
  IN_APP = { exposed: "in_app_viewed", clicked: "in_app_clicked", held: "in_app_held" }.freeze
  PUSH = { exposed: "push_delivered", clicked: Grovs::Events::PUSH_OPEN, held: "push_held" }.freeze
  # A journey has nothing to click; the name never occurs, so the clicks stay at zero.
  JOURNEY = { exposed: "journey_entered", clicked: "journey_none", held: "journey_held" }.freeze
  # Only people who reached the split, grouped by the path recorded; nobody is held there.
  JOURNEY_PATH = { exposed: Journeys::Entry::PATH, clicked: "journey_none", held: "journey_none" }.freeze
  REVENUE_HOURS = 72
  # CH equivalent of RevenueLedgerQuery::REVENUE_DELTA_SQL (Postgres-only, != is fine: purchase_type is non-nullable LowCardinality here).
  REVENUE_DELTA_CH_SQL = <<~SQL.squish.freeze
    multiIf(
      p.event_type IN ('#{Grovs::Purchases::EVENT_BUY}', '#{Grovs::Purchases::EVENT_REFUND_REVERSED}'), p.usd_price_cents * p.quantity,
      p.event_type = '#{Grovs::Purchases::EVENT_REFUND}', -(p.usd_price_cents * p.quantity),
      p.event_type = '#{Grovs::Purchases::EVENT_CANCEL}' AND p.purchase_type != '#{Grovs::Purchases::TYPE_SUBSCRIPTION}', -(p.usd_price_cents * p.quantity),
      0
    )
  SQL

  def self.in_app(campaign, from:, to:)
    new(campaign, from, to, IN_APP, project_control: InAppSetting.for(campaign.project).control_group).call
  end

  def self.push(campaign, from:, to:)
    new(campaign, from, to, PUSH, project_control: InAppSetting.for(campaign.project).control_group).call
  end

  def self.journey(journey, from:, to:)
    new(journey, from, to, JOURNEY, project_control: InAppSetting.for(journey.project).control_group).call
  end

  def self.journey_path(journey, step_id, from:, to:)
    new(journey, from, to, JOURNEY_PATH, project_control: 0, step: journey.step(step_id)).call
  end

  def initialize(campaign, from, to, events, project_control:, step: nil)
    @campaign = campaign
    @step = step
    @from = Date.iso8601(from.to_s)
    @to = Date.iso8601(to.to_s)
    @events = events
    @project_control = project_control.to_i
    raise InAppReport::Invalid, "the range must be 1 to #{InAppReport::MAX_DAYS} days" unless (@to - @from).to_i.between?(0, InAppReport::MAX_DAYS - 1)
  rescue Date::Error
    raise InAppReport::Invalid, "from and to must be dates such as 2026-10-01"
  end

  def call
    raise NotApplicable, "This campaign runs no experiment" unless @step || @campaign.experiment? || @project_control.positive?

    Rails.cache.fetch(cache_key, expires_in: CACHE) { build }
  end

  private

  def goal = @campaign.conversion.is_a?(Hash) ? @campaign.conversion : nil
  # A journey converts on any of its goals, as any of them takes the person out; the first sets the window.
  def goals = @campaign.is_a?(Journey) ? @campaign.goals : [goal].compact
  def event_goals = goals.reject { |g| Experiments::Goal.purchase?(g) }
  def purchase_goals = goals.select { |g| Experiments::Goal.purchase?(g) }
  def control_group = @step ? 0 : @campaign.control_group
  def control = control_group.to_i
  def variants = @step ? %w[a b c].first(@step["paths"].size) : @campaign.variant_ids
  def window = goal ? goal["window_hours"].to_i : REVENUE_HOURS

  def cache_key
    ["experiments", @campaign.class.name, @campaign.id, @campaign.updated_at.to_f, @from, @to, @project_control, @step&.dig("id")].join(":")
  end

  def build
    rows = read(groups_sql).to_a.index_by { |row| row["grp"] }
    groups = (variants + [Experiments::Split::CONTROL, PROJECT_CONTROL]).map { |id| group(id, rows[id]) }
    groups.reject! { |g| g["id"] == Experiments::Split::CONTROL } if control.zero?
    groups.reject! { |g| g["id"] == PROJECT_CONTROL && g["exposed"].zero? } if @project_control.zero?
    a = groups.find { |g| g["id"] == "a" }
    groups.each { |g| g["confidence"] = variants.include?(g["id"]) && g["id"] != "a" ? confidence(g, a) : nil }
    { "goal" => goal, "control_group" => control_group, "project_control_group" => @project_control,
      "test_share" => @campaign.try(:test_share), "groups" => groups }.merge(against_control(groups)).merge(revenue_against_control(groups))
  end

  def group(id, row)
    row ||= {}
    exposed = row["exposed"].to_i
    revenue = row["revenue"].to_i
    clicked = [Experiments::Split::CONTROL, PROJECT_CONTROL].include?(id) ? nil : row["clicked"].to_i
    converted = goal ? row["converted"].to_i : nil
    { "id" => id, "exposed" => exposed, "clicked" => clicked, "click_rate" => rate(clicked, exposed),
      "converted" => converted, "conversion_rate" => rate(converted, exposed), "confidence" => nil,
      "revenue_cents" => revenue, "revenue_per_person_cents" => exposed.zero? ? nil : (revenue.to_f / exposed).round }
  end

  # Lift, added conversions and the people still needed, all variants together against the campaign's control.
  def against_control(groups)
    none = { "lift" => nil, "added_conversions" => nil, "confidence" => nil, "more_people_needed" => nil }
    ctrl = groups.find { |g| g["id"] == Experiments::Split::CONTROL }
    return none if ctrl.nil? || goal.nil?

    treated = groups.select { |g| variants.include?(g["id"]) }
    all = { "exposed" => treated.sum { |g| g["exposed"] }, "converted" => treated.sum { |g| g["converted"] } }
    all["conversion_rate"] = rate(all["converted"], all["exposed"])
    return none if all["exposed"].zero? || ctrl["exposed"].zero?

    sure = confidence(all, ctrl)
    { "lift" => ctrl["conversion_rate"].to_f.positive? ? (all["conversion_rate"] / ctrl["conversion_rate"] - 1).round(4) : nil,
      "added_conversions" => (all["converted"] - all["exposed"] * ctrl["converted"].to_f / ctrl["exposed"]).round,
      "confidence" => sure, "more_people_needed" => sure.nil? || sure < 0.95 ? more_people(all, ctrl) : nil }
  end

  # All variants against the campaign's control, from unrounded per-person revenue; no goal needed.
  def revenue_against_control(groups)
    ctrl = groups.find { |g| g["id"] == Experiments::Split::CONTROL }
    treated = groups.select { |g| variants.include?(g["id"]) }
    exposed = treated.sum { |g| g["exposed"] }
    return { "revenue_lift" => nil, "added_revenue_cents" => nil } if ctrl.nil? || ctrl["exposed"].zero? || exposed.zero?

    mine = treated.sum { |g| g["revenue_cents"] }.to_f / exposed
    theirs = ctrl["revenue_cents"].to_f / ctrl["exposed"]
    { "revenue_lift" => theirs.positive? ? (mine / theirs - 1).round(4) : nil, "added_revenue_cents" => (exposed * (mine - theirs)).round }
  end

  def rate(part, whole)
    return nil if part.nil? || whole.zero?

    (part.to_f / whole).round(4)
  end

  def measure = goal ? "conversion_rate" : "click_rate"
  def count = goal ? "converted" : "clicked"

  # One-sided two-proportion z-test: how sure we are that `one` does better than `other`.
  def confidence(one, other)
    n1 = one["exposed"]
    n2 = other["exposed"]
    return nil if n1 < MIN_PEOPLE || n2 < MIN_PEOPLE || one[count].nil? || other[count].nil?

    pooled = (one[count] + other[count]).to_f / (n1 + n2)
    return nil if pooled.zero? || pooled == 1

    z = (one[measure] - other[measure]) / Math.sqrt(pooled * (1 - pooled) * (1.0 / n1 + 1.0 / n2))
    (0.5 * (1 + Math.erf(z / Math.sqrt(2)))).round(4)
  end

  # People per group to see the observed difference at 95% with 80% power, less those already there.
  def more_people(one, other)
    p1 = one[measure]
    p2 = other[measure]
    return nil if p1.nil? || p2.nil? || p1 == p2

    needed = ((Z_ALPHA + Z_BETA)**2 * (p1 * (1 - p1) + p2 * (1 - p2)) / (p1 - p2)**2).ceil
    more = needed - [one["exposed"], other["exposed"]].min
    more.positive? ? more : nil
  end

  IN_WINDOW = "g.at > e.at AND g.at <= e.at + INTERVAL {window:UInt32} HOUR".freeze

  def groups_sql
    <<~SQL.squish
      SELECT grp, count() AS exposed, countIf(clicked) AS clicked, countIf(converted) AS converted, sum(revenue) AS revenue FROM (
        SELECT e.grp AS grp, e.visitor_id AS visitor_id, e.clicked AS clicked,
               max(g.is_goal = 1 AND #{IN_WINDOW}) AS converted, sumIf(g.cents, #{IN_WINDOW}) AS revenue
        FROM (#{exposures_sql}) AS e
        LEFT JOIN (#{signals_sql}) AS g ON g.visitor_id = e.visitor_id
        GROUP BY grp, visitor_id, clicked
      ) GROUP BY grp
    SQL
  end

  # Goal events and purchases in one list, so the report stays one join.
  def signals_sql
    events = event_goals.any? ? "#{goal_events_sql} UNION ALL " : ""
    "SELECT visitor_id, at, is_goal, cents FROM (#{events}#{purchases_sql})"
  end

  def goal_events_sql
    <<~SQL.squish
      SELECT visitor_id, created_at AS at, toUInt8(1) AS is_goal, toInt64(0) AS cents FROM events FINAL
      WHERE project_id = {project_id:UInt64} AND toDate(created_at, 'UTC') BETWEEN {from:Date} AND {goal_to:Date}
        AND (#{event_goals.each_with_index.map { |g, i| Experiments::Goal.sql(g, "goal_#{i}") }.join(' OR ')}) AND visitor_id IN (SELECT visitor_id FROM (#{exposures_sql}))
    SQL
  end

  # As Analytics::EventsSource: filters inside, LIMIT BY not FINAL, so partitions still prune.
  def purchases_sql
    <<~SQL.squish
      SELECT visitor_id, at, is_goal, cents FROM (
        SELECT p.visitor_id AS visitor_id, if(p.recorded_at = toDateTime64(0, 3, 'UTC'), p.created_at, p.recorded_at) AS at,
               toUInt8(#{purchase_goal_sql}) AS is_goal, toInt64(#{REVENUE_DELTA_CH_SQL}) AS cents
        FROM purchase_events AS p
        WHERE p.project_id = {project_id:UInt64} AND p.visitor_id > 0 AND p.created_at >= toDateTime64({from:Date}, 3, 'UTC')
        ORDER BY p.created_at DESC LIMIT 1 BY p.project_id, p.transaction_id, p.event_type
      ) WHERE toDate(at, 'UTC') BETWEEN {from:Date} AND {goal_to:Date}
    SQL
  end

  def purchase_goal_sql
    return "0" if purchase_goals.empty?

    buy = "p.event_type = '#{Grovs::Purchases::EVENT_BUY}'"
    products.present? ? "#{buy} AND p.product_id IN {products:Array(String)}" : buy
  end

  # Nil when any purchase goal takes every product.
  def products = purchase_goals.all? { |g| g["products"].present? } ? purchase_goals.flat_map { |g| g["products"] }.uniq : nil

  # One row a person; a push person's variant is the one exposed, since the winner may differ from their bucket.
  def exposures_sql
    campaign = "CAST(properties.`campaign_id` AS String) = {campaign:String}"
    exposed = @step ? "#{campaign} AND CAST(properties.`step_id` AS String) = {step:String}" : campaign
    held = "event_name = '#{@events[:held]}'"
    project_held = "#{held} AND CAST(properties.`scope` AS String) = 'project'"
    held_mine = @events == IN_APP ? "#{held} AND (#{campaign} OR CAST(properties.`scope` AS String) = 'project')" : "#{held} AND #{campaign}"
    variant = "anyIf(CAST(properties.`variant` AS String), event_name = '#{@events[:exposed]}')"
    bucketed = Experiments::Split.sql(Experiments::Bucket.sql("{campaign:String}"), control: control, variants: variants.size)
    path = "argMinIf(CAST(properties.`path` AS String), created_at, event_name = '#{@events[:exposed]}')"
    picked = if @step then "multiIf(#{variants.each_with_index.map { |v, i| "#{path} = 'path_#{i}', '#{v}'" }.join(', ')}, '')"
             elsif @events == PUSH then "if(#{variant} != '', #{variant}, #{bucketed})"
             else bucketed
             end
    <<~SQL.squish
      SELECT visitor_id,
             multiIf(countIf(#{project_held}) > 0, '#{PROJECT_CONTROL}', countIf(#{held}) > 0, '#{Experiments::Split::CONTROL}', #{picked}) AS grp,
             minIf(created_at, event_name != '#{@events[:clicked]}') AS at, max(event_name = '#{@events[:clicked]}') AS clicked
      FROM events FINAL
      WHERE project_id = {project_id:UInt64} AND toDate(created_at, 'UTC') BETWEEN {from:Date} AND {to:Date} AND event_type = 'custom'
        AND visitor_id > 0
        AND ((event_name IN ('#{@events[:exposed]}', '#{@events[:clicked]}') AND #{exposed}) OR (#{held_mine}))
      GROUP BY visitor_id HAVING countIf(event_name != '#{@events[:clicked]}') > 0
    SQL
  end

  def read(sql)
    placeholders = { project_id: @campaign.project_id, from: @from.iso8601, to: @to.iso8601, campaign: @campaign.hashid, window: window,
                     goal_to: (@to + (window / 24) + 1).iso8601 }
    event_goals.each_with_index { |g, i| placeholders[:"goal_#{i}"] = Experiments::Goal.name(g) }
    placeholders[:products] = products if products.present?
    placeholders[:step] = @step["id"] if @step
    query = ClickHouse::Client::Query.new(raw_query: "#{sql} SETTINGS max_execution_time = #{TIMEOUT}", placeholders: placeholders)
    Clickhouse.with_request_timeout(TIMEOUT + 2) { Clickhouse.with { |conn| conn.select_all(query) } }
  rescue ClickHouse::Client::DatabaseError, *Clickhouse::TRANSPORT_ERRORS => e
    raise Clickhouse::Unavailable, "experiment report" if Clickhouse.availability_error?(e)

    raise
  end
end
