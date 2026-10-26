require "bigdecimal"
require "erb"
require "time"
require_relative "in_app_definition_check"

# Executable statement of the engine rules; the SDK engines must agree with it on every shared case.
class InAppReferenceEngine
  STALE_AFTER = 48 * 3600
  BAD_SCHEMES = %w[javascript data file blob].freeze
  FIELD = /\{\{\s*(user|event)\.([A-Za-z0-9_]+)\s*(?:\|\s*default:\s*"([^"]*)"\s*)?\}\}/
  NUMBER = InAppDefinitionCheck::NUMBER
  RESERVED = %w[variants control_group conversion].freeze
  Unresolved = Class.new(StandardError)

  def initialize(kase)
    @device = kase.fetch("device")
    @campaigns = kase.fetch("campaigns").grep(Hash)
    @global = kase.fetch("global_caps")
    @synced_at = Time.iso8601(kase.fetch("synced_at"))
    @not_ready = kase.fetch("not_ready", [])
    @views = []
    @answered = []
    @session_views = []
    @counts = Hash.new(0)
    @counted = @campaigns.select { |c| supported?(c) }.flat_map { |c| c["conditions"] }
                         .select { |c| c["type"] == "event_count" }.map { |c| c["name"] }
    @next_view = 0
  end

  def start_session
    @session_views = []
  end

  # A sync restarts the 48 hour clock; the server has already left out campaigns this person is done with.
  def sync(response)
    @synced_at = Time.iso8601(response.fetch("at"))
  end

  # Kept for good: a person who has answered is not asked again, in this session or a later one.
  def answer(campaign_id)
    @answered << campaign_id
  end

  def track(event, at)
    now = Time.iso8601(at)
    @counts[event["name"]] += 1 if event["type"] == "event" && @counted.include?(event["name"])
    reasons = {}
    passing = @campaigns.select do |campaign|
      reason = skip_reason(campaign, event, now)
      reasons[campaign["id"]] = reason if reason
      reason.nil?
    end
    winner = passing.min_by { |c| [-c["priority"], Time.iso8601(c["created_at"]), c["id"]] }
    (passing - [winner]).each { |c| reasons[c["id"]] = "lower_priority" }
    return { "show" => nil, "reasons" => reasons } if winner.nil?

    view = record_view(winner, now)
    { "show" => winner["id"], "view" => view["id"], "delay" => winner["delay_seconds"], "reasons" => reasons }.merge(rendered(winner, event))
  end

  private

  def skip_reason(campaign, event, now)
    return "stale" if now - @synced_at > STALE_AFTER
    return "unsupported" unless supported?(campaign)
    return "no_trigger" unless campaign["triggers"].any? { |t| trigger_matches?(t, event) }
    return "not_ready" if @not_ready.include?(campaign["id"])
    return "schedule" unless scheduled?(campaign["schedule"], now)
    return "condition" unless conditions_pass?(campaign, now)

    cap_reason(campaign, now) || content_reason(campaign, event)
  end

  def supported?(campaign)
    return false unless InAppDefinitionCheck.well_formed?(campaign)
    return false unless campaign["format"] == 1 && campaign["delivery_mode"] == "device"
    return false unless RESERVED.all? { |field| campaign[field].nil? }
    return false if @device.fetch("unsupported_templates", []).include?(campaign["template"])

    (action_types(campaign) & @device.fetch("unsupported_actions", [])).empty?
  end

  def actions(campaign)
    content = campaign["content"]
    (content["buttons"].map { |b| b["action"] } + [content["tap_action"]]).compact
  end

  def action_types(campaign) = actions(campaign).map { |a| a["type"] }

  def trigger_matches?(trigger, event)
    return false unless trigger["type"] == event["type"]

    case trigger["type"]
    when "app_open" then true
    when "screen_view" then trigger["name"].nil? || trigger["name"].downcase == event["name"].to_s.downcase
    else trigger["name"] == event["name"] && trigger.fetch("filters", []).all? { |f| compare(event.fetch("properties", {})[f["field"]], f["op"], f["value"]) }
    end
  end

  # Lists and objects have no text form that every platform agrees on, so they count as no value.
  def text(value)
    case value
    when nil, Hash, Array then nil
    when Float then value == value.floor ? value.to_i.to_s : BigDecimal(value.to_s).to_s("F")
    else value.to_s
    end
  end

  def compare(actual, operator, expected)
    actual = text(actual)
    present = !actual.nil? && actual != ""
    return !present if operator == "is_not_set"
    return false unless present
    return true if operator == "is_set"
    return between?(actual, expected) if operator == "between"

    expected = text(expected)
    return false if expected.nil?

    case operator
    when "eq" then same?(actual, expected)
    when "neq" then !same?(actual, expected)
    when "gt" then numbers?(actual, expected) && number(actual) > number(expected)
    when "lt" then numbers?(actual, expected) && number(actual) < number(expected)
    when "contains" then actual.downcase.include?(expected.downcase)
    when "not_contains" then !actual.downcase.include?(expected.downcase)
    else false
    end
  end

  def between?(actual, range)
    return false unless range.is_a?(Array) && range.size == 2 && numbers?(actual, *range)

    number(actual).between?(number(range[0]), number(range[1]))
  end

  def numbers?(*values) = values.all? { |v| v.is_a?(Numeric) || v.to_s.match?(NUMBER) }

  # Doubles, because that is the only number every platform's JSON parser agrees on.
  def number(value) = Float(text(value))

  def same?(actual, expected)
    return (number(actual) <=> number(expected)).zero? if numbers?(actual, expected)

    actual.downcase == expected.downcase
  end

  def version_order(left, right)
    a, b = [left, right].map { |v| v.to_s[/\A[\d.]*/].split(".").map(&:to_i) }
    size = [a.size, b.size].max
    (a + ([0] * (size - a.size))) <=> (b + ([0] * (size - b.size)))
  end

  def version_passes?(actual, operator, expected)
    return false if text(actual).to_s.empty?

    case operator
    when "eq" then version_order(actual, expected).zero?
    when "neq" then !version_order(actual, expected).zero?
    when "gt" then version_order(actual, expected).positive?
    when "lt" then version_order(actual, expected).negative?
    when "between" then version_order(actual, expected[0]) >= 0 && version_order(actual, expected[1]) <= 0
    else false
    end
  end

  def conditions_pass?(campaign, now)
    return false if action_types(campaign).include?("request_push_permission") && @device["push_permission"] == "granted"
    # A restricted message waits for its orientation, like a condition; absent and "any" fit both.
    return false unless [nil, "any", @device.fetch("orientation", "portrait")].include?(campaign["content"]["orientation"])

    campaign["conditions"].all? { |c| condition_passes?(c, now) }
  end

  def condition_passes?(condition, now)
    op = condition["op"]
    value = condition["value"]
    case condition["type"]
    when "platform" then compare(@device["platform"], op, value)
    when "language" then compare(@device["language"], op, value)
    when "app_version" then version_passes?(@device["app_version"], op, value)
    when "os_version" then version_passes?(@device["os_version"], op, value)
    when "user_attribute" then compare(@device.fetch("user", {})[condition["key"]], op, value)
    when "event_count" then compare(@counts[condition["name"]], op, value)
    when "first_seen" then first_seen_passes?(op, value, now)
    else false
    end
  end

  def first_seen_passes?(operator, value, now)
    return false unless InAppDefinitionCheck.timestamp?(@device["first_seen_at"])

    seen = Time.iso8601(@device["first_seen_at"])
    case operator
    when "before" then seen < Time.iso8601(value)
    when "after" then seen > Time.iso8601(value)
    when "within_days" then now - seen <= value * 86_400
    else false
    end
  end

  def local(time) = (time + (@device.fetch("utc_offset_minutes", 0) * 60)).utc

  def weekday(time) = time.wday.zero? ? 7 : time.wday

  def scheduled?(schedule, now)
    return false if now < Time.iso8601(schedule["start_at"])
    return false if schedule["end_at"] && now >= Time.iso8601(schedule["end_at"])

    here = local(now)
    clock = here.strftime("%H:%M")
    return false unless in_clock_window?(schedule["from"], schedule["to"], clock)

    schedule["days"].nil? || schedule["days"].include?(weekday(opened_on(schedule, here, clock)))
  end

  def in_clock_window?(from, to, clock)
    return true if from.nil? || to.nil? || from == to
    return clock >= from && clock < to if from <= to

    clock >= from || clock < to
  end

  # After midnight inside a window that crosses it, the day that counts is the one the window opened on.
  def opened_on(schedule, here, clock)
    from = schedule["from"]
    crosses = !from.nil? && from > schedule["to"]
    crosses && clock < schedule["to"] ? here - 86_400 : here
  end

  def day_of(time) = local(time).strftime("%Y-%m-%d")

  def week_of(time)
    here = local(time)
    (here - ((weekday(here) - 1) * 86_400)).strftime("%Y-%m-%d")
  end

  # Every cap is counted on the device, from the views this device recorded.
  def cap_reason(campaign, now)
    return "answered" if @answered.include?(campaign["id"])

    caps = campaign["caps"]
    mine = @views.select { |v| v["campaign"] == campaign["id"] }
    in_session = @session_views.select { |v| v["campaign"] == campaign["id"] }
    return "cap_session" if over?(caps["session"], in_session.size)
    return "cap_day" if over?(caps["day"], mine.count { |v| day_of(v["at"]) == day_of(now) })
    return "cap_week" if over?(caps["week"], mine.count { |v| week_of(v["at"]) == week_of(now) })
    return "cap_lifetime" if over?(caps["lifetime"], mine.size)
    return nil if caps["ignore_global"]
    return "cap_global_session" if over?(@global["session"], @session_views.count { |v| v["global"] })

    "cap_global_day" if over?(@global["day"], @views.count { |v| v["global"] && day_of(v["at"]) == day_of(now) })
  end

  def over?(limit, count) = !limit.nil? && count >= limit

  def content_reason(campaign, event)
    rendered(campaign, event)
    actions(campaign).select { |a| a["type"] == "open_url" }.any? { |a| unsafe?(a["url"], event) } ? "unsafe_link" : nil
  rescue Unresolved
    "personalization"
  end

  def unsafe?(template, event)
    fixed = template[%r{\A[A-Za-z][A-Za-z0-9+.-]*://[^/?#]*}] || template[/\A[A-Za-z][A-Za-z0-9+.-]*:/]
    return true if fixed.nil? || fixed.include?("{{")

    BAD_SCHEMES.include?(fill(template, event, encode: true)[/\A[^:]+/].downcase)
  end

  def fill(template, event, encode: false)
    raise Unresolved if template.gsub(FIELD, "").include?("{{")

    template.gsub(FIELD) do
      source = Regexp.last_match(1) == "user" ? @device.fetch("user", {}) : event.fetch("properties", {})
      value = text(source[Regexp.last_match(2)])
      value = Regexp.last_match(3) if value.nil? || value == ""
      raise Unresolved if value.nil?

      encode ? ERB::Util.url_encode(value) : value
    end
  end

  def rendered(campaign, event)
    content = campaign["content"]
    { "title" => content["title"] && fill(content["title"], event),
      "message" => content["message"] && fill(content["message"], event),
      "buttons" => content["buttons"].map { |b| fill(b["text"], event) },
      "urls" => actions(campaign).select { |a| a["type"] == "open_url" }.map { |a| fill(a["url"], event, encode: true) } }
  end

  def record_view(campaign, now)
    @next_view += 1
    view = { "id" => "d#{@next_view}", "campaign" => campaign["id"], "at" => now, "global" => !campaign["caps"]["ignore_global"] }
    @views << view
    @session_views << view
    view
  end
end
