# The three events a device raises for a message; a host app can forge them, so each is checked.
module InAppEventCheck
  VIEWED = "in_app_viewed".freeze
  CLICKED = "in_app_clicked".freeze
  ANSWERED = "in_app_answered".freeze
  COMMENTED = "in_app_commented".freeze
  COMMENT_MAX = 1_000
  FROM_DEVICES = [VIEWED, CLICKED, "in_app_dismissed", ANSWERED, COMMENTED].freeze

  module_function

  def accept(project:, visitor:, name:, properties:, event_id:)
    return refuse("switched_off") unless Grovs.in_app_enabled? && project.instance.in_app_enabled?
    return refuse("server_only") unless FROM_DEVICES.include?(name)

    campaign = project.in_app_campaigns.find_by_hashid(properties.to_h["campaign_id"].to_s)
    return refuse("unknown_campaign") if campaign.nil? || campaign.launched_at.nil?
    return refuse("unknown_button") if name == CLICKED && !button?(campaign, properties.to_h)
    return refuse("bad_answer") if [ANSWERED, COMMENTED].include?(name) && !answer?(campaign, name, properties.to_h)
    # One answer a person: a second device, or a forged batch, cannot move the score.
    return refuse("already_answered") if name == ANSWERED && !InAppViews.answered(campaign: campaign, visitor: visitor)
    return refuse("no_answer") if name == COMMENTED && !InAppViews.answered?(campaign: campaign, visitor: visitor)

    InAppViews.record(campaign: campaign, visitor: visitor, event_id: event_id) if name == VIEWED
    true
  rescue Hashids::InputError
    refuse("unknown_campaign")
  end

  BUTTON_ID = /\A[A-Za-z0-9_-]{1,64}\z/

  # No id is a tap on the message itself. A device on an older revision may name a button since renamed.
  def button?(campaign, properties)
    id = properties["button_id"]
    return true if id.blank? || campaign.contents.any? { |content| Array(content["buttons"]).any? { |button| button["id"] == id } }

    properties["revision"].is_a?(Integer) && properties["revision"] < campaign.revision && id.to_s.match?(BUTTON_ID)
  end

  STARS = (1..5)

  # Checked against the question as it is now, in any variant; an older revision may name an option since removed.
  def answer?(campaign, name, properties)
    questions = campaign.contents.filter_map { |content| content["question"] if content["question"].is_a?(Hash) }
    questions.any? { |question| value?(campaign, question, properties) && (name == ANSWERED || comment?(question, properties["comment"])) }
  end

  def comment?(question, comment)
    question["comment"].is_a?(Hash) && comment.is_a?(String) && comment.strip.present? && comment.size <= COMMENT_MAX
  end

  def value?(campaign, question, properties)
    value = properties["value"]
    return value.is_a?(Integer) && STARS.cover?(value) if question["type"] == "stars"
    return true if question["options"].any? { |option| option["id"] == value }

    properties["revision"].is_a?(Integer) && properties["revision"] < campaign.revision && value.to_s.match?(BUTTON_ID)
  end

  def refuse(reason)
    Grovs::Metrics.increment("in_app.event_refused", tags: { reason: reason })
    false
  end
end
