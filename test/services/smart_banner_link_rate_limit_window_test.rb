require "test_helper"

class SmartBannerLinkRateLimitWindowTest < ActiveSupport::TestCase
  include SmartBannerTestHelper

  fixtures :instances, :projects, :domains, :redirect_configs

  setup do
    @banner = create_test_banner(projects(:one))
    @ip = "198.51.100.7"
    @key = "smart_banner:new_link_rate:#{@banner.id}:#{@ip}"
    REDIS.with { |c| c.del(@key) }
  end

  [[Redis::BaseError, "connection refused"], [ConnectionPool::TimeoutError, "Waited 5 sec"]].each do |error, message|
    test "a #{error.name} on the counter fails open even with a zero limit and logs a warning" do
      warnings = []
      link = nil
      # REDIS is a BasicObject wrapper that Minitest cannot stub; nested #with reuses this connection.
      REDIS.with do |conn|
        conn.stub(:incr, ->(*) { raise error, message }) do
          SmartBannerLinkService.stub(:new_link_rate_limit, 0) do
            Rails.logger.stub(:warn, ->(msg) { warnings << msg }) do
              assert_difference "SmartBannerLink.count", 1 do
                link = SmartBannerLinkService.fetch(@banner, page_path: "/p/1", data: {}, client_ip: @ip)
              end
            end
          end
        end
      end

      assert_not_equal @banner.default_link_id, link.id
      assert_includes warnings, "smart_banner_new_link_rate_limit_check_failed: #{message}"
    end
  end

  test "without a client ip the limit is not applied and no counter is written" do
    SmartBannerLinkService.stub(:new_link_rate_limit, 0) do
      link = SmartBannerLinkService.fetch(@banner, page_path: "/p/1", data: {}, client_ip: "")

      assert_not_equal @banner.default_link_id, link.id
    end
    assert_empty REDIS.with { |c| c.keys("smart_banner:new_link_rate:#{@banner.id}:*") }
  end

  test "the window is fixed: later new links do not extend the first request's TTL" do
    SmartBannerLinkService.fetch(@banner, page_path: "/p/1", data: {}, client_ip: @ip)
    assert_in_delta 60, REDIS.with { |c| c.ttl(@key) }, 2

    REDIS.with { |c| c.expire(@key, 10) }
    SmartBannerLinkService.fetch(@banner, page_path: "/p/2", data: {}, client_ip: @ip)

    assert_equal "2", REDIS.with { |c| c.get(@key) }
    assert_operator REDIS.with { |c| c.ttl(@key) }, :<=, 10
  end

  test "an existing page link is served without touching the counter" do
    SmartBannerLinkService.fetch(@banner, page_path: "/p/1", data: {}, client_ip: @ip)
    SmartBannerLinkService.fetch(@banner, page_path: "/p/1", data: {}, client_ip: @ip)

    assert_equal "1", REDIS.with { |c| c.get(@key) }
  end
end
