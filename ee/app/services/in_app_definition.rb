require "json-schema"
require "nokogiri"
require "strscan"

# The format 1 definition a device receives, and the checks the backend owes it.
module InAppDefinition
  SCHEMA = JSON.parse(Rails.root.join("ee/config/in_app/definition.schema.json").read).freeze
  MAX_BYTES = 16 * 1024
  HTML_MAX_BYTES = 64 * 1024
  FIELD = /\{\{\s*(user|event)\.[A-Za-z0-9_]+\s*(\|\s*default:\s*"[^"{}]*"\s*)?\}\}/
  # http is excluded on purpose: html content always requires https, unlike the general link/open_url rule.
  FORBIDDEN_LINK_SCHEMES = %w[javascript vbscript data blob file about intent http].freeze
  URL_ATTRS = %w[href src poster srcset data-grovs-url].freeze
  CONTENT = { "title" => nil, "message" => nil, "image" => { "portrait" => nil, "landscape" => nil }, "colors" => {},
              "close_button" => true, "dismissible" => true, "backdrop" => "dim", "buttons" => [], "tap_action" => nil,
              "question" => nil }.freeze
  CAPS = { "session" => nil, "day" => nil, "week" => nil, "lifetime" => nil, "ignore_global" => false }.freeze

  module_function

  def build(campaign)
    schedule = campaign.schedule.is_a?(Hash) ? campaign.schedule : {}
    {
      "format" => 1, "id" => campaign.hashid, "revision" => campaign.revision, "created_at" => stamp(campaign.created_at || Time.current),
      "priority" => campaign.priority, "template" => campaign.template,
      "content" => CONTENT.merge(campaign.content.is_a?(Hash) ? campaign.content : {}),
      "triggers" => campaign.triggers, "conditions" => campaign.conditions,
      "caps" => CAPS.merge(campaign.caps.is_a?(Hash) ? campaign.caps : {}),
      "schedule" => { "start_at" => stamp(campaign.start_at || campaign.launched_at || campaign.created_at || Time.current),
                      "end_at" => campaign.end_at && stamp(campaign.end_at),
                      "days" => schedule["days"], "from" => schedule["from"], "to" => schedule["to"] },
      "delay_seconds" => campaign.delay_seconds, "delivery_mode" => "device",
      "variants" => nil, "control_group" => nil, "conversion" => nil
    }
  end

  def problems(definition)
    return ["Text cannot hold a line break outside the title and message"] if stray_line_break?(definition)

    found = JSON::Validator.fully_validate(SCHEMA, definition.merge("id" => definition["id"] || "new"))
                           .reject { |error| own_upload?(definition, error) }.map { |error| explain(error) }.uniq
    found.concat(own_rules(definition)) if found.empty?
    found
  end

  # The 16 KB definition limit excludes html: it has its own 64 KB check, measured raw.
  def size_of(definition)
    content = definition["content"]
    trimmed = content.is_a?(Hash) ? definition.merge("content" => content.except("html")) : definition
    trimmed.to_json.bytesize
  end

  # cases.json's link_rule section is the one normative source for this; keep it and this method in step.
  def link_allowed?(url)
    normalised = normalise_link(url)
    return true if normalised.start_with?("#")

    scheme = normalised[/\A([a-z][a-z0-9+.-]*):/i, 1]&.downcase
    return false if scheme.nil?
    return normalised.match?(%r{\Ahttps://[^/?#\s]+}i) if scheme == "https"
    return true if %w[mailto tel sms].include?(scheme)

    !FORBIDDEN_LINK_SCHEMES.include?(scheme)
  end

  # Resources never get the custom-scheme or mailto/tel/sms allowance a navigable link gets.
  # Local development serves media over http; production never accepts these hosts.
  LOCAL_HTTP = %r{\Ahttp://(localhost|127\.0\.0\.1|[a-z0-9.-]+\.lvh\.me|[a-z0-9.-]+\.localhost)(:\d+)?(/|\z)}i

  def resource_allowed?(url, image:)
    normalised = normalise_link(url)
    return true if normalised.match?(%r{\Ahttps://[^/?#\s]+}i) || (Rails.env.local? && normalised.match?(LOCAL_HTTP))

    image && normalised.match?(%r{\Adata:image/}i)
  end

  def normalise_link(url)
    trimmed = url.to_s.gsub(/\A[\u0000- ]+/, "").gsub(/[\u0000- ]+\z/, "").gsub(/[\t\n\r]/, "")
    trimmed.sub(/\A[A-Za-z][A-Za-z0-9+.-]*(?=:)/, &:downcase)
  end

  NAMES = { "content/title" => "The title", "content/message" => "The message", "content/image/portrait" => "The portrait image",
            "content/image/landscape" => "The landscape image", "content/tap_action" => "The tap action", "content" => "The message",
            "triggers" => "The triggers", "conditions" => "The conditions", "priority" => "The priority", "template" => "The template",
            "delay_seconds" => "The delay", "content/dismissible" => "Whether it can be dismissed", "content/question" => "The question",
            "content/orientation" => "The orientation",
            "caps/session" => "The limit per session", "caps/day" => "The limit per day", "caps/week" => "The limit per week",
            "caps/lifetime" => "The limit for ever", "schedule" => "The schedule", "schedule/days" => "The days",
            "schedule/from" => "The first hour", "schedule/to" => "The last hour" }.freeze
  PARTS = { "text" => "label", "url" => "link", "action" => "action", "name" => "name", "field" => "property", "value" => "value",
            "op" => "operator", "colors" => "colours", "key" => "attribute", "filters" => "filters" }.freeze
  LISTS = { "buttons" => "Button", "triggers" => "Trigger", "conditions" => "Condition" }.freeze

  # The validator speaks of properties and patterns; the person reading it chose a title and a picture.
  def explain(error)
    # Only the first line: what follows lists every shape the value failed to be, which explains nothing.
    first = error.lines.first.to_s
    path = first[%r{'#/([^']*)'}, 1].to_s
    "#{name_of(path)} #{complaint(first, path)}"
  end

  def name_of(path)
    return NAMES[path] if NAMES.key?(path)

    list = LISTS.find { |key, _| path =~ %r{(?:\A|/)#{key}/(\d+)} }
    return "The campaign" if list.nil? && path.empty?
    return "The #{path.split('/').last.tr('_', ' ')}" if list.nil?

    part = PARTS[path.split("/").reverse.find { |piece| PARTS.key?(piece) }]
    ["#{list[1]} #{Regexp.last_match(1).to_i + 1}", part].compact.join(" ")
  end

  def complaint(error, path)
    case error
    when /minimum number of items (\d+)/ then "need at least #{Regexp.last_match(1)}"
    when /more items than the allowed (\d+)/ then "can be at most #{Regexp.last_match(1)}"
    when /minimum string length/ then "cannot be empty"
    when /maximum string length of (\d+)/ then "cannot be longer than #{Regexp.last_match(1)} characters"
    when /minimum value of (\d+)/ then "must be #{Regexp.last_match(1)} or more"
    when /maximum value of (\d+)/ then "must be #{Regexp.last_match(1)} or less"
    when /required property of '([^']+)'/ then "is missing its #{Regexp.last_match(1).tr('_', ' ')}"
    when /did not match the regex/ then path.include?("image") ? "must be served over https" : "is not valid"
    else "is not valid"
    end
  end

  # Outside production this server may hand out plain http addresses for its own uploads.
  def own_upload?(definition, error)
    return false if Rails.env.production?

    slot = error[%r{'#/content/image/(portrait|landscape)'}, 1]
    prefix = ENV.fetch("S3_ASSET_PREFIX", "")
    slot.present? && prefix.start_with?("http://") && definition.dig("content", "image", slot).to_s.start_with?(prefix)
  end

  def own_rules(definition)
    found = []
    found << "The campaign is larger than 16 KB" if size_of(definition) > MAX_BYTES
    ids = definition["content"]["buttons"].pluck("id")
    found << "Button ids must be unique" if ids.uniq.size != ids.size
    finish = definition["schedule"]["end_at"]
    found << "The end must be after the start" if finish && Time.iso8601(finish) <= Time.iso8601(definition["schedule"]["start_at"])
    found << "Text holds {{ that is not a field" if texts(definition).any? { |text| text.gsub(FIELD, "").include?("{{") }
    found << "A web link must name its site in full, such as https://example.com" if links(definition).any? { |link| loose?(link) }
    found << "A condition holds a date that does not exist" unless definition["conditions"].all? { |condition| real_date?(condition) }
    found << "An alert that cannot be dismissed needs a button" if trap?(definition)
    found.concat(alert_rules(definition["content"])) if definition["template"] == "alert"
    found.concat(html_rules(definition)) if definition["template"] == "html"
    found.concat(question_rules(definition))
  end

  # Reached only once the schema has already confirmed content.html and content.layout are present and shaped.
  def html_rules(definition)
    html = definition.dig("content", "html").to_s
    return ["The HTML cannot be empty"] if html.strip.empty?
    return ["The HTML is larger than 64 KB"] if html.bytesize > HTML_MAX_BYTES

    doc = parse_html(html)
    return ["The HTML could not be read"] if doc.nil?

    found = []
    found << "The HTML cannot use a <base> tag" if doc.at_css("base")
    found << 'The HTML cannot use <meta http-equiv="refresh">' if doc.css("meta").any? { |node| node["http-equiv"].to_s.casecmp?("refresh") }
    found << "The HTML links to an address that is not allowed" if disallowed_link?(doc)
    found << "The HTML loads a resource that is not allowed" if disallowed_resource?(doc)
    found.concat(field_in_url_problems(doc))
    found
  end

  # {{ inside these is reported by field_in_url_problems instead; a fillable value is never "not allowed" here.
  def fillable?(value) = value.to_s.include?("{{")

  def disallowed_link?(doc)
    bad_href = doc.css("a[href]").any? { |node| !fillable?(node["href"]) && !link_allowed?(node["href"]) }
    bad_action = doc.css("[data-grovs-url]").any? { |node| !fillable?(node["data-grovs-url"]) && !link_allowed?(node["data-grovs-url"]) }
    bad_href || bad_action
  end

  def disallowed_resource?(doc)
    return true if doc.css("[src]").any? { |node| !fillable?(node["src"]) && !resource_allowed?(node["src"], image: node.name == "img") }
    return true if doc.css("[poster]").any? { |node| !fillable?(node["poster"]) && !resource_allowed?(node["poster"], image: true) }
    return true if doc.css("link[href]").any? { |node| !fillable?(node["href"]) && !resource_allowed?(node["href"], image: false) }
    return true if doc.css("[srcset]").any? { |node| !fillable?(node["srcset"]) && bad_srcset?(node["srcset"]) }

    doc.css("[style]").any? { |node| style_urls(node["style"]).any? { |url| !resource_allowed?(url, image: true) } }
  end

  def bad_srcset?(value) = srcset_urls(value).any? { |url| !resource_allowed?(url, image: true) }

  # URL attributes are never filled (grovs.user/grovs.event build those in script), so {{ there is always a mistake.
  def field_in_url_problems(doc)
    offenders = url_attributes(doc).select { |_, value| value.include?("{{") }.first(3)
    return [] if offenders.empty?

    named = offenders.map { |attr, value| "#{attr}=\"#{value}\"" }.join(", ")
    ["The HTML holds {{ inside a URL attribute: #{named}; build personalized URLs with grovs.user"]
  end

  def url_attributes(doc)
    doc.css(URL_ATTRS.map { |attr| "[#{attr}]" }.join(",")).flat_map do |node|
      URL_ATTRS.filter_map { |attr| [attr, node[attr]] if node[attr] }
    end
  end

  # The HTML spec's candidate grammar: a run of non-whitespace is the URL; a trailing comma on it is the separator,
  # so a data: URI's own internal commas (before any whitespace) are never mistaken for one.
  def srcset_urls(value)
    scanner = StringScanner.new(value.to_s)
    urls = []
    until scanner.eos?
      scanner.skip(/[\s,]+/)
      url = scanner.scan(/\S+/)
      break if url.nil?

      if url.end_with?(",")
        urls << url.sub(/,+\z/, "")
      else
        urls << url
        scanner.skip(/\s+/)
        scanner.skip(/[^,]*/)
        scanner.skip(/,/)
      end
    end
    urls
  end

  STYLE_URL = /url\(\s*(?:"((?:[^"\\]|\\.)*)"|'((?:[^'\\]|\\.)*)'|((?:[^"'()\s\\]|\\.)*))\s*\)/im

  def style_urls(value)
    style = value.to_s.gsub(%r{/\*.*?\*/}m, "")
    found = style.scan(STYLE_URL).map { |parts| parts.compact.first.gsub(/\\(.)/m, '\1') }
    # A url( the pattern could not read is answered with an address nothing allows, never skipped.
    found << "unreadable:" if style.gsub(STYLE_URL, "").match?(/url\(/i)
    found.reject(&:empty?)
  end

  def parse_html(html)
    Nokogiri::HTML5.parse(html)
  rescue StandardError
    nil
  end

  NO_QUESTION = %w[alert cover_image interstitial_image half_interstitial_image html].freeze

  def question_rules(definition)
    question = definition["content"]["question"]
    return [] if question.nil?

    found = []
    found << "This kind of message cannot hold a question" if NO_QUESTION.include?(definition["template"])
    ids = question["options"].pluck("id")
    found << "Option ids must be unique" if ids.uniq.size != ids.size
    split = question.dig("comment", "split")
    found << "The follow-up cannot split a list of options" if split && question["type"] == "choice"
    found
  end

  # The system alert gets cramped with long text; the dashboard enforces the same limits.
  ALERT_LIMITS = { "title" => 80, "message" => 300 }.freeze
  ALERT_BUTTON_LIMIT = 30

  def alert_rules(content)
    found = ALERT_LIMITS.filter_map do |key, max|
      "An alert #{key} cannot be longer than #{max} characters" if content[key].to_s.length > max
    end
    long_button = content["buttons"].any? { |button| button["text"].to_s.length > ALERT_BUTTON_LIMIT }
    found << "An alert button label cannot be longer than #{ALERT_BUTTON_LIMIT} characters" if long_button
    found
  end

  # The system alert has no tap action, so without a button nothing would close it.
  def trap?(definition)
    content = definition["content"]
    definition["template"] == "alert" && content["dismissible"] == false && content["buttons"].empty?
  end

  # A web link whose site a field could supply, or a scheme that runs code or another app's intent.
  def loose?(link)
    return true if link.match?(/\A(vbscript|intent):/i)

    link.match?(/\Ahttps?:/i) && !link.match?(%r{\Ahttps?://[^/?#\s]+}i)
  end

  def real_date?(condition)
    return true unless condition["type"] == "first_seen" && condition["value"].is_a?(String)

    year, month, day = condition["value"][0, 10].split("-").map(&:to_i)
    Date.valid_date?(year, month, day)
  end

  def links(definition)
    content = definition["content"]
    (content["buttons"].pluck("action") + [content["tap_action"]]).compact.pluck("url").compact
  end

  def texts(definition)
    content = definition["content"]
    actions = content["buttons"].pluck("action") + [content["tap_action"]]
    [content["title"], content["message"], *content["buttons"].pluck("text"), *actions.compact.pluck("url")].compact
  end

  # Ruby patterns match line by line, so a second line could slip past a pattern meant for the whole value.
  def stray_line_break?(value, path = [])
    case value
    when Hash then value.any? { |key, inner| key.to_s.match?(/[\r\n]/) || stray_line_break?(inner, path + [key]) }
    when Array then value.any? { |inner| stray_line_break?(inner, path) }
    when String then value.match?(/[\r\n]/) && !prose?(path)
    else false
    end
  end

  def prose?(path) = [%w[content title], %w[content message], %w[content html]].include?(path)

  def stamp(time) = time.utc.strftime("%Y-%m-%dT%H:%M:%SZ")
end
