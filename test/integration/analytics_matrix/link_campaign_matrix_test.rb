# frozen_string_literal: true

require "test_helper"
require_relative "../auth_test_helper"
require_relative "scenario_dsl"

# Link/campaign/visitor stats add up: link stats per link, campaign == sum of
# links, no leak. Oracle is an in-memory tally from the test's OWN link→campaign
# map (never CampaignStatisticsQuery).
class LinkCampaignMatrixTest < ActionDispatch::IntegrationTest
  include AuthTestHelper
  include ClickhouseTestHelper
  include AnalyticsMatrix::ScenarioDSL

  fixtures :instances, :users, :instance_roles, :projects, :devices, :visitors,
           :domains, :redirect_configs

  # event type -> stat column. user_referred absent: it has link_id nil, so it's
  # visitor-side only (asserted separately).
  TYPE_METRIC = {
    "view" => :views, "open" => :opens, "install" => :installs,
    "app_open" => :app_opens, "reactivation" => :reactivations
  }.freeze

  setup do
    matrix_setup!
    @project = projects(:one)
    @domain  = domains(:one)
    @redirect = redirect_configs(:one)
    @date = Date.current
    @project2 = projects(:two)
    [Event, LinkDailyStatistic, VisitorDailyStatistic].each do |m|
      m.where(project_id: [@project.id, @project2.id]).delete_all
    end

    @headers = doorkeeper_headers_for(users(:admin_user)) # dashboard API auth

    @campaign_a = Campaign.create!(project: @project, name: "Campaign A", archived: false)
    @campaign_b = Campaign.create!(project: @project, name: "Campaign B", archived: false)
    @link_a1 = build_link("lc-a1", campaign: @campaign_a, tracking: true)
    @link_a2 = build_link("lc-a2", campaign: @campaign_a)
    @link_b1 = build_link("lc-b1", campaign: @campaign_b)
    @plain   = build_link("lc-plain", campaign: nil)
  end

  teardown { matrix_teardown! }

  def build_link(path, campaign:, tracking: false)
    attrs = {
      domain: @domain, redirect_config: @redirect, campaign: campaign, path: path,
      title: path, generated_from_platform: "ios", active: true, sdk_generated: false, data: "[]"
    }
    if tracking
      attrs.merge!(tracking_source: "email", tracking_medium: "newsletter", tracking_campaign: "spring")
    end
    Link.create!(attrs)
  end

  def fresh_device(platform = "ios")
    device = Device.create!(
      user_agent: "lc", ip: "1.1.1.1", remote_ip: "2.2.2.2",
      platform: platform, vendor: "lc-#{SecureRandom.hex(6)}"
    )
    Visitor.create!(
      project: @project, device: device, web_visitor: false,
      sdk_identifier: "lc-#{SecureRandom.hex(4)}", uuid: SecureRandom.uuid
    )
    device
  end

  def raw_for(device:, link:, type:, project: nil, session: nil, engagement: nil)
    {
      type: type, project_id: (project || @project).id, device_id: device.id,
      link_id: link&.id, data: nil, engagement_time: engagement,
      created_at: Time.current.utc.iso8601(3), event_name: "",
      session_id: session || "lc-#{SecureRandom.hex(6)}", tags: []
    }.to_json
  end

  # Each event on a fresh device+visitor so VIEW dedup (per project+device) can't
  # collapse counts.
  def raw_event(link:, type:, platform: "ios", project: nil, session: nil)
    raw_for(device: fresh_device(platform), link: link, type: type, project: project, session: session)
  end

  # Ingest the standard matrix; returns the independent oracle:
  #   { links: { link_id => {views:, opens:, ...} }, campaigns: { campaign_id => {...} } }
  def ingest_matrix
    plan = {
      @link_a1 => { "view" => 3, "open" => 2, "install" => 1 },
      @link_a2 => { "view" => 1, "open" => 1 },
      @link_b1 => { "view" => 2, "install" => 1 },
      @plain   => { "view" => 2, "open" => 1 }
    }
    links = Hash.new { |h, k| h[k] = Hash.new(0) }
    campaigns = Hash.new { |h, k| h[k] = Hash.new(0) }
    raws = []
    plan.each do |link, counts|
      counts.each do |type, n|
        n.times { raws << raw_event(link: link, type: type) }
        links[link.id][TYPE_METRIC[type]] += n
        campaigns[link.campaign_id][TYPE_METRIC[type]] += n if link.campaign_id
      end
    end
    ingest_via_process_batch(raws.shuffle(random: Random.new(6)), chunk: 500)
    { links: links, campaigns: campaigns }
  end

  test "PG LinkDailyStatistic reconciles per link" do
    oracle = ingest_matrix[:links]

    oracle.each do |link_id, metrics|
      rows = LinkDailyStatistic.where(project_id: @project.id, link_id: link_id)
      metrics.each do |col, expected|
        assert_equal expected, rows.sum(col), "link #{link_id} #{col}"
      end
    end
  end

  test "campaign totals equal the sum of their links (CampaignStatisticsQuery)" do
    oracle = ingest_matrix[:campaigns]
    rows = CampaignStatisticsQuery.new(project: @project, params: { start_date: @date, end_date: @date }).call
    by_id = rows.index_by(&:id)

    assert_equal oracle[@campaign_a.id][:views],    by_id[@campaign_a.id].total_views.to_i
    assert_equal oracle[@campaign_a.id][:opens],    by_id[@campaign_a.id].total_opens.to_i
    assert_equal oracle[@campaign_a.id][:installs], by_id[@campaign_a.id].total_installs.to_i
    assert_equal oracle[@campaign_b.id][:views],    by_id[@campaign_b.id].total_views.to_i
    assert_equal oracle[@campaign_b.id][:installs], by_id[@campaign_b.id].total_installs.to_i
    # plain_link (no campaign) must NOT inflate any campaign: campaign_a == a1+a2 exactly.
    assert_equal 4, by_id[@campaign_a.id].total_views.to_i
  end

  test "LinkStatisticsQuery campaign_id filter returns only that campaign's links" do
    ingest_matrix
    all_paths = LinkStatisticsQuery.new(
      project: @project, params: { start_date: @date, end_date: @date, all: true }
    ).call[:links].map { |l| l["path"] || l[:path] }
    assert_includes all_paths, @plain.path, "unfiltered list includes the non-campaign link"

    filtered = LinkStatisticsQuery.new(
      project: @project, campaign_id: @campaign_a.id,
      params: { start_date: @date, end_date: @date, all: true }
    ).call[:links].map { |l| l["path"] || l[:path] }
    assert_equal [@link_a1.path, @link_a2.path].sort, filtered.sort
  end

  test "CH link_daily reconciles event counts per link and type" do
    metric_type = TYPE_METRIC.invert
    oracle = ingest_matrix[:links]

    oracle.each do |link_id, metrics|
      rows = Clickhouse.with do |c|
        c.select_all("SELECT event_type, sum(cnt) AS n FROM link_daily " \
                     "WHERE project_id = #{@project.id} AND link_id = #{link_id} GROUP BY event_type").to_a
      end
      ch = rows.to_h { |r| [r["event_type"], r["n"].to_i] }
      metrics.each do |col, expected|
        assert_equal expected, ch[metric_type[col]].to_i, "CH link_daily link #{link_id} #{col}"
      end
    end
  end

  test "CH events carry link/campaign attribution fields" do
    ingest_via_process_batch([raw_event(link: @link_a1, type: "open", session: "attr-1")])

    row = ch_query("events", @project.id, extra_where: "session_id = 'attr-1'").first
    assert_not_nil row
    assert_equal @link_a1.id,     row["link_id"].to_i
    assert_equal @campaign_a.id,  row["campaign_id"].to_i
    assert_equal "email",         row["tracking_source"]
    assert_equal "newsletter",    row["tracking_medium"]
    assert_equal "spring",        row["tracking_campaign"]
  end

  test "organic (no-link) events do not touch link or campaign stats" do
    ingest_via_process_batch(Array.new(3) { raw_event(link: nil, type: "view") })

    assert_equal 0, LinkDailyStatistic.where(project_id: @project.id).count, "no link_daily rows"
    assert_empty ch_query("link_daily", @project.id), "MV excludes link_id=0"
    rows = CampaignStatisticsQuery.new(project: @project, params: { start_date: @date, end_date: @date }).call
    rows.each { |r| assert_equal 0, r.total_views.to_i, "campaign #{r.id} untouched by organic" }
    # the events still landed at project level
    assert_equal 3, ch_event_count(@project.id, event_type: "view")
  end

  test "user_referred credits the referrer's visitor stats, never link stats" do
    referrer_device = fresh_device
    referrer = Visitor.find_by!(project_id: @project.id, device_id: referrer_device.id)
    inviter_link = build_link("lc-inviter", campaign: nil)
    inviter_link.update!(visitor: referrer)
    installer_device = fresh_device

    ingest_via_process_batch([raw_for(device: installer_device, link: inviter_link, type: "install")])

    referred = VisitorDailyStatistic.where(project_id: @project.id, visitor_id: referrer.id).sum(:user_referred)
    assert_equal 1, referred, "referrer's visitor stats credited"
    assert_equal 0, LinkDailyStatistic.where(project_id: @project.id).sum(:user_referred),
                 "derived user_referred has link_id nil — never touches link stats"
  end

  test "VisitorDailyStatistic reconciles per visitor" do
    device = fresh_device
    visitor = Visitor.find_by!(project_id: @project.id, device_id: device.id)
    # non-VIEW events on one visitor (no dedup): 2 open, 1 install, 1 app_open
    raws = [
      raw_for(device: device, link: nil, type: "open"),
      raw_for(device: device, link: nil, type: "open"),
      raw_for(device: device, link: nil, type: "install"),
      raw_for(device: device, link: nil, type: "app_open")
    ]
    ingest_via_process_batch(raws)

    rows = VisitorDailyStatistic.where(project_id: @project.id, visitor_id: visitor.id)
    assert_equal 2, rows.sum(:opens)
    assert_equal 1, rows.sum(:installs)
    assert_equal 1, rows.sum(:app_opens)
  end

  test "link and campaign stats are isolated per project" do
    # project one: campaign_a / link_a1 gets 2 opens
    ingest_via_process_batch([
      raw_event(link: @link_a1, type: "open"), raw_event(link: @link_a1, type: "open")
    ])

    # project two: its own campaign + link + 5 opens (one p2 visitor; opens don't dedup)
    p2_campaign = Campaign.create!(project: @project2, name: "P2 Campaign", archived: false)
    p2_link = Link.create!(
      domain: domains(:two), redirect_config: @redirect, campaign: p2_campaign, path: "lc-p2",
      title: "p2", generated_from_platform: "ios", active: true, sdk_generated: false, data: "[]"
    )
    p2_device = Device.create!(user_agent: "lc", ip: "9.9.9.9", remote_ip: "9.9.9.9",
                               platform: "ios", vendor: "lc-p2-#{SecureRandom.hex(6)}")
    Visitor.create!(project: @project2, device: p2_device, web_visitor: false,
                    sdk_identifier: "lc-p2", uuid: SecureRandom.uuid)
    ingest_via_process_batch(Array.new(5) { raw_for(device: p2_device, link: p2_link, type: "open", project: @project2) })

    p1 = CampaignStatisticsQuery.new(project: @project, params: { start_date: @date, end_date: @date }).call.index_by(&:id)
    p2 = CampaignStatisticsQuery.new(project: @project2, params: { start_date: @date, end_date: @date }).call.index_by(&:id)

    assert_equal 2, p1[@campaign_a.id].total_opens.to_i, "p1 sees only its own opens"
    refute_includes p1.keys, p2_campaign.id, "p2's campaign must not appear in p1's results"
    assert_equal 5, p2[p2_campaign.id].total_opens.to_i, "p2 keeps its own opens"
    refute_includes p2.keys, @campaign_a.id, "p1's campaign must not appear in p2's results"
  end

  # Adversarial: a project-ONE event that references a project-TWO link. The
  # LinkDailyStatistic row is keyed to project one (the event's project), so
  # project two's campaign total must NOT include it.
  test "an event referencing another project's link does not leak into that project's campaign" do
    p2_campaign = Campaign.create!(project: @project2, name: "P2 Campaign", archived: false)
    p2_link = Link.create!(
      domain: domains(:two), redirect_config: @redirect, campaign: p2_campaign, path: "lc-foreign",
      title: "f", generated_from_platform: "ios", active: true, sdk_generated: false, data: "[]"
    )
    p2_device = Device.create!(user_agent: "lc", ip: "9.9.9.9", remote_ip: "9.9.9.9",
                               platform: "ios", vendor: "lc-f-#{SecureRandom.hex(6)}")
    Visitor.create!(project: @project2, device: p2_device, web_visitor: false,
                    sdk_identifier: "lc-f", uuid: SecureRandom.uuid)
    ingest_via_process_batch(Array.new(5) { raw_for(device: p2_device, link: p2_link, type: "open", project: @project2) })

    # the adversarial project-one event on the foreign link
    ingest_via_process_batch([raw_event(link: p2_link, type: "open", project: @project)])

    p2_opens = CampaignStatisticsQuery.new(project: @project2, params: { start_date: @date, end_date: @date })
                                      .call.find { |c| c.id == p2_campaign.id }.total_opens.to_i
    assert_equal 5, p2_opens, "a foreign project-one event must not leak into p2's campaign total"
  end

  # Same project-scope fix, but on LinkStatisticsQuery directly: a project-TWO
  # event referencing project one's link_a1 creates a (project=2, link_a1)
  # LinkDailyStatistic row. LinkStatisticsQuery(project one) must NOT sum it.
  # (BaseSerializer passes through the SQL-selected total_* columns, so the
  # dashboard totals are observable here.)
  test "LinkStatisticsQuery totals are project-scoped against a foreign event" do
    ingest_via_process_batch([
      raw_event(link: @link_a1, type: "open"), raw_event(link: @link_a1, type: "open")
    ])
    p2_device = Device.create!(user_agent: "lc", ip: "9.9.9.9", remote_ip: "9.9.9.9",
                               platform: "ios", vendor: "lc-fl-#{SecureRandom.hex(6)}")
    Visitor.create!(project: @project2, device: p2_device, web_visitor: false,
                    sdk_identifier: "lc-fl", uuid: SecureRandom.uuid)
    ingest_via_process_batch([raw_for(device: p2_device, link: @link_a1, type: "open", project: @project2)])

    link = LinkStatisticsQuery.new(
      project: @project, params: { link_id: @link_a1.id, start_date: @date, end_date: @date, active: true, all: true }
    ).call[:links].first
    assert_equal 2, (link["total_opens"] || link[:total_opens]).to_i,
                 "foreign-project event must not inflate this link's dashboard total"
  end

  # End-to-end through the real dashboard HTTP endpoint (request → controller →
  # query → serialize → JSON), not just the service layer.
  # NOTE: the links/search_v2 endpoint is intentionally NOT covered here — its
  # 200 response returns {links:, meta:} but its declared API contract expects a
  # paginated {data, page, ...} shape (which campaigns_v2 returns). That contract
  # drift is tracked separately; the per-link dashboard totals are covered at the
  # service level (LinkStatisticsQuery tests above).
  test "campaigns dashboard endpoint returns totals = sum of links over the full request path" do
    ingest_matrix
    post "#{API_PREFIX}/projects/#{@project.id}/campaigns/search_v2",
         params: { start_date: @date.to_s, end_date: @date.to_s }, headers: @headers
    assert_response :ok

    a = JSON.parse(response.body)["data"].find { |c| c["name"] == "Campaign A" }
    assert_not_nil a, "Campaign A in the dashboard response"
    assert_equal 4, a["total_views"].to_i,    "campaign_a views = link_a1(3) + link_a2(1)"
    assert_equal 3, a["total_opens"].to_i,     # 2 + 1
                 "campaign_a opens = sum of its links"
    assert_equal 1, a["total_installs"].to_i   # 1 + 0
  end

  test "time_spent records the engagement value (not a count) on link and campaign" do
    device = fresh_device
    ingest_via_process_batch([raw_for(device: device, link: @link_a1, type: "time_spent", engagement: 5000)])

    assert_equal 5000, LinkDailyStatistic.where(project_id: @project.id, link_id: @link_a1.id).sum(:time_spent),
                 "link time_spent = engagement value, not 1"
    campaign_ts = CampaignStatisticsQuery.new(project: @project, params: { start_date: @date, end_date: @date })
                                         .call.find { |c| c.id == @campaign_a.id }.total_time_spent.to_i
    assert_equal 5000, campaign_ts
  end

  test "VisitorStatisticsQuery scopes visitors by project and date" do
    device = fresh_device
    visitor = Visitor.find_by!(project_id: @project.id, device_id: device.id)
    ingest_via_process_batch([raw_for(device: device, link: nil, type: "open")])

    in_range = VisitorStatisticsQuery.new(project: @project, params: { start_date: @date, end_date: @date })
                                     .call[:visitors].map { |v| v["sdk_identifier"] || v[:sdk_identifier] }
    assert_includes in_range, visitor.sdk_identifier, "visitor with an in-range event appears"

    out_range = VisitorStatisticsQuery.new(project: @project, params: { start_date: @date + 5, end_date: @date + 10 })
                                      .call[:visitors].map { |v| v["sdk_identifier"] || v[:sdk_identifier] }
    refute_includes out_range, visitor.sdk_identifier, "out-of-window date excludes the visitor"
  end
end
