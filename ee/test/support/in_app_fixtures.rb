require_relative "push_campaign_fixtures"

module InAppFixtures
  CONTENT = { "title" => "Hello", "message" => "Welcome" }.freeze
  TRIGGERS = [{ "type" => "event", "name" => "cart_viewed" }].freeze
  SEGMENT_DEFINITION = PushCampaignFixtures::SEGMENT_DEFINITION

  def in_app_campaign(project, **attrs)
    InAppCampaign.create!({ project: project, name: "Welcome", content: CONTENT.dup, triggers: TRIGGERS.map(&:dup) }.merge(attrs))
  end

  def live_in_app_campaign(project, **attrs)
    campaign = in_app_campaign(project, **attrs)
    campaign.launch!
    campaign
  end

  # Stamps are keyed by database ids, which repeat from run to run, so they are cleared after a test as well as before.
  def self.included(base)
    base.teardown { clear_in_app_stamps } if base.respond_to?(:teardown)
  end

  def clear_in_app_stamps(*projects)
    REDIS.with { |conn| conn.keys("in_app:*").each { |key| conn.del(key) } }
    projects.each { |project| Rails.cache.delete_matched("in_app:served:#{project.id}:*") }
  end
  STARS = { "id" => "q1", "type" => "stars", "options" => [], "comment" => { "split" => 3, "low" => "What went wrong?", "high" => nil },
            "thanks" => "Thank you", "review_from" => 4 }.freeze
  CHOICE = { "id" => "q1", "type" => "choice", "options" => [{ "id" => "search", "text" => "Search" }, { "id" => "friend", "text" => "A friend" }],
             "comment" => nil, "thanks" => nil, "review_from" => nil }.freeze

  def asking(question = STARS, **content) = CONTENT.merge("question" => question.deep_dup).merge(content.stringify_keys)

end
