require "test_helper"

class SmartBannerLinkServiceConcurrencyTest < ActiveSupport::TestCase
  include SmartBannerTestHelper

  self.use_transactional_tests = false

  fixtures :instances, :projects, :domains, :redirect_configs

  setup do
    @banner = create_test_banner(projects(:one))
  end

  teardown do
    link_ids = Link.where(generated_from_platform: SmartBanner::LINK_PLATFORM).pluck(:id)
    SmartBannerLink.where(smart_banner_id: @banner&.id).delete_all
    SmartBanner.where(id: @banner&.id).delete_all
    Link.where(id: link_ids).delete_all
  end

  test "the same payload from many requests at once creates one link" do
    links = run_concurrently(4) do
      SmartBannerLinkService.fetch(SmartBanner.find(@banner.id), page_path: "/p/1", data: {})
    end

    assert_equal 1, links.map(&:id).uniq.size
    assert_equal 1, SmartBannerLink.where(smart_banner_id: @banner.id).count
    assert_equal 1, @banner.reload.links_count
    assert_equal 2, Link.where(generated_from_platform: SmartBanner::LINK_PLATFORM).count, "default + one, no orphans"
  end

  test "the cap is soft: racing payloads may overshoot it, then creation stops" do
    SmartBannerLinkService.stub(:max_links, 3) do
      2.times { |i| SmartBannerLinkService.fetch(@banner, page_path: "/seed/#{i}", data: {}) }

      run_concurrently(4) do |i|
        SmartBannerLinkService.fetch(SmartBanner.find(@banner.id), page_path: "/race/#{i}", data: {})
      end

      created = SmartBannerLink.where(smart_banner_id: @banner.id).count
      assert_operator created, :>=, 3
      assert_equal created, @banner.reload.links_count
      assert_no_difference "Link.count" do
        assert_equal @banner.default_link_id,
                     SmartBannerLinkService.fetch(@banner, page_path: "/after", data: {}).id
      end
    end
  end

  private

  # Each thread opens its own connection and waits at the barrier so all start together.
  def run_concurrently(count, &block)
    barrier = Concurrent::CyclicBarrier.new(count)
    count.times.map do |i|
      Thread.new do
        ActiveRecord::Base.connection_pool.with_connection do |conn|
          conn.execute("SELECT 1")
          barrier.wait(10) or raise "barrier timeout"
          block.call(i)
        end
      end
    end.map(&:value)
  end
end
