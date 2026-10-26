require "test_helper"

class SmartBannerManagementServiceTest < ActiveSupport::TestCase
  include SmartBannerTestHelper

  fixtures :instances, :projects, :domains, :redirect_configs

  setup do
    @project = projects(:one)
  end

  test "create appends to the end and makes the default link" do
    first = SmartBannerManagementService.create(project: @project, attrs: { name: "A", title: "Get it" })
    second = SmartBannerManagementService.create(project: @project, attrs: { name: "B", title: "Get it" },
                                                 icon: png_attachable)

    assert_equal [0, 1], [first.priority, second.priority]
    assert first.default_link.present?
    assert second.icon.attached?
  end

  test "create defaults to draft status" do
    banner = SmartBannerManagementService.create(project: @project, attrs: { name: "A", title: "t" })

    assert_equal "draft", banner.status
  end

  test "create with invalid attributes raises and leaves nothing behind" do
    assert_no_difference ["SmartBanner.count", "Link.count"] do
      assert_raises(ActiveRecord::RecordInvalid) do
        SmartBannerManagementService.create(project: @project, attrs: { name: "A", title: "" })
      end
    end
  end

  test "update changes fields, replaces and removes the icon" do
    banner = SmartBannerManagementService.create(project: @project, attrs: { name: "A", title: "Old" })

    SmartBannerManagementService.update(banner: banner, attrs: { title: "New" }, icon: png_attachable)
    assert_equal "New", banner.reload.title
    assert banner.icon.attached?

    SmartBannerManagementService.update(banner: banner.reload, attrs: {}, remove_icon: true)
    assert_not banner.reload.icon.attached?
  end

  test "reorder rewrites priorities in the given order" do
    a = SmartBannerManagementService.create(project: @project, attrs: { name: "A", title: "t" })
    b = SmartBannerManagementService.create(project: @project, attrs: { name: "B", title: "t" })
    c = SmartBannerManagementService.create(project: @project, attrs: { name: "C", title: "t" })

    result = SmartBannerManagementService.reorder(project: @project, ids: [c.id, a.id, b.id].map(&:to_s))

    assert_equal [c.id, a.id, b.id], result.map(&:id)
    assert_equal [0, 1, 2], result.map(&:priority)
  end

  test "reorder refuses a list that is not every banner exactly once" do
    a = SmartBannerManagementService.create(project: @project, attrs: { name: "A", title: "t" })
    b = SmartBannerManagementService.create(project: @project, attrs: { name: "B", title: "t" })

    [[a.id], [a.id, a.id], [a.id, b.id, 999_999]].each do |ids|
      assert_raises(SmartBannerManagementService::InvalidOrder) do
        SmartBannerManagementService.reorder(project: @project, ids: ids)
      end
    end
  end

  test "reorder with a non-scalar id raises InvalidOrder instead of blowing up" do
    a = SmartBannerManagementService.create(project: @project, attrs: { name: "A", title: "t" })
    b = SmartBannerManagementService.create(project: @project, attrs: { name: "B", title: "t" })

    assert_raises(SmartBannerManagementService::InvalidOrder) do
      SmartBannerManagementService.reorder(project: @project, ids: [a.id.to_s, { "x" => 1 }, b.id.to_s])
    end
  end

  test "reorder excludes archived banners from the required id list and leaves their priority alone" do
    a = SmartBannerManagementService.create(project: @project, attrs: { name: "A", title: "t" })
    b = SmartBannerManagementService.create(project: @project, attrs: { name: "B", title: "t" })
    archived = SmartBannerManagementService.create(project: @project, attrs: { name: "C", title: "t" })
    SmartBannerManagementService.update(banner: archived, attrs: { status: "archived" })

    assert_raises(SmartBannerManagementService::InvalidOrder) do
      SmartBannerManagementService.reorder(project: @project, ids: [b.id, a.id, archived.id])
    end

    result = SmartBannerManagementService.reorder(project: @project, ids: [b.id, a.id])

    assert_equal [b.id, a.id], result.reject { |x| x.id == archived.id }.map(&:id)
    assert_equal 2, archived.reload.priority
  end

  test "archiving a banner leaves its priority untouched" do
    banner = SmartBannerManagementService.create(project: @project, attrs: { name: "A", title: "t" })
    original_priority = banner.priority

    SmartBannerManagementService.update(banner: banner, attrs: { status: "archived" })

    assert_equal "archived", banner.reload.status
    assert_equal original_priority, banner.priority
  end

  test "restoring an archived banner forces paused and appends to the end, ignoring the requested status" do
    archived = SmartBannerManagementService.create(project: @project, attrs: { name: "A", title: "t" })
    SmartBannerManagementService.update(banner: archived, attrs: { status: "archived" })
    other = SmartBannerManagementService.create(project: @project, attrs: { name: "B", title: "t" })

    SmartBannerManagementService.update(banner: archived.reload, attrs: { status: "live" })

    assert_equal "paused", archived.reload.status
    assert_equal other.priority + 1, archived.priority
  end

  test "sdk payload lists live banners in priority order in the SDK shape" do
    a = SmartBannerManagementService.create(project: @project, attrs: { name: "A", title: "First", status: "live" })
    SmartBannerManagementService.create(project: @project, attrs: { name: "B", title: "Off", status: "draft" })
    c = SmartBannerManagementService.create(project: @project, attrs: { name: "C", title: "Second", status: "live" })
    SmartBannerManagementService.reorder(project: @project, ids: SmartBanner.where(project: @project).order(:id).pluck(:id).reverse)

    payload = SmartBanner.sdk_payload_for(@project)

    assert_equal [c.id, a.id], payload.map { |b| b["id"] }
    assert_equal %w[background_color button_color button_text button_text_color default_link dismiss_days icon_url id
                    open_hide_days platforms position subtitle text_color title url_exclude url_include],
                 payload.first.keys.sort
    assert_equal c.default_link.access_path, payload.first["default_link"]
    assert_match %r{\Ahttps://}, payload.first["default_link"]
  end

  test "the sdk payload cache is cleared when a banner changes" do
    Rails.stub(:cache, ActiveSupport::Cache::MemoryStore.new) do
      banner = SmartBannerManagementService.create(project: @project, attrs: { name: "A", title: "Old", status: "live" })
      assert_equal ["Old"], SmartBanner.sdk_payload_for(@project).map { |b| b["title"] }

      SmartBannerManagementService.update(banner: banner, attrs: { title: "New" })
      assert_equal ["New"], SmartBanner.sdk_payload_for(@project).map { |b| b["title"] }

      banner.destroy!
      assert_equal [], SmartBanner.sdk_payload_for(@project)
    end
  end

  test "a payload computed before a change cannot be served after it" do
    Rails.stub(:cache, ActiveSupport::Cache::MemoryStore.new) do
      banner = SmartBannerManagementService.create(project: @project, attrs: { name: "A", title: "Old", status: "live" })
      stale_key = SmartBanner.sdk_cache_key(@project.id)

      SmartBannerManagementService.update(banner: banner, attrs: { title: "New" })
      Rails.cache.write(stale_key, [{ "title" => "Old" }])

      assert_equal ["New"], SmartBanner.sdk_payload_for(@project).map { |b| b["title"] }
    end
  end

  test "dashboard shape carries stats, icon url and default link" do
    banner = SmartBannerManagementService.create(project: @project, attrs: { name: "A", title: "t" }, icon: png_attachable)

    h = SmartBannerSerializer.new(banner).build(stats: SmartBannerSerializer::EMPTY_STATS)

    assert_equal SmartBannerSerializer::EMPTY_STATS, h["stats"]
    assert h["icon_url"].present?
    assert_equal banner.default_link.access_path, h["default_link"]
    assert_equal "A", h["name"]
  end

  test "duplicate copies fields and icon into a draft banner at the end with its own default link" do
    banner = SmartBannerManagementService.create(
      project: @project,
      attrs: { name: "A", title: "t", status: "live", subtitle: "Sub", url_include: ["/p/*"] },
      icon: png_attachable
    )
    SmartBannerManagementService.create(project: @project, attrs: { name: "B", title: "t" })

    copy = SmartBannerManagementService.duplicate(banner: banner)

    assert_equal "A (copy)", copy.name
    assert_equal "draft", copy.status
    assert_equal "Sub", copy.subtitle
    assert_equal ["/p/*"], copy.url_include
    assert_equal 2, copy.priority
    assert copy.icon.attached?
    assert copy.default_link.present?
    assert_not_equal banner.default_link_id, copy.default_link_id
  end

  test "duplicate resets links_count on the copy" do
    banner = SmartBannerManagementService.create(project: @project, attrs: { name: "A", title: "t" })
    banner.update_column(:links_count, 10_000)

    copy = SmartBannerManagementService.duplicate(banner: banner)

    assert_equal 0, copy.links_count
    assert copy.default_link.present?
    assert_difference "Link.count", 1 do
      SmartBannerLinkService.fetch(copy, page_path: "/p/1", data: {})
    end
  end
end
