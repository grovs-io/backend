# Which branch of a split each person takes, decided for a whole batch at once.
class Journeys::Forks
  TIMEOUT = 15
  PERMIT_TTL = 60

  # written: attributes set earlier in the same pass, not yet committed, by visitor.
  def initialize(journey, written = {})
    @journey = journey
    @written = written
  end

  # visitor_ids of the people at this split => { visitor_id => branch }
  def decide(step, visitor_ids)
    return percent(step, visitor_ids) if step["mode"] == "percent"

    condition = step["condition"]
    yes = case condition["kind"]
          when "event" then did_event(condition, visitor_ids)
          when "segment" then in_segment(condition, visitor_ids)
          when "attribute" then with_attribute(condition, visitor_ids)
          when "platform" then on_platform(condition, visitor_ids)
          else Set.new
          end
    visitor_ids.index_with { |id| yes.include?(id) ? "yes_next" : "no_next" }
  end

  private

  # Fixed per person and step, so a person who comes back takes the same path.
  def percent(step, visitor_ids)
    visitor_ids.index_with do |id|
      bucket = Experiments::Bucket.of("#{@journey.hashid}:#{step['id']}", id)
      edge = 0
      index = step["paths"].index { |path| bucket < (edge += path["percent"]) } || (step["paths"].size - 1)
      "path_#{index}"
    end
  end

  def in_segment(condition, visitor_ids)
    key = @journey.segment_keys.dig(condition["segment_id"], "key")
    return Set.new if key.nil?

    SegmentMembership.where(segment_key: key, visitor_id: visitor_ids).pluck(:visitor_id).to_set
  end

  def on_platform(condition, visitor_ids)
    Visitor.joins(:device).where(id: visitor_ids, devices: { platform: condition["values"] }).pluck(:id).to_set
  end

  def with_attribute(condition, visitor_ids)
    rows = Visitor.where(id: visitor_ids).pluck(:id, :sdk_attributes)
    rows.select { |id, attrs| attribute?((attrs.is_a?(Hash) ? attrs : {}).merge(@written.fetch(id, {})), condition) }.to_set(&:first)
  end

  def attribute?(attributes, condition)
    value = attributes.is_a?(Hash) ? attributes[condition["key"]] : nil
    matcher = Journeys::Matcher
    case condition["op"]
    when "exists" then matcher.compare(value, "is_set", nil)
    when "not_exists" then matcher.compare(value, "is_not_set", nil)
    else matcher.compare(value, condition["op"], condition["value"])
    end
  end

  # One ClickHouse query for the batch, in its own permit lane so a mass entry queues instead of flooding it.
  def did_event(condition, visitor_ids)
    event = condition["event"]
    placeholders = { project_id: @journey.project_id, ids: visitor_ids, days: condition["days"], min: condition["min_count"],
                     name: (event["name"] || event["screen"] || event["system"]).to_s }
    filters = Array(event["filters"]).each_with_index.map { |filter, i| filter_sql(filter, i, placeholders) }
    named = if event["system"].present?
              "event_type = {name:String}"
            elsif event["screen"].present?
              "event_type = 'screen_view' AND lower(screen_name) = lower({name:String})"
            else
              "event_type = 'custom' AND event_name = {name:String}"
            end
    sql = <<~SQL.squish
      SELECT visitor_id FROM events FINAL
      WHERE project_id = {project_id:UInt64} AND visitor_id IN {ids:Array(UInt64)} AND created_at >= now() - INTERVAL {days:UInt32} DAY
        AND #{named} #{filters.map { |f| "AND #{f}" }.join(' ')}
      GROUP BY visitor_id HAVING count() >= {min:UInt32}
    SQL
    Segments::Permits.with(@journey.project_id, ttl: PERMIT_TTL, lane: :journeys) { read(sql, placeholders) }.to_set { |row| Integer(row["visitor_id"]) }
  end

  # The field is checked against Journey::FIELD before it is saved, so it is safe inside backticks.
  def filter_sql(filter, index, placeholders)
    raise ArgumentError, "bad field" unless filter["field"].match?(Journey::FIELD)

    prop = "CAST(properties.`#{filter['field']}` AS String)"
    name = "f#{index}"
    value = Journeys::Matcher.text(filter["value"])
    case filter["op"]
    when "is_set" then "#{prop} != ''"
    when "is_not_set" then "#{prop} = ''"
    when "between"
      placeholders[:"#{name}a"], placeholders[:"#{name}b"] = filter["value"].map(&:to_f)
      "toFloat64OrNull(#{prop}) BETWEEN {#{name}a:Float64} AND {#{name}b:Float64}"
    when "gt", "lt"
      placeholders[name.to_sym] = value.to_f
      "toFloat64OrNull(#{prop}) #{filter['op'] == 'gt' ? '>' : '<'} {#{name}:Float64}"
    else
      placeholders[name.to_sym] = value.to_s
      text_sql(filter["op"], prop, name)
    end
  end

  def text_sql(operator, prop, name)
    case operator
    when "eq" then "lower(#{prop}) = lower({#{name}:String})"
    when "neq" then "#{prop} != '' AND lower(#{prop}) != lower({#{name}:String})"
    when "contains" then "positionCaseInsensitiveUTF8(#{prop}, {#{name}:String}) > 0"
    else "#{prop} != '' AND positionCaseInsensitiveUTF8(#{prop}, {#{name}:String}) = 0"
    end
  end

  def read(sql, placeholders)
    query = ClickHouse::Client::Query.new(raw_query: "#{sql} SETTINGS max_execution_time = #{TIMEOUT}", placeholders: placeholders)
    Clickhouse.with_request_timeout(TIMEOUT + 2) { Clickhouse.with { |conn| conn.select_all(query) } }
  rescue ClickHouse::Client::DatabaseError, *Clickhouse::TRANSPORT_ERRORS => e
    raise Clickhouse::Unavailable, "journey split" if Clickhouse.availability_error?(e)

    raise
  end
end
