# What happened to one campaign, read from the events its devices sent.
class InAppReport
  CACHE = 60.seconds
  TIMEOUT = 15
  MAX_DAYS = 92
  NAMES = { "in_app_viewed" => "views", "in_app_clicked" => "clicks", "in_app_dismissed" => "dismissals" }.freeze
  EMPTY = { "views" => 0, "clicks" => 0, "dismissals" => 0 }.freeze

  class Invalid < StandardError; end

  EXPORT_ROWS = 10_000

  def self.call(campaign, from:, to:, by: "day")
    new(campaign, from, to, by).call
  end

  PAGE = 25
  CURSOR = /\A(\d{13})_([A-Za-z0-9_-]{1,80})\z/

  # One page of comments, newest first. `before` is the cursor the page before it gave; `values` narrows to those answers.
  def self.comments(campaign, from:, to:, values: nil, before: nil)
    new(campaign, from, to, "day").comment_page(Array(values).map(&:to_s).first(10), before)
  end

  # Every answer of the period with its comment, one row a person, newest first; for a file, so it is not cached.
  def self.answers(campaign, from:, to:)
    new(campaign, from, to, "day").answer_rows
  end

  def initialize(campaign, from, to, by)
    @campaign = campaign
    @from = Date.iso8601(from.to_s)
    @to = Date.iso8601(to.to_s)
    @by = by.to_s
    raise Invalid, "by must be day or hour" unless %w[day hour].include?(@by)
    raise Invalid, "the range must be 1 to #{MAX_DAYS} days" unless (@to - @from).to_i.between?(0, MAX_DAYS - 1)
  rescue Date::Error
    raise Invalid, "from and to must be dates such as 2026-10-01"
  end

  def comment_page(values, before)
    raise Invalid, "This campaign asks no question" unless @campaign.content["question"].is_a?(Hash)
    raise Invalid, "before is not a cursor this endpoint gave" if before.present? && !before.to_s.match?(CURSOR)

    rows = read(page_sql(values, before), page_placeholders(values, before)).to_a
    more = rows.size > PAGE
    shown = rows.first(PAGE)
    { "comments" => shown.map { |row| row.slice("value", "comment", "at", "platform") },
      "next_before" => more ? "#{shown.last['ms']}_#{shown.last['event_id']}" : nil }
  end

  def answer_rows
    question = @campaign.content["question"]
    raise Invalid, "This campaign asks no question" unless question.is_a?(Hash)

    labels = question["options"].to_h { |option| [option["id"], option["text"]] }
    found = read(export_sql).to_a
    rows = found.first(EXPORT_ROWS).map do |row|
      row.slice("at", "platform", "country", "app_version", "comment").merge(
        "answer" => row["value"], "label" => labels.fetch(row["value"], row["value"]), "user" => row["user"].presence
      )
    end
    { "type" => question["type"], "truncated" => found.size > EXPORT_ROWS, "rows" => rows }
  end

  def call
    Rails.cache.fetch("in_app:report:#{@campaign.id}:#{@from}:#{@to}:#{@by}", expires_in: CACHE) { build }
  end

  private

  def build
    rows = read(counts_sql).to_a
    people = read(people_sql).first || {}
    totals = sum(rows)
    { "totals" => totals.merge("unique_viewers" => people["viewers"].to_i, "unique_clickers" => people["clickers"].to_i,
                               "click_rate" => totals["views"].zero? ? 0.0 : (totals["clicks"].to_f / totals["views"]).round(4)),
      "trend" => grouped(rows, "bucket"), "platforms" => grouped(rows, "platform"),
      "buttons" => rows.select { |r| r["event_name"] == "in_app_clicked" }.group_by { |r| r["button"].to_s }
                       .map { |button, list| { "button_id" => button.presence, "clicks" => list.sum { |r| r["n"].to_i } } },
      "eligible_devices" => eligible, "answers" => answers }
  end


  # Nil for a campaign that asks nothing. The score is the average number of stars; a list of options has none.
  def answers
    question = @campaign.content["question"]
    return nil unless question.is_a?(Hash)

    counts = read(values_sql).to_h { |row| [row["value"].to_s, row["n"].to_i] }
    said = read(commented_sql).to_h { |row| [row["value"].to_s, row["n"].to_i] }
    { "type" => question["type"], "count" => counts.values.sum, "score" => score(question["type"], counts),
      "values" => labelled(question, counts, said) }
  end

  # An option removed after launch keeps its row, under its id, so the counts still add up.
  def labelled(question, counts, said)
    named = question["options"].map { |o| [o["id"], o["text"]] } if question["type"] == "choice"
    named ||= InAppEventCheck::STARS.map { |n| [n, n.to_s] }
    gone = (counts.keys | said.keys) - named.map { |value, _| value.to_s }
    (named + gone.sort.map { |value| [value, value] }).map do |value, label|
      { "value" => value, "label" => label, "count" => counts[value.to_s].to_i, "comments" => said[value.to_s].to_i }
    end
  end

  def score(type, counts)
    total = counts.values.sum
    return nil if total.zero? || type == "choice"

    (counts.sum { |value, n| value.to_i * n }.to_f / total).round(2)
  end

  def sum(rows) = rows.each_with_object(EMPTY.dup) { |row, out| out[NAMES.fetch(row["event_name"])] += row["n"].to_i }

  def grouped(rows, key)
    rows.group_by { |row| row[key].to_s }.sort.map { |value, list| { key => value }.merge(sum(list)) }
  end

  # Devices, not people: a membership row is one visitor.
  def eligible
    return SegmentMembership.where(project_id: @campaign.project_id, segment_key: @campaign.segment_key).count if @campaign.segment_key

    nil
  end

  MINE = <<~SQL.squish.freeze
    project_id = {project_id:UInt64} AND toDate(created_at, 'UTC') BETWEEN {from:Date} AND {to:Date}
    AND event_type = 'custom' AND CAST(properties.`campaign_id` AS String) = {campaign:String}
  SQL
  # A message closed by a turn to an orientation it doesn't allow wasn't dismissed by anyone.
  SCOPE = "#{MINE} AND event_name IN ('in_app_viewed', 'in_app_clicked', 'in_app_dismissed') " \
          "AND NOT (event_name = 'in_app_dismissed' AND CAST(properties.`reason` AS String) = 'orientation')".freeze
  # UTC by name: the label ends in Z, whatever time zone the server keeps.
  BUCKETS = { "hour" => "formatDateTime(toStartOfHour(created_at, 'UTC'), '%Y-%m-%dT%H:00:00Z', 'UTC')",
              "day" => "toString(toDate(created_at, 'UTC'))" }.freeze

  def counts_sql
    "SELECT event_name, #{BUCKETS.fetch(@by)} AS bucket, platform, CAST(properties.`button_id` AS String) AS button, count() AS n " \
      "FROM events FINAL WHERE #{SCOPE} GROUP BY event_name, bucket, platform, button"
  end

  def values_sql
    "SELECT CAST(properties.`value` AS String) AS value, count() AS n FROM events FINAL " \
      "WHERE #{MINE} AND event_name = 'in_app_answered' GROUP BY value"
  end

  def commented_sql
    "SELECT CAST(properties.`value` AS String) AS value, count() AS n FROM events FINAL " \
      "WHERE #{MINE} AND event_name = 'in_app_commented' GROUP BY value"
  end

  def page_sql(values, before)
    where = [MINE, "event_name = 'in_app_commented'"]
    where << "CAST(properties.`value` AS String) IN {values:Array(String)}" if values.any?
    where << "(created_at, event_id) < (fromUnixTimestamp64Milli({before_ms:Int64}, 'UTC'), {before_id:String})" if before.present?
    "SELECT CAST(properties.`value` AS String) AS value, CAST(properties.`comment` AS String) AS comment, platform, event_id, " \
      "toUnixTimestamp64Milli(created_at) AS ms, formatDateTime(created_at, '%Y-%m-%dT%H:%i:%SZ', 'UTC') AS at FROM events FINAL " \
      "WHERE #{where.join(' AND ')} ORDER BY created_at DESC, event_id DESC LIMIT #{PAGE + 1}"
  end

  def page_placeholders(values, before)
    ms, id = before.to_s.match(CURSOR)&.captures
    { values: values, before_ms: ms.to_i, before_id: id.to_s }.select { |key, _| key == :values ? values.any? : before.present? }
  end

  def export_sql
    # From the answer's own row, not the comment's: `any` over both picks whichever arrived first.
    "SELECT formatDateTime(min(created_at), '%Y-%m-%dT%H:%i:%SZ', 'UTC') AS at, " \
      "argMinIf(platform, created_at, event_name = 'in_app_answered') AS platform, " \
      "argMinIf(country, created_at, event_name = 'in_app_answered') AS country, " \
      "argMinIf(app_version, created_at, event_name = 'in_app_answered') AS app_version, " \
      "argMinIf(sdk_identifier, created_at, event_name = 'in_app_answered') AS user, " \
      "argMinIf(CAST(properties.`value` AS String), created_at, event_name = 'in_app_answered') AS value, " \
      "argMaxIf(CAST(properties.`comment` AS String), created_at, event_name = 'in_app_commented') AS comment " \
      "FROM events FINAL WHERE #{MINE} AND event_name IN ('in_app_answered', 'in_app_commented') " \
      "GROUP BY visitor_id HAVING countIf(event_name = 'in_app_answered') > 0 ORDER BY min(created_at) DESC LIMIT #{EXPORT_ROWS + 1}"
  end

  def people_sql
    "SELECT uniqExactIf(visitor_id, event_name = 'in_app_viewed') AS viewers, uniqExactIf(visitor_id, event_name = 'in_app_clicked') AS clickers " \
      "FROM events FINAL WHERE #{SCOPE}"
  end

  def read(sql, more = {})
    query = ClickHouse::Client::Query.new(
      raw_query: "#{sql} SETTINGS max_execution_time = #{TIMEOUT}",
      placeholders: { project_id: @campaign.project_id, from: @from.iso8601, to: @to.iso8601, campaign: @campaign.hashid }.merge(more)
    )
    Clickhouse.with_request_timeout(TIMEOUT + 2) { Clickhouse.with { |conn| conn.select_all(query) } }
  rescue ClickHouse::Client::DatabaseError, *Clickhouse::TRANSPORT_ERRORS => e
    raise Clickhouse::Unavailable, "in-app report" if Clickhouse.availability_error?(e)

    raise
  end
end
