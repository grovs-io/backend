require "test_helper"

class InAppDefinitionReportAndImagesTest < ActiveSupport::TestCase
  include InAppFixtures
  fixtures :instances, :projects, :visitors, :devices

  setup do
    @project = projects(:one)
    clear_in_app_stamps(@project)
  end

  def definition = in_app_campaign(@project).definition
  def html(markup) = in_app_campaign(@project, template: "html", content: { "html" => markup, "layout" => "modal" }).definition

  test "values under a minimum and missing fields are explained in words, naming the field" do
    d = definition
    assert_equal ["The priority must be 1 or more"], InAppDefinition.problems(d.merge("priority" => 0))
    assert_equal ["The delay must be 0 or more"], InAppDefinition.problems(d.merge("delay_seconds" => -1))
    assert_equal ["The limit per session must be 1 or more"], InAppDefinition.problems(d.merge("caps" => d["caps"].merge("session" => 0)))
    assert_equal ["The message is missing its title"], InAppDefinition.problems(d.merge("content" => d["content"].except("title")))
    nameless = d["content"].merge("buttons" => [{ "text" => "Go", "action" => "close" }])
    assert_includes InAppDefinition.problems(d.merge("content" => nameless)), "Button 1 is missing its id"
  end

  test "a list over its maximum names the limit instead of saying the field is not valid" do
    d = definition
    assert_equal ["The triggers can be at most 5"], InAppDefinition.problems(d.merge("triggers" => d["triggers"] * 6))
  end

  test "a srcset candidate list separated by a bare comma is read candidate by candidate" do
    assert_includes InAppDefinition.problems(html('<img src="https://cdn.example/a.png" srcset="https://cdn.example/a.png, http://cdn.example/b.png">')),
                    "The HTML loads a resource that is not allowed"
    assert_empty InAppDefinition.problems(html('<img src="https://cdn.example/a.png" srcset="https://cdn.example/a.png,, https://cdn.example/b.png">'))
  end

  test "removing a picture empties that slot in every variant too, and leaves the other slot and plain variants alone" do
    picture = { "portrait" => "https://img.example/p.png", "landscape" => "https://img.example/l.png" }
    campaign = in_app_campaign(@project, content: CONTENT.merge("image" => picture),
                                         variants: [{ "id" => "b", "content" => CONTENT.merge("title" => "B", "image" => picture) },
                                                    { "id" => "c", "content" => CONTENT.merge("title" => "C") }])
    assert campaign.remove_image("portrait")
    campaign.reload
    assert_equal({ "portrait" => nil, "landscape" => picture["landscape"] }, campaign.content["image"])
    assert_equal({ "portrait" => nil, "landscape" => picture["landscape"] }, campaign.variants[0]["content"]["image"])
    assert_equal CONTENT.merge("title" => "C"), campaign.variants[1]["content"]
  end

  test "an in-app report turns a ClickHouse outage into Unavailable and lets a broken query surface" do
    campaign = live_in_app_campaign(@project)
    read = ->(error) { Clickhouse.stub(:with, ->(*) { raise error }) { InAppReport.call(campaign, from: Date.current.iso8601, to: Date.current.iso8601) } }
    assert_raises(Clickhouse::Unavailable) { read.call(ClickHouse::Client::DatabaseError.new("Code: 209. DB::Exception: Socket timeout")) }
    assert_raises(Clickhouse::Unavailable) { read.call(Errno::ECONNRESET.new) }
    broken = ClickHouse::Client::DatabaseError.new("Code: 47. DB::Exception: Unknown identifier: properties.x")
    assert_same broken, assert_raises(ClickHouse::Client::DatabaseError) { read.call(broken) }
  end
end
