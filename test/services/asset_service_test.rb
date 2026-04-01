require "test_helper"

class AssetServiceTest < ActiveSupport::TestCase
  setup do
    @saved_prefix = ENV["S3_ASSET_PREFIX"]
    ENV["S3_ASSET_PREFIX"] = "https://cdn.example.com"
  end

  teardown do
    ENV["S3_ASSET_PREFIX"] = @saved_prefix
  end

  test "returns permanent URL for attached asset" do
    file = DownloadableFile.create!(name: "test-asset")
    file.file.attach(
      io: StringIO.new("test content"),
      filename: "test.csv",
      content_type: "text/csv"
    )

    url = AssetService.permanent_url(file.file)
    assert url.present?
    assert url.start_with?("https://cdn.example.com"), "URL should start with S3 prefix"
  end

  test "returns nil for unattached asset" do
    file = DownloadableFile.create!(name: "no-attachment")

    result = AssetService.permanent_url(file.file)
    assert_nil result
  end

  test "URL contains rails blob path" do
    file = DownloadableFile.create!(name: "blob-check")
    file.file.attach(
      io: StringIO.new("blob content"),
      filename: "blob.csv",
      content_type: "text/csv"
    )

    url = AssetService.permanent_url(file.file)
    assert_includes url, "/rails/active_storage/blobs/"
  end
end
