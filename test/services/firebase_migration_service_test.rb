require "test_helper"
require "tempfile"

class FirebaseMigrationServiceTest < ActiveSupport::TestCase
  fixtures :instances, :projects

  setup do
    @project = projects(:one)
    @domain = Domain.create!(project: @project, domain: "test.link", subdomain: "fb#{SecureRandom.hex(2)}")
    @redirect_config = RedirectConfig.create!(project: @project)
  end

  def build_service(deeplink_prefix: nil, short_link_prefix: nil)
    FirebaseMigrationService.new(
      project: @project,
      deeplink_prefix: deeplink_prefix,
      short_link_prefix: short_link_prefix
    )
  end

  def create_csv(rows)
    file = Tempfile.new(["firebase", ".csv"])
    headers = %w[name short_link utm_campaign utm_medium utm_source link]
    file.write(headers.join(",") + "\n")
    rows.each { |row| file.write(row.join(",") + "\n") }
    file.rewind
    file
  end

  test "import_csv creates links with prefix params" do
    csv = create_csv([
      ["Link One", "https://myapp.page.link/abc123", "campaign1", "email", "newsletter", "https://myapp/deep/path"]
    ])

    result = build_service(
      deeplink_prefix: "https://myapp/",
      short_link_prefix: "https://myapp.page.link/"
    ).import_csv(csv.path)

    assert_equal 1, result[:created_count]
    assert_equal 0, result[:skipped_count]

    link = result[:links].first
    assert_equal "abc123", link.path
    assert_equal "campaign1", link.tracking_campaign
    assert_equal({ "appLink" => "myapp://deep/path" }, link.data)
  ensure
    csv&.close!
  end

  test "import_csv without prefixes uses raw values" do
    csv = create_csv([
      ["Raw Link", "rawpath", "", "", "", "https://example.com/page"]
    ])

    result = build_service.import_csv(csv.path)
    assert_equal 1, result[:created_count]

    link = result[:links].first
    assert_equal "rawpath", link.path
    assert_equal({ "appLink" => "https://example.com/page" }, link.data)
  ensure
    csv&.close!
  end

  test "import_csv skips duplicate paths" do
    Link.create!(
      name: "Existing",
      path: "existing-path",
      generated_from_platform: "dashboard",
      domain: @domain,
      active: true,
      redirect_config: @redirect_config
    )

    csv = create_csv([
      ["Duplicate", "existing-path", "", "", "", ""]
    ])

    result = build_service.import_csv(csv.path)
    assert_equal 0, result[:created_count]
    assert_equal 1, result[:skipped_count]
    assert_equal "duplicate_on_domain", result[:skipped].first[:reason]
  ensure
    csv&.close!
  end

  test "import_csv skips blank paths" do
    csv = create_csv([
      ["Blank Path", "", "", "", "", ""]
    ])

    result = build_service.import_csv(csv.path)
    assert_equal 0, result[:created_count]
    assert_equal 1, result[:skipped_count]
    assert_equal "blank_path", result[:skipped].first[:reason]
  ensure
    csv&.close!
  end
end
