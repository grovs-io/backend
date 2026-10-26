require "test_helper"
require "json-schema"

class InAppDefinitionSchemaTest < ActiveSupport::TestCase
  SCHEMA = JSON.parse(File.read(File.expand_path("../../../config/in_app/definition.schema.json", __dir__)))
  BASE = {
    "format" => 1, "id" => "c1", "revision" => 1, "created_at" => "2026-09-01T00:00:00Z", "priority" => 1, "template" => "interstitial",
    "content" => { "title" => "Hello", "message" => "Welcome", "image" => { "portrait" => nil, "landscape" => nil }, "colors" => {},
                   "close_button" => true, "backdrop" => "dim", "buttons" => [], "tap_action" => nil },
    "triggers" => [{ "type" => "event", "name" => "cart_viewed" }],
    "conditions" => [],
    "caps" => { "session" => nil, "day" => nil, "week" => nil, "lifetime" => nil, "ignore_global" => false },
    "schedule" => { "start_at" => "2026-09-01T00:00:00Z", "end_at" => nil, "days" => nil, "from" => nil, "to" => nil },
    "delay_seconds" => 0, "delivery_mode" => "device", "variants" => nil, "control_group" => nil, "conversion" => nil
  }.freeze

  def base = BASE
  def with(changes) = BASE.deep_merge(changes)
  def errors_for(definition) = JSON::Validator.fully_validate(SCHEMA, definition)

  test "the base campaign is valid" do
    assert_empty errors_for(base)
  end

  test "a delay, a store action and a message that must be answered are valid" do
    button = { "id" => "b1", "text" => "Update", "action" => { "type" => "open_store" } }
    assert_empty errors_for(with("delay_seconds" => 3600, "content" => { "dismissible" => false, "buttons" => [button] }))
    assert_empty errors_for(with("content" => { "dismissible" => false, "tap_action" => { "type" => "close" } }))
    assert_empty errors_for(with("content" => { "dismissible" => true }))
  end

  test "a full campaign is valid" do
    full = with(
      "priority" => 10, "template" => "cover",
      "content" => {
        "image" => { "portrait" => "https://cdn.example/a1.png", "landscape" => "https://cdn.example/a2.png" },
        "colors" => { "background" => "#FFFFFF", "title" => "#111111", "message" => "#444444AA" },
        "buttons" => [
          { "id" => "b1", "text" => "Shop", "action" => { "type" => "open_url", "url" => "https://acme.example/sale" },
            "colors" => { "background" => "#2A86FF", "text" => "#FFFFFF" } },
          { "id" => "b2", "text" => "Later", "action" => { "type" => "key_value", "payload" => { "screen" => "offers" } } }
        ],
        "tap_action" => { "type" => "open_url", "url" => "acme://product/{{ event.product }}?ref={{ user.plan }}" }
      },
      "triggers" => [{ "type" => "event", "name" => "cart_viewed", "filters" => [{ "field" => "total", "op" => "between", "value" => [10, 50] }] },
                     { "type" => "screen_view" }, { "type" => "app_open" }],
      "conditions" => [{ "type" => "user_attribute", "key" => "plan", "op" => "is_set" },
                       { "type" => "first_seen", "op" => "within_days", "value" => 7 }],
      "caps" => { "session" => 1, "day" => 20, "week" => 20, "lifetime" => 500, "ignore_global" => true },
      "schedule" => { "end_at" => "2026-10-05T00:00:00.000Z", "days" => [1, 7], "from" => "09:00", "to" => "21:30" }
    )
    assert_empty errors_for(full)
  end

  INVALID = {
    "a format other than 1" => { "format" => 2 },
    "a priority above 10" => { "priority" => 11 },
    "a priority below 1" => { "priority" => 0 },
    "an unknown template" => { "template" => "carousel" },
    "an unknown top-level field" => { "colour" => "red" },
    "no triggers" => { "triggers" => [] },
    "six triggers" => { "triggers" => Array.new(6) { { "type" => "app_open" } } },
    "an unknown trigger type" => { "triggers" => [{ "type" => "shake" }] },
    "six filters on a trigger" => { "triggers" => [{ "type" => "event", "name" => "a", "filters" => Array.new(6) { { "field" => "v", "op" => "is_set" } } }] },
    "an unknown filter operator" => { "triggers" => [{ "type" => "event", "name" => "a", "filters" => [{ "field" => "v", "op" => "like", "value" => 1 }] }] },
    "eleven conditions" => { "conditions" => Array.new(11) { { "type" => "platform", "op" => "eq", "value" => "ios" } } },
    "an unknown condition type" => { "conditions" => [{ "type" => "weather", "op" => "eq", "value" => "sunny" }] },
    "three buttons" => { "content" => { "buttons" => Array.new(3) { |i| { "id" => "b#{i}", "text" => "x", "action" => { "type" => "close" } } } } },
    "an unknown action" => { "content" => { "tap_action" => { "type" => "run_script" } } },
    "an image that is not https" => { "content" => { "image" => { "portrait" => "http://cdn.example/a.png", "landscape" => nil } } },
    "a colour that is not hex" => { "content" => { "colors" => { "title" => "red" } } },
    "a day cap above 20" => { "caps" => { "day" => 21 } },
    "a week cap above 20" => { "caps" => { "week" => 21 } },
    "a cap of zero" => { "caps" => { "session" => 0 } },
    "a weekday of 8" => { "schedule" => { "days" => [8] } },
    "an hour of 24" => { "schedule" => { "from" => "24:00", "to" => "06:00" } },
    "a start time without a zone" => { "schedule" => { "start_at" => "2026-10-01T00:00:00" } },
    "a negative delay" => { "delay_seconds" => -1 },
    "a delay of more than an hour" => { "delay_seconds" => 3601 },
    "a message nobody can dismiss and nothing to tap" => { "content" => { "dismissible" => false } },
    "dismissible that is not yes or no" => { "content" => { "dismissible" => "no" } },
    "a store action with a link of its own" => { "content" => { "tap_action" => { "type" => "open_store", "url" => "https://a.example" } } },
    "an unknown delivery mode" => { "delivery_mode" => "server" },
    "variants before experimentation exists" => { "variants" => [] },
    "a control group before experimentation exists" => { "control_group" => {} },
    "a conversion goal before experimentation exists" => { "conversion" => {} },
    "a link with a script scheme" => { "content" => { "tap_action" => { "type" => "open_url", "url" => "JavaScript:alert(1)" } } },
    "a link with a data scheme" => { "content" => { "tap_action" => { "type" => "open_url", "url" => "data:text/html,hi" } } },
    "a link with a file scheme" => { "content" => { "tap_action" => { "type" => "open_url", "url" => "file:///etc/hosts" } } },
    "a link with a blob scheme" => { "content" => { "tap_action" => { "type" => "open_url", "url" => "BLOB:https://acme.example/1" } } },
    "a link with no scheme" => { "content" => { "tap_action" => { "type" => "open_url", "url" => "acme.example/path" } } },
    "a link with a field as its scheme" => { "content" => { "tap_action" => { "type" => "open_url", "url" => "{{ event.scheme }}://acme.example" } } },
    "a link with a field in its host" => { "content" => { "tap_action" => { "type" => "open_url", "url" => "https://{{ event.host }}/path" } } },
    "an alert with an image" => { "template" => "alert", "content" => { "image" => { "portrait" => "https://cdn.example/a.png" } } },
    "an image template with no image" => { "template" => "cover_image", "content" => { "title" => nil, "message" => nil } },
    "an image template with a title" => { "template" => "cover_image",
                                         "content" => { "message" => nil, "image" => { "portrait" => "https://cdn.example/a.png" } } },
    "an image template with a button" => { "template" => "interstitial_image",
                                          "content" => { "title" => nil, "message" => nil, "image" => { "portrait" => "https://cdn.example/a.png" },
                                                         "buttons" => [{ "id" => "b1", "text" => "x", "action" => { "type" => "close" } }] } },
    "html content on a non-html template" => { "content" => { "html" => "<p>hi</p>" } },
    "a layout on a non-html template" => { "content" => { "layout" => "modal" } }
  }.freeze

  INVALID.each do |name, changes|
    test "rejects #{name}" do
      assert_not_empty errors_for(with(changes))
    end
  end

  test "an image template with only an image and a tap action is valid" do
    image = with("template" => "half_interstitial_image",
                 "content" => { "title" => nil, "message" => nil, "image" => { "portrait" => "https://cdn.example/a.png" },
                                "tap_action" => { "type" => "open_url", "url" => "https://acme.example/sale" } })
    assert_empty errors_for(image)
  end

  test "an alert with text, buttons and no image is valid" do
    alert = with("template" => "alert", "content" => { "buttons" => [{ "id" => "ok", "text" => "OK", "action" => { "type" => "close" } }] })
    assert_empty errors_for(alert)
  end

  test "an html campaign with html and a layout is valid" do
    html = with("template" => "html", "content" => { "html" => "<div>Hi</div>", "layout" => "modal" })
    assert_empty errors_for(html)
  end

  test "an html campaign rejects an unknown layout" do
    bad = with("template" => "html", "content" => { "html" => "<div>Hi</div>", "layout" => "fullscreen" })
    assert_not_empty errors_for(bad)
  end

  test "an html campaign rejects missing html" do
    bad = with("template" => "html", "content" => { "layout" => "modal" })
    assert_not_empty errors_for(bad)
  end

  test "an html campaign rejects missing layout" do
    bad = with("template" => "html", "content" => { "html" => "<div>Hi</div>" })
    assert_not_empty errors_for(bad)
  end

  test "rejects a campaign missing a required field" do
    SCHEMA.fetch("required").each do |field|
      assert_not_empty errors_for(base.except(field)), "accepted a campaign without #{field}"
    end
  end
end
