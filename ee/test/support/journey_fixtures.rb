module JourneyFixtures
  ADD_TO_CART = { "type" => "event", "event" => { "name" => "add_to_cart" }, "segment_id" => nil, "audience_segment_id" => nil }.freeze
  PUSH = { "title" => "Come back", "body" => "Your cart misses you" }.freeze
  IN_APP = { "template" => "interstitial", "content" => { "title" => "Hello", "message" => "10% off" },
             "triggers" => [{ "type" => "app_open" }], "caps" => {}, "valid_days" => 7 }.freeze

  def self.included(base)
    base.teardown { REDIS.with { |conn| conn.keys("journeys:*").each { |key| conn.del(key) } } } if base.respond_to?(:teardown)
  end

  def step(id, type, **attrs)
    defaults = { "push" => PUSH, "in_app" => IN_APP, "wait" => { "minutes" => 60 } }.fetch(type, {})
    { "id" => id, "type" => type }.merge(type == "split" ? {} : { "next" => nil }).merge(defaults.deep_dup).merge(attrs.deep_stringify_keys)
  end

  def map(*steps) = steps.index_by { |s| s["id"] }

  def journey(project, steps: map(step("s1", "push")), **attrs)
    Journey.create!({ project: project, name: "Cart recovery", entry: ADD_TO_CART.deep_dup, first_step: steps.keys.first, steps: steps }.merge(attrs))
  end

  def live_journey(project, **attrs)
    j = journey(project, **attrs)
    assert j.launch!, "launched"
    j.reload
  end

  def person(visitor) = visitor.sdk_identifier.present? ? "i:#{visitor.sdk_identifier}" : "v:#{visitor.id}"

  def seen(visitor, name, at: Time.current, screen: nil, received: nil, **properties)
    row = [visitor.id, person(visitor), name, screen, properties.stringify_keys, (at.to_f * 1000).to_i]
    received ? row << (received.to_f * 1000).to_i : row
  end

  def signal(project, *rows) = Journeys::Signals.new(project, rows).call

  def row_of(journey, visitor) = JourneyPerson.find_by(journey_id: journey.id, person_key: person(visitor))

  # Runs every due step at a given time, as the step jobs would.
  def step_all(journey, at: 1.second.from_now)
    travel_to(at) { Journeys::Stepper.new(journey.reload).run }
  end

  def counts(journey)
    sql = "SELECT step_id, branch, SUM(people) FROM journey_counts WHERE journey_id = #{journey.id} GROUP BY 1, 2"
    JourneyPerson.connection.select_rows(sql).to_h { |step_id, branch, n| [[step_id, branch], n.to_i] }
  end
end
