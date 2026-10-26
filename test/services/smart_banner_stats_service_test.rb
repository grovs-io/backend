require "test_helper"

class SmartBannerStatsServiceTest < ActiveSupport::TestCase
  include ClickhouseTestHelper
  include SmartBannerTestHelper

  fixtures :instances, :projects, :domains, :redirect_configs, :links

  setup do
    skip_unless_clickhouse!
    @project = projects(:one)
    @banner = create_test_banner(@project, name: "A")
    @other = create_test_banner(@project, name: "B")
    @page_link = SmartBannerLinkService.fetch(@banner, page_path: "/p/1", data: {})
  end

  test "counts banner events and link events over the last 30 days" do
    insert_ch_events([
      banner_event("smart_banner_view", @banner.id),
      banner_event("smart_banner_view", @banner.id),
      banner_event("smart_banner_view", @banner.id),
      banner_event("smart_banner_view", @banner.id, at: 40.days.ago),
      banner_event("smart_banner_click", @banner.id.to_s),
      banner_event("smart_banner_dismiss", @banner.id),
      banner_event("smart_banner_view", @other.id),
      link_event("open", @banner.default_link),
      link_event("open", @page_link),
      link_event("install", @page_link),
      link_event("reinstall", @page_link),
      link_event("open", @page_link, at: 40.days.ago),
      link_event("open", links(:basic_link))
    ])

    stats = SmartBannerStatsService.for_banners(@project, [@banner, @other])

    assert_equal({ "views" => 3, "clicks" => 1, "dismisses" => 1, "ctr" => 0.3333, "opens" => 2, "installs" => 2 },
                 stats[@banner.id])
    assert_equal 1, stats[@other.id]["views"]
    assert_equal 0.0, stats[@other.id]["ctr"]
    assert_equal 0, stats[@other.id]["opens"]
  end

  test "a replayed event is counted once" do
    row = banner_event("smart_banner_view", @banner.id)
    insert_ch_events([row, row.dup])

    assert_equal 1, SmartBannerStatsService.for_banners(@project, [@banner])[@banner.id]["views"]
  end

  test "link events are counted by banner tag in one query" do
    insert_ch_events([link_event("open", @banner.default_link), link_event("install", @page_link),
                      link_event("open", @other.default_link)])
    original = Clickhouse.method(:with)
    queries = 0
    counting = lambda { |*args, &block|
      queries += 1
      original.call(*args, &block)
    }

    stats = Clickhouse.stub(:with, counting) { SmartBannerStatsService.for_banners(@project, [@banner, @other]) }

    assert_equal [1, 1], stats[@banner.id].values_at("opens", "installs")
    assert_equal [1, 0], stats[@other.id].values_at("opens", "installs")
    assert_equal 2, queries, "one banner-event query plus one link-event query"
  end

  test "a failed query is logged and counted before falling back to empty stats" do
    logged = []
    metrics = []
    Rails.logger.stub(:error, ->(msg) { logged << msg }) do
      Grovs::Metrics.stub(:increment, ->(name, **) { metrics << name }) do
        Clickhouse.stub(:with, ->(*) { raise "down" }) do
          assert_equal({ @banner.id => SmartBannerSerializer::EMPTY_STATS },
                       SmartBannerStatsService.for_banners(@project, [@banner]))
        end
      end
    end

    assert(logged.any? { |m| m.include?("smart_banners.stats_failed") && m.include?("down") })
    assert_includes metrics, "smart_banners.stats_failed"
  end

  private

  def stamp(time)
    time.utc.strftime("%Y-%m-%d %H:%M:%S.%3N")
  end

  def banner_event(name, banner_id, at: 1.day.ago)
    { event_id: "sb_#{SecureRandom.hex(6)}", project_id: @project.id, event_type: "custom", event_name: name,
      properties: { "smart_banner_id" => banner_id }, created_at: stamp(at) }
  end

  def link_event(type, link, at: 1.day.ago)
    { event_id: "sbl_#{SecureRandom.hex(6)}", project_id: @project.id, event_type: type, link_id: link.id,
      link_tags: Array(link.tags), created_at: stamp(at) }
  end
end
