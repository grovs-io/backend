require "date"

# What an engine must find in a definition before it will consider it; unknown fields are ignored.
module InAppDefinitionCheck
  TIMESTAMP = /\A(\d{4})-(\d{2})-(\d{2})T([01]\d|2[0-3]):[0-5]\d:[0-5]\d(\.\d{1,3})?Z\z/
  CLOCK = /\A([01]\d|2[0-3]):[0-5]\d\z/
  NUMBER = /\A-?\d+(\.\d+)?\z/
  TEMPLATES = %w[cover interstitial half_interstitial header footer alert
                 cover_image interstitial_image half_interstitial_image html].freeze
  LAYOUTS = %w[full modal banner_top banner_bottom].freeze
  ORIENTATIONS = [nil, "any", "portrait", "landscape"].freeze
  ACTIONS = %w[close open_url key_value request_push_permission request_app_rating open_store].freeze
  VALUE_OPS = %w[eq neq gt lt contains not_contains].freeze
  ORDER_OPS = %w[eq neq gt lt].freeze
  CAPS = %w[session day week lifetime].freeze

  module_function

  NO_QUESTION = %w[alert cover_image interstitial_image half_interstitial_image html].freeze

  def well_formed?(campaign)
    campaign.is_a?(Hash) && header?(campaign) && content?(campaign["content"]) && page?(campaign) && way_out?(campaign) &&
      holds_question?(campaign) && triggers?(campaign["triggers"]) &&
      list_of?(campaign["conditions"]) { |c| condition?(c) } && caps?(campaign["caps"]) &&
      schedule?(campaign["schedule"])
  end

  def header?(campaign)
    whole?(campaign["format"]) && string?(campaign["id"]) && whole?(campaign["priority"]) &&
      timestamp?(campaign["created_at"]) && TEMPLATES.include?(campaign["template"]) &&
      whole?(campaign["delay_seconds"]) && !campaign["delay_seconds"].negative? && string?(campaign["delivery_mode"])
  end

  def content?(content)
    content.is_a?(Hash) && text_or_nil?(content["title"]) && text_or_nil?(content["message"]) &&
      list_of?(content["buttons"]) { |b| button?(b) } && (content["tap_action"].nil? || action?(content["tap_action"])) &&
      asked?(content) && ORIENTATIONS.include?(content["orientation"])
  end

  def page?(campaign)
    campaign["template"] != "html" || (campaign["content"]["html"].is_a?(String) && LAYOUTS.include?(campaign["content"]["layout"]))
  end

  QUESTIONS = %w[stars choice].freeze

  # Answering is a tap on the question, so a question stands in for the buttons and the tap action.
  def asked?(content)
    question = content["question"]
    return true if question.nil?
    return false unless question.is_a?(Hash) && string?(question["id"]) && QUESTIONS.include?(question["type"])
    return false unless content["buttons"].empty? && content["tap_action"].nil?

    options = question["options"]
    chosen = question["type"] == "choice"
    list_of?(options) { |o| o.is_a?(Hash) && string?(o["id"]) && string?(o["text"]) } && (chosen ? options.size.between?(2, 5) : options.empty?)
  end

  # These templates draw no question, so one on them would be lost, or shut the person in.
  def holds_question?(campaign)
    campaign["content"]["question"].nil? || !NO_QUESTION.include?(campaign["template"])
  end

  # A message nobody can dismiss must offer something to tap, or it would hold the screen for ever; an html page carries its own.
  def way_out?(campaign)
    content = campaign["content"]
    return true if content["dismissible"].nil? || content["dismissible"] == true

    content["dismissible"] == false && (campaign["template"] == "html" || content["buttons"].any? ||
      !content["tap_action"].nil? || !content["question"].nil?)
  end

  def button?(button) = button.is_a?(Hash) && string?(button["id"]) && string?(button["text"]) && action?(button["action"])

  def action?(action)
    return false unless action.is_a?(Hash) && ACTIONS.include?(action["type"])

    case action["type"]
    when "open_url" then string?(action["url"])
    when "key_value" then action["payload"].is_a?(Hash)
    else true
    end
  end

  def triggers?(triggers) = list_of?(triggers) { |t| trigger?(t) } && triggers.any?

  def trigger?(trigger)
    return false unless trigger.is_a?(Hash)

    case trigger["type"]
    when "app_open" then !trigger.key?("name") && !trigger.key?("filters")
    when "screen_view" then !trigger.key?("filters") && (!trigger.key?("name") || string?(trigger["name"]))
    when "event" then string?(trigger["name"]) && list_of?(trigger.fetch("filters", [])) { |f| comparison?(f) && string?(f["field"]) }
    else false
    end
  end

  def comparison?(rule)
    return false unless rule.is_a?(Hash)

    case rule["op"]
    when "is_set", "is_not_set" then true
    when "between" then pair?(rule["value"]) { |v| number?(v) }
    when *VALUE_OPS then scalar?(rule["value"])
    else false
    end
  end

  def condition?(condition)
    return false unless condition.is_a?(Hash)

    case condition["type"]
    when "platform", "language" then %w[eq neq].include?(condition["op"]) && string?(condition["value"])
    when "app_version", "os_version" then ordered?(condition) { |v| string?(v) }
    when "event_count" then string?(condition["name"]) && ordered?(condition) { |v| number?(v) }
    when "user_attribute" then string?(condition["key"]) && comparison?(condition)
    when "first_seen" then first_seen?(condition)
    else false
    end
  end

  def ordered?(condition, &)
    return pair?(condition["value"], &) if condition["op"] == "between"

    ORDER_OPS.include?(condition["op"]) && yield(condition["value"])
  end

  def first_seen?(condition)
    case condition["op"]
    when "before", "after" then timestamp?(condition["value"])
    when "within_days" then whole?(condition["value"]) && condition["value"].positive?
    else false
    end
  end

  def caps?(caps)
    caps.is_a?(Hash) && [true, false].include?(caps["ignore_global"]) &&
      CAPS.all? { |name| caps[name].nil? || (whole?(caps[name]) && caps[name].positive?) }
  end

  def schedule?(schedule)
    return false unless schedule.is_a?(Hash) && timestamp?(schedule["start_at"])
    return false unless schedule["end_at"].nil? || timestamp?(schedule["end_at"])
    return false unless schedule["days"].nil? || (list_of?(schedule["days"]) { |d| whole?(d) && d.between?(1, 7) } && schedule["days"].any?)

    window = [schedule["from"], schedule["to"]]
    window.all?(&:nil?) || window.all? { |clock| string?(clock) && clock.match?(CLOCK) }
  end

  def list_of?(list, &) = list.is_a?(Array) && list.all?(&)
  def pair?(list, &) = list_of?(list, &) && list.size == 2
  def string?(value) = value.is_a?(String) && !value.empty?
  def scalar?(value) = value.is_a?(String) || value.is_a?(Numeric) || [true, false].include?(value)
  def text_or_nil?(value) = value.nil? || value.is_a?(String)
  def number?(value) = value.is_a?(Numeric) || (value.is_a?(String) && value.match?(NUMBER))

  # JavaScript cannot tell 1.0 from 1, so a number with no fractional part is a whole number everywhere.
  def whole?(value) = value.is_a?(Integer) || (value.is_a?(Float) && value.finite? && value == value.floor)

  def timestamp?(value)
    parts = value.is_a?(String) && value.match(TIMESTAMP)
    parts ? Date.valid_date?(parts[1].to_i, parts[2].to_i, parts[3].to_i) : false
  end
end
