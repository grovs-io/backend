require "test_helper"
require_relative "../../../test/integration/auth_test_helper"

class InAppReportTest < ActionDispatch::IntegrationTest
  include AuthTestHelper
  include AuditTestHelper
  include ClickhouseTestHelper
  include InAppFixtures
  fixtures :instances, :users, :instance_roles, :projects, :visitors, :devices

  setup do
    skip_unless_clickhouse!
    truncate_clickhouse_tables
    @project = projects(:one)
    entitle!(@project.instance)
    @member = doorkeeper_headers_for(users(:member_user))
    clear_in_app_stamps(@project)
    @campaign = live_in_app_campaign(@project)
    @other = live_in_app_campaign(@project)
  end

  def event(name, visitor:, at:, platform: "ios", campaign: @campaign, project: @project, **properties)
    { project_id: project.id, event_type: "custom", event_name: name, visitor_id: visitor, platform: platform,
      created_at: at.utc.strftime("%Y-%m-%d %H:%M:%S.%L"), properties: { campaign_id: campaign.hashid }.merge(properties) }
  end

  def report(**params)
    get "#{API_PREFIX}/projects/#{@project.id}/in_app_campaigns/#{@campaign.hashid}/report", params: params, headers: @member
    response.parsed_body["report"]
  end

  test "counts views, people, clicks by button and dismissals for this campaign only" do
    day = Time.utc(2026, 9, 20, 10)
    insert_ch_events([
                       event("in_app_viewed", visitor: 1, at: day), event("in_app_viewed", visitor: 1, at: day + 1.hour),
                       event("in_app_viewed", visitor: 2, at: day + 1.day, platform: "web"),
                       event("in_app_viewed", visitor: 3, at: day + 1.day, platform: "web"),
                       event("in_app_clicked", visitor: 1, at: day + 2.minutes, button_id: "shop"),
                       event("in_app_clicked", visitor: 2, at: day + 1.day, platform: "web"),
                       event("in_app_dismissed", visitor: 3, at: day + 1.day, platform: "web", reason: "swipe"),
                       event("in_app_viewed", visitor: 9, at: day, campaign: @other),
                       event("in_app_viewed", visitor: 9, at: day, project: projects(:two)),
                       event("cart_viewed", visitor: 1, at: day),
                       event("in_app_viewed", visitor: 8, at: day - 30.days)
                     ])
    out = report(from: "2026-09-19", to: "2026-09-22")
    assert_response :ok
    assert_equal({ "views" => 4, "clicks" => 2, "dismissals" => 1, "unique_viewers" => 3, "unique_clickers" => 2, "click_rate" => 0.5 }, out["totals"])
    assert_equal [{ "bucket" => "2026-09-20", "views" => 2, "clicks" => 1, "dismissals" => 0 },
                  { "bucket" => "2026-09-21", "views" => 2, "clicks" => 1, "dismissals" => 1 }], out["trend"]
    assert_equal [{ "platform" => "ios", "views" => 2, "clicks" => 1, "dismissals" => 0 },
                  { "platform" => "web", "views" => 2, "clicks" => 1, "dismissals" => 1 }], out["platforms"]
    assert_equal [{ "button_id" => nil, "clicks" => 1 }, { "button_id" => "shop", "clicks" => 1 }], out["buttons"].sort_by { |b| b["button_id"].to_s }
    assert_nil out["eligible_devices"]
  end

  test "a message closed by turning the device is not a dismissal" do
    day = Time.utc(2026, 9, 20, 10)
    insert_ch_events([event("in_app_dismissed", visitor: 1, at: day, reason: "orientation"),
                      event("in_app_dismissed", visitor: 2, at: day, reason: "close_button")])
    out = report(from: "2026-09-20", to: "2026-09-20")
    assert_equal 1, out["totals"]["dismissals"]
    assert_equal [1, 1], [out["trend"].sum { |b| b["dismissals"] }, out["platforms"].sum { |p| p["dismissals"] }]
  end

  test "an event stored twice is counted once" do
    row = event("in_app_viewed", visitor: 1, at: Time.utc(2026, 9, 20, 10)).merge(event_id: "same")
    insert_ch_events([row])
    insert_ch_events([row])
    assert_equal 1, report(from: "2026-09-20", to: "2026-09-20")["totals"]["views"]
  end

  test "by hour, and an empty report" do
    insert_ch_events([event("in_app_viewed", visitor: 1, at: Time.utc(2026, 9, 20, 10, 30))])
    assert_equal ["2026-09-20T10:00:00Z"], report(from: "2026-09-20", to: "2026-09-20", by: "hour")["trend"].pluck("bucket")
    empty = report(from: "2026-08-01", to: "2026-08-02")
    assert_equal [0, 0.0, [], []], [empty["totals"]["views"], empty["totals"]["click_rate"], empty["trend"], empty["buttons"]]
  end

  test "a segment campaign reports how many devices may see it" do
    @campaign.update_columns(segment_key: "k")
    2.times { |i| SegmentMembership.create!(visitor_id: i + 1, segment_key: "k", project_id: @project.id, confirmed_at: Time.current) }
    assert_equal 2, report(from: "2026-09-20", to: "2026-09-20")["eligible_devices"]
  end

  test "without dates it covers the launch day to today, and at most 92 days" do
    @campaign.update_columns(launched_at: 200.days.ago)
    insert_ch_events([event("in_app_viewed", visitor: 1, at: 10.days.ago), event("in_app_viewed", visitor: 1, at: 150.days.ago)])
    assert_equal 1, report["totals"]["views"]
    assert_response :ok
  end

  test "refuses a range it cannot read" do
    [{ from: "yesterday" }, { from: "2026-09-20", to: "2026-09-01" }, { from: "2026-01-01", to: "2026-09-01" }, { by: "minute" }].each do |params|
      report(**params)
      assert_response :unprocessable_entity
    end
  end

  test "answers 503 while ClickHouse is away" do
    Clickhouse.stub(:with, ->(&) { raise Clickhouse::Unavailable, "down" }) { report(from: "2026-09-20", to: "2026-09-20") }
    assert_response :service_unavailable
  end
  test "answers are counted by value and scored; none for a campaign that asks nothing" do
    assert_nil report(from: "2026-09-19", to: "2026-09-22")["answers"]

    @campaign = live_in_app_campaign(@project, content: asking)
    day = Time.utc(2026, 9, 20, 10)
    give = ->(name, visitor, value, **more) { event(name, visitor: visitor, at: day + visitor.minutes, question_id: "q1", type: "stars", value: value, **more) }
    insert_ch_events([give.call("in_app_answered", 1, 5), give.call("in_app_answered", 2, 5), give.call("in_app_answered", 3, 2),
                      give.call("in_app_commented", 3, 2, comment: "Too slow"),
                      give.call("in_app_answered", 9, 1).merge(properties: { campaign_id: @other.hashid, value: 1 })])
    out = report(from: "2026-09-19", to: "2026-09-22")["answers"]
    assert_response :ok
    assert_equal ["stars", 3, 4.0], out.values_at("type", "count", "score")
    assert_equal [0, 1, 0, 0, 2], out["values"].pluck("count")
    assert_equal [0, 1, 0, 0, 0], out["values"].pluck("comments")
  end

  test "a list of options is counted by option, named, and has no score" do
    @campaign = live_in_app_campaign(@project, content: asking(CHOICE))
    insert_ch_events([event("in_app_answered", visitor: 1, at: Time.utc(2026, 9, 20, 10), question_id: "q1", type: "choice", value: "friend")])
    out = report(from: "2026-09-19", to: "2026-09-22")["answers"]
    assert_nil out["score"]
    assert_equal [{ "value" => "search", "label" => "Search", "count" => 0, "comments" => 0 },
                  { "value" => "friend", "label" => "A friend", "count" => 1, "comments" => 0 }], out["values"]
  end

  test "every answer can be taken out as rows, one a person, with its comment and the option's text" do
    @campaign = live_in_app_campaign(@project, content: asking(CHOICE))
    day = Time.utc(2026, 9, 20, 10)
    give = ->(name, visitor, value, at, **more) { event(name, visitor: visitor, at: at, question_id: "q1", type: "choice", value: value, **more) }
    insert_ch_events([give.call("in_app_answered", 1, "friend", day).merge(sdk_identifier: "ana", country: "RO", app_version: "2.1.0"),
                      give.call("in_app_commented", 1, "friend", day + 20.seconds, comment: "My sister uses it"),
                      give.call("in_app_answered", 2, "search", day + 1.hour, platform: "web"),
                      give.call("in_app_viewed", 3, "search", day),
                      give.call("in_app_answered", 9, "search", day - 40.days)])
    get "#{API_PREFIX}/projects/#{@project.id}/in_app_campaigns/#{@campaign.hashid}/answers", params: { from: "2026-09-19", to: "2026-09-22" },
                                                                                          headers: @member
    assert_response :ok
    out = response.parsed_body["answers"]
    assert_equal ["choice", false], out.values_at("type", "truncated")
    assert_equal [{ "at" => "2026-09-20T11:00:00Z", "platform" => "web", "country" => "", "app_version" => "", "comment" => "",
                    "answer" => "search", "label" => "Search", "user" => nil },
                  { "at" => "2026-09-20T10:00:00Z", "platform" => "ios", "country" => "RO", "app_version" => "2.1.0",
                    "comment" => "My sister uses it", "answer" => "friend", "label" => "A friend", "user" => "ana" }], out["rows"]
  end

  test "a campaign that asks nothing has no answers to take out" do
    get "#{API_PREFIX}/projects/#{@project.id}/in_app_campaigns/#{@campaign.hashid}/answers", headers: @member
    assert_response :unprocessable_entity
  end

  test "comments come a page at a time, newest first, to the very last, and can be narrowed to some answers" do
    @campaign = live_in_app_campaign(@project, content: asking)
    day = Time.utc(2026, 9, 20, 10)
    rows = (1..60).map do |i|
      event("in_app_commented", visitor: i, at: day + i.minutes, question_id: "q1", type: "stars", value: (i % 5) + 1, comment: "Comment #{i}")
        .merge(event_id: "e#{i.to_s.rjust(3, '0')}")
    end
    insert_ch_events(rows + [event("in_app_commented", visitor: 99, at: day, campaign: @other, value: 1, comment: "Not mine")])
    url = "#{API_PREFIX}/projects/#{@project.id}/in_app_campaigns/#{@campaign.hashid}/comments"
    ask = lambda do |**params|
      get url, params: { from: "2026-09-19", to: "2026-09-22" }.merge(params), headers: @member
      assert_response :ok
      response.parsed_body
    end

    seen = []
    cursor = nil
    3.times do
      page = ask.call(**{ before: cursor }.compact)
      seen.concat(page["comments"].pluck("comment"))
      cursor = page["next_before"]
    end
    assert_nil cursor
    assert_equal (1..60).map { |i| "Comment #{i}" }.reverse, seen

    low = ask.call(values: "1,2")
    assert_equal %w[1 2], low["comments"].pluck("value").uniq.sort
    assert_equal 24, low["comments"].size
    assert_nil low["next_before"]

    get url, params: { before: "not a cursor" }, headers: @member
    assert_response :unprocessable_entity
  end

  test "an option removed after launch keeps its row, so the counts add up" do
    @campaign = live_in_app_campaign(@project, content: asking(CHOICE))
    day = Time.utc(2026, 9, 20, 10)
    insert_ch_events([event("in_app_answered", visitor: 1, at: day, question_id: "q1", type: "choice", value: "friend"),
                      event("in_app_answered", visitor: 2, at: day, question_id: "q1", type: "choice", value: "gone"),
                      event("in_app_commented", visitor: 2, at: day + 1.minute, question_id: "q1", type: "choice", value: "gone", comment: "Hm")])
    out = report(from: "2026-09-19", to: "2026-09-22")["answers"]
    assert_equal 2, out["count"]
    assert_equal [["search", 0, 0], ["friend", 1, 0], ["gone", 1, 1]], out["values"].map { |v| v.values_at("value", "count", "comments") }
    assert_equal "gone", out["values"].last["label"]
  end

end
