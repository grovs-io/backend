require "test_helper"

class SmartBannerLinkServiceTest < ActiveSupport::TestCase
  include SmartBannerTestHelper

  fixtures :instances, :projects, :domains, :redirect_configs, :devices, :visitors

  setup do
    @project = projects(:one)
    @banner = create_test_banner(@project)
  end

  test "the default link is an anonymous, preview-less, hidden banner link" do
    link = @banner.default_link

    assert link.persisted?
    assert_nil link.visitor_id
    assert_equal false, link.sdk_generated
    assert_equal SmartBanner::LINK_PLATFORM, link.generated_from_platform
    assert_equal({}, link.data)
    assert_equal ["smart_banner", "smart_banner:#{@banner.id}"], link.tags
    assert_equal false, link.show_preview_ios
    assert_equal false, link.show_preview_android
    assert_nil link.title
    assert_nil link.subtitle
    assert_nil link.image_url
  end

  test "the same payload returns the same link" do
    first = SmartBannerLinkService.fetch(@banner, page_path: "/products/1", data: { "id" => "1" })
    second = SmartBannerLinkService.fetch(@banner, page_path: "/products/1", data: { "id" => "1" })

    assert_equal first.id, second.id
    assert_equal 1, @banner.smart_banner_links.count
    assert_equal 1, @banner.reload.links_count
  end

  test "key order does not matter" do
    first = SmartBannerLinkService.fetch(@banner, page_path: "/p", data: { "a" => 1, "b" => true })
    second = SmartBannerLinkService.fetch(@banner, page_path: "/p", data: { "b" => true, "a" => 1 })

    assert_equal first.id, second.id
  end

  test "different data or page path gives a different link" do
    a = SmartBannerLinkService.fetch(@banner, page_path: "/products/a", data: {})
    b = SmartBannerLinkService.fetch(@banner, page_path: "/products/b", data: {})
    c = SmartBannerLinkService.fetch(@banner, page_path: "/products/a", data: { "x" => "1" })

    assert_equal 3, [a.id, b.id, c.id].uniq.size
  end

  test "stored data is the page data plus page_path, and the page's own page_path wins" do
    plain = SmartBannerLinkService.fetch(@banner, page_path: "/p/1", data: { "sku" => "A1" })
    custom = SmartBannerLinkService.fetch(@banner, page_path: "/p/2", data: { "page_path" => "/app/home" })

    assert_equal({ "page_path" => "/p/1", "sku" => "A1" }, plain.data)
    assert_equal({ "page_path" => "/app/home" }, custom.data)
  end

  test "page links are anonymous and hidden like the default link" do
    link = SmartBannerLinkService.fetch(@banner, page_path: "/p/1", data: {})

    assert_nil link.visitor_id
    assert_equal false, link.sdk_generated
    assert_equal SmartBanner::LINK_PLATFORM, link.generated_from_platform
  end

  test "invalid data is refused" do
    [
      [nil, {}],
      ["", {}],
      ["products/1", {}],
      ["/#{'a' * 512}", {}],
      ["/p", "not an object"],
      ["/p", { "nested" => { "a" => 1 } }],
      ["/p", { "list" => [1] }],
      ["/p", { "inf" => Float::INFINITY }],
      ["/p", (1..21).index_by { |i| "k#{i}" }],
      ["/p", { "k" * 65 => 1 }],
      ["/p", { "v" => "x" * 513 }]
    ].each do |page_path, data|
      assert_raises(SmartBannerLinkData::Invalid, "expected #{page_path.inspect} / #{data.inspect} to be refused") do
        SmartBannerLinkService.fetch(@banner, page_path: page_path, data: data)
      end
    end
    assert_equal 0, @banner.smart_banner_links.count
  end

  # Same examples as the spec's "Link data boundary examples" table; the web SDK tests use them too.
  test "the 4096-byte limit covers the whole canonical payload" do
    at_limit = ("a".."g").index_with { |_k| "x" * 512 }.merge("h" => "x" * 438)
    over_limit = at_limit.merge("h" => "x" * 439)

    assert_equal 4096, JSON.generate(SmartBannerLinkData.build(page_path: "/p", data: at_limit)).bytesize
    assert_raises(SmartBannerLinkData::Invalid) { SmartBannerLinkData.build(page_path: "/p", data: over_limit) }
    assert_equal({ "page_path" => "/" }, SmartBannerLinkData.build(page_path: "/", data: nil))
  end

  test "multibyte values count in bytes, not characters" do
    data = ("a".."d").index_with { |_k| "é" * 512 }

    assert_raises(SmartBannerLinkData::Invalid) { SmartBannerLinkData.build(page_path: "/p", data: data) }
  end

  test "null values are dropped before the checks" do
    built = SmartBannerLinkData.build(page_path: "/p", data: { "id" => nil, "sku" => "A1" })

    assert_equal({ "page_path" => "/p", "sku" => "A1" }, built)
    assert_equal SmartBannerLinkData.build(page_path: "/p", data: { "sku" => "A1" }), built
  end

  test "past the cap the default link is returned and nothing is created" do
    SmartBannerLinkService.stub(:max_links, 2) do
      SmartBannerLinkService.fetch(@banner, page_path: "/p/1", data: {})
      SmartBannerLinkService.fetch(@banner, page_path: "/p/2", data: {})

      assert_no_difference "Link.count" do
        assert_equal @banner.default_link_id, SmartBannerLinkService.fetch(@banner, page_path: "/p/3", data: {}).id
      end
      assert_equal "/p/1", SmartBannerLinkService.fetch(@banner, page_path: "/p/1", data: {}).data["page_path"]
    end
  end

  test "the new-link rate limit does not affect existing-link lookups past the limit" do
    ip = "203.0.113.10"
    link = SmartBannerLinkService.fetch(@banner, page_path: "/p/1", data: {}, client_ip: ip)

    SmartBannerLinkService.stub(:new_link_rate_limit, 0) do
      assert_equal link.id, SmartBannerLinkService.fetch(@banner, page_path: "/p/1", data: {}, client_ip: ip).id
    end
  end

  test "the 121st new link in a minute from the same IP for the same banner raises RateLimited" do
    ip = "203.0.113.20"

    SmartBannerLinkService.stub(:new_link_rate_limit, 2) do
      SmartBannerLinkService.fetch(@banner, page_path: "/p/1", data: {}, client_ip: ip)
      SmartBannerLinkService.fetch(@banner, page_path: "/p/2", data: {}, client_ip: ip)

      assert_no_difference "Link.count" do
        assert_raises(SmartBannerLinkService::RateLimited) do
          SmartBannerLinkService.fetch(@banner, page_path: "/p/3", data: {}, client_ip: ip)
        end
      end
    end
  end

  test "another IP or another banner is not affected by a rate-limited IP" do
    limited_ip = "203.0.113.30"
    other_banner = create_test_banner(@project, name: "Other")

    SmartBannerLinkService.stub(:new_link_rate_limit, 1) do
      SmartBannerLinkService.fetch(@banner, page_path: "/p/1", data: {}, client_ip: limited_ip)
      assert_raises(SmartBannerLinkService::RateLimited) do
        SmartBannerLinkService.fetch(@banner, page_path: "/p/2", data: {}, client_ip: limited_ip)
      end

      other_ip_link = SmartBannerLinkService.fetch(@banner, page_path: "/p/2", data: {}, client_ip: "203.0.113.31")
      assert_not_equal @banner.default_link_id, other_ip_link.id

      other_banner_link = SmartBannerLinkService.fetch(other_banner, page_path: "/p/2", data: {}, client_ip: limited_ip)
      assert_not_equal other_banner.default_link_id, other_banner_link.id
    end
  end

  test "an install through a banner link creates no USER_REFERRED and no inviter" do
    link = SmartBannerLinkService.fetch(@banner, page_path: "/p/1", data: {})
    device = devices(:ios_device)
    parsed = [{ type: Grovs::Events::INSTALL, project_id: @project.id, device_id: device.id,
                link_id: link.id, occurred_at: Time.current }]

    event_rows, updates, inviter_assignments = BatchEventProcessorJob.new.send(
      :handle_referrals, parsed, { @project.id => @project }, { device.id => device },
      { link.id => link }, { [@project.id, device.id] => visitors(:ios_visitor) }
    )

    assert_empty event_rows
    assert_empty updates
    assert_empty inviter_assignments
  end

  # CLAUDE.md: the batch path and the sync fallback must treat referrals the same way.
  test "an install through a banner link on the sync fallback creates no USER_REFERRED and no inviter" do
    link = SmartBannerLinkService.fetch(@banner, page_path: "/p/1", data: {})
    device = Device.create!(platform: "ios", user_agent: "Banner-Test/#{SecureRandom.hex(4)}",
                            ip: "10.1.2.3", remote_ip: "10.1.2.4")
    visitor = Visitor.create!(project: @project, device: device, web_visitor: false)
    device.define_singleton_method(:visitor_for_project_id) do |project_id|
      Visitor.includes(:device).find_by(project_id: project_id, device_id: id)
    end

    assert_no_difference -> { Event.where(event: Grovs::Events::USER_REFERRED).count } do
      EventIngestionService.log(Grovs::Events::INSTALL, @project, device, {}, link)
    end
    assert_nil visitor.reload.inviter_id
  end
end
