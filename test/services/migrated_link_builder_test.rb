require "test_helper"

class MigratedLinkBuilderTest < ActiveSupport::TestCase
  fixtures :projects, :instances, :domains, :redirect_configs, :links, :custom_redirects

  setup do
    @project = projects(:one)
    @domain  = @project.domain
  end

  def full_payload
    {
      "ios_url"           => "myapp://ios",
      "android_url"       => "myapp://android",
      "desktop_url"       => "https://example.com/web",
      "og_title"          => "Migration Title",
      "og_description"    => "Migration Subtitle",
      "og_image_url"      => "https://cdn.example.com/x.png",
      "tracking_campaign" => "campaign",
      "tracking_source"   => "source",
      "tracking_medium"   => "medium",
      "tags"              => %w[t1 t2],
      "provider"          => "branch",
      "custom_data"       => { "foo" => "bar" }
    }
  end

  test "creates Link on the project's primary domain" do
    link = MigratedLinkBuilder.call(project: @project, payload: full_payload)
    assert_equal @domain.id, link.domain_id
    assert_equal @project.redirect_config.id, link.redirect_config_id
    assert_equal Grovs::Migrations::GENERATED_FROM_PLATFORM, link.generated_from_platform
    assert link.active
  end

  test "OG fields map to Link.title / subtitle / image_url" do
    link = MigratedLinkBuilder.call(project: @project, payload: full_payload)
    assert_equal "Migration Title", link.title
    assert_equal "Migration Subtitle", link.subtitle
    assert_equal "https://cdn.example.com/x.png", link.image_url
  end

  test "missing OG fields stay nil (render-time fallback handles substitution)" do
    payload = full_payload.merge("og_title" => nil, "og_description" => "", "og_image_url" => nil)
    link = MigratedLinkBuilder.call(project: @project, payload: payload)
    assert_nil link.title
    assert_nil link.subtitle
    assert_nil link.image_url
  end

  test "UTM fields populate tracking_* columns" do
    link = MigratedLinkBuilder.call(project: @project, payload: full_payload)
    assert_equal "campaign", link.tracking_campaign
    assert_equal "source",   link.tracking_source
    assert_equal "medium",   link.tracking_medium
  end

  test "tags map to Link.tags" do
    link = MigratedLinkBuilder.call(project: @project, payload: full_payload)
    assert_equal %w[t1 t2], link.tags
  end

  test "custom_data lands in Link.data" do
    link = MigratedLinkBuilder.call(project: @project, payload: full_payload)
    assert_equal "bar", link.data["foo"]
    # Platform URLs and OG fields must NOT leak into data
    assert_not link.data.key?("ios_url"),  "ios_url leaked into data"
    assert_not link.data.key?("og_title"), "og_title leaked into data"
  end

  test "creates CustomRedirect rows for each present platform" do
    link = MigratedLinkBuilder.call(project: @project, payload: full_payload)
    redirects = link.custom_redirects.order(:platform)
    assert_equal 3, redirects.count
    expected = {
      Grovs::Platforms::IOS     => "myapp://ios",
      Grovs::Platforms::ANDROID => "myapp://android",
      Grovs::Platforms::DESKTOP => "https://example.com/web"
    }
    redirects.each do |cr|
      assert_equal expected[cr.platform], cr.url
      assert cr.open_app_if_installed
    end
  end

  test "blank platform URL produces NO CustomRedirect row" do
    payload = full_payload.merge("android_url" => nil, "desktop_url" => "")
    link = MigratedLinkBuilder.call(project: @project, payload: payload)
    platforms = link.custom_redirects.pluck(:platform)
    assert_includes platforms, Grovs::Platforms::IOS
    assert_not_includes platforms, Grovs::Platforms::ANDROID
    assert_not_includes platforms, Grovs::Platforms::DESKTOP
  end

  test "auto-generates a unique path" do
    link1 = MigratedLinkBuilder.call(project: @project, payload: full_payload)
    link2 = MigratedLinkBuilder.call(project: @project, payload: full_payload)
    assert_not_equal link1.path, link2.path
    assert link1.path.length >= 6
  end

  test "name falls back to 'Migrated from <provider>' when payload name absent" do
    link = MigratedLinkBuilder.call(project: @project, payload: full_payload)
    assert_equal "Migrated from branch", link.name
  end

  test "name from payload takes priority" do
    payload = full_payload.merge("name" => "My Custom Name")
    link = MigratedLinkBuilder.call(project: @project, payload: payload)
    assert_equal "My Custom Name", link.name
  end

  # ---------------------------------------------------------------------------
  # URL scheme scrubbing (XSS / open-redirect defense against adversarial payloads)
  #
  # Two-tier model:
  #   - Mobile redirects (ios_url, android_url) accept custom URI schemes (myapp://) —
  #     that's the foundation of deep linking. javascript:/data:/file:/vbscript:/about: blocked.
  #   - Web redirects (desktop_url) and og_image_url are rendered in a browser. http/https only.
  # ---------------------------------------------------------------------------

  test "mobile redirect: rejects javascript: scheme" do
    payload = full_payload.merge("ios_url" => "javascript:alert(1)", "android_url" => "JAVASCRIPT:alert(1)")
    link = MigratedLinkBuilder.call(project: @project, payload: payload)
    platforms = link.custom_redirects.pluck(:platform)
    assert_not_includes platforms, Grovs::Platforms::IOS
    assert_not_includes platforms, Grovs::Platforms::ANDROID
  end

  test "mobile redirect: rejects data: scheme" do
    payload = full_payload.merge("ios_url" => "data:text/html,<script>alert(1)</script>")
    link = MigratedLinkBuilder.call(project: @project, payload: payload)
    assert_not_includes link.custom_redirects.pluck(:platform), Grovs::Platforms::IOS
  end

  test "mobile redirect: rejects file: scheme" do
    payload = full_payload.merge("ios_url" => "file:///etc/passwd")
    link = MigratedLinkBuilder.call(project: @project, payload: payload)
    assert_not_includes link.custom_redirects.pluck(:platform), Grovs::Platforms::IOS
  end

  test "mobile redirect: rejects vbscript: and about: schemes" do
    %w[vbscript:msgbox(1) about:blank].each do |bad_url|
      payload = full_payload.merge("ios_url" => bad_url)
      link = MigratedLinkBuilder.call(project: @project, payload: payload)
      assert_not_includes link.custom_redirects.pluck(:platform), Grovs::Platforms::IOS,
        "expected #{bad_url} to be blocked"
    end
  end

  test "mobile redirect: ACCEPTS custom URI schemes (myapp://, fb123://) — required for deep linking" do
    %w[myapp://path fb123456789://foo twitter://timeline].each do |url|
      project_local = projects(:one)  # reuse to avoid uniqueness issues from rapid creates
      payload = full_payload.merge("ios_url" => url)
      link = MigratedLinkBuilder.call(project: project_local, payload: payload)
      assert_includes link.custom_redirects.where(platform: Grovs::Platforms::IOS).pluck(:url), url
    end
  end

  test "web/desktop redirect: rejects non-http/https schemes including custom app schemes" do
    payload = full_payload.merge("desktop_url" => "myapp://deeplink")
    link = MigratedLinkBuilder.call(project: @project, payload: payload)
    assert_not_includes link.custom_redirects.pluck(:platform), Grovs::Platforms::DESKTOP
  end

  test "web/desktop redirect: accepts http:/https:" do
    payload = full_payload.merge("desktop_url" => "https://example.com/landing")
    link = MigratedLinkBuilder.call(project: @project, payload: payload)
    assert_equal "https://example.com/landing",
      link.custom_redirects.where(platform: Grovs::Platforms::DESKTOP).first&.url
  end

  test "mobile redirect: rejects malformed URIs without raising" do
    payload = full_payload.merge("ios_url" => "https://[malformed")
    assert_nothing_raised do
      link = MigratedLinkBuilder.call(project: @project, payload: payload)
      assert_not_includes link.custom_redirects.pluck(:platform), Grovs::Platforms::IOS
    end
  end

  test "og_image_url: rejects javascript: scheme" do
    payload = full_payload.merge("og_image_url" => "javascript:alert(1)")
    link = MigratedLinkBuilder.call(project: @project, payload: payload)
    assert_nil link.image_url
  end

  test "og_image_url: rejects custom app schemes (rendered in browser)" do
    payload = full_payload.merge("og_image_url" => "myapp://image")
    link = MigratedLinkBuilder.call(project: @project, payload: payload)
    assert_nil link.image_url
  end

  test "og_image_url: accepts valid https" do
    payload = full_payload.merge("og_image_url" => "https://cdn.example.com/x.png")
    link = MigratedLinkBuilder.call(project: @project, payload: payload)
    assert_equal "https://cdn.example.com/x.png", link.image_url
  end

  # ---------------------------------------------------------------------------
  # Payload size caps (defense against adversarial / large upstream responses)
  # ---------------------------------------------------------------------------

  test "custom_data over MAX_CUSTOM_DATA_BYTES is dropped (NOT truncated)" do
    huge_blob = "x" * (MigratedLinkBuilder::MAX_CUSTOM_DATA_BYTES + 1)
    payload = full_payload.merge("custom_data" => { "huge" => huge_blob })
    link = MigratedLinkBuilder.call(project: @project, payload: payload)
    assert_equal({}, link.data, "oversize payload must be dropped entirely (partial JSON is untrustworthy)")
  end

  test "custom_data just under MAX_CUSTOM_DATA_BYTES is preserved" do
    safe = "y" * 100
    payload = full_payload.merge("custom_data" => { "safe_key" => safe })
    link = MigratedLinkBuilder.call(project: @project, payload: payload)
    assert_equal safe, link.data["safe_key"]
  end

  test "tags over MAX_TAG_COUNT are truncated" do
    too_many = (1..(MigratedLinkBuilder::MAX_TAG_COUNT + 20)).map { |i| "tag#{i}" }
    payload = full_payload.merge("tags" => too_many)
    link = MigratedLinkBuilder.call(project: @project, payload: payload)
    assert_equal MigratedLinkBuilder::MAX_TAG_COUNT, link.tags.size
  end

  test "individual tag over MAX_TAG_LENGTH is truncated to the limit" do
    long_tag = "z" * (MigratedLinkBuilder::MAX_TAG_LENGTH + 50)
    payload = full_payload.merge("tags" => [long_tag])
    link = MigratedLinkBuilder.call(project: @project, payload: payload)
    assert_equal MigratedLinkBuilder::MAX_TAG_LENGTH, link.tags.first.length
  end

  test "returns nil (does NOT raise) when project has no domain" do
    # Stub the project's domain to nil — simulates a partial-provisioning state without
    # actually destroying the fixture row (which would trigger unrelated callback chains).
    @project.stub(:domain, nil) do
      result = MigratedLinkBuilder.call(project: @project, payload: full_payload)
      assert_nil result, "missing domain must return nil so the click can fall back"
    end
  end

  test "returns nil when project has no redirect_config" do
    @project.stub(:redirect_config, nil) do
      result = MigratedLinkBuilder.call(project: @project, payload: full_payload)
      assert_nil result, "missing redirect_config must return nil so the click can fall back"
    end
  end

  test "tag truncation preserves UTF-8 boundaries (multi-byte chars not cut mid-codepoint)" do
    # 4-byte emoji repeated. With byte truncation at an odd boundary, this would produce
    # invalid UTF-8 that PG rejects. Char-based truncation must keep the string valid.
    long_emoji_tag = "🚀" * (MigratedLinkBuilder::MAX_TAG_LENGTH + 10)
    payload = full_payload.merge("tags" => [long_emoji_tag])
    link = MigratedLinkBuilder.call(project: @project, payload: payload)
    tag = link.tags.first
    assert tag.valid_encoding?, "truncated tag must remain valid UTF-8"
    assert_equal MigratedLinkBuilder::MAX_TAG_LENGTH, tag.length
  end

  test "non-string tags are dropped" do
    payload = full_payload.merge("tags" => ["valid", 123, nil, { weird: "object" }, "also_valid"])
    link = MigratedLinkBuilder.call(project: @project, payload: payload)
    assert_equal %w[valid also_valid], link.tags
  end
end
