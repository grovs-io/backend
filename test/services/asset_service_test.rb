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

  test "absolute_url is the same as permanent_url once S3_ASSET_PREFIX is set" do
    file = DownloadableFile.create!(name: "with-prefix")
    file.file.attach(io: StringIO.new("x"), filename: "x.csv", content_type: "text/csv")

    assert_equal AssetService.permanent_url(file.file), AssetService.absolute_url(file.file)
  end

  test "absolute_url falls back to the api host once S3_ASSET_PREFIX is unset" do
    file = DownloadableFile.create!(name: "no-prefix")
    file.file.attach(io: StringIO.new("x"), filename: "x.csv", content_type: "text/csv")
    saved = { protocol: ENV["SERVER_HOST_PROTOCOL"], host: ENV["SERVER_HOST"] }
    ENV["S3_ASSET_PREFIX"] = nil
    ENV["SERVER_HOST_PROTOCOL"] = "https://"
    ENV["SERVER_HOST"] = "example.com"

    url = AssetService.absolute_url(file.file)
    assert_equal "https://api.example.com#{AssetService.permanent_url(file.file)}", url
  ensure
    ENV["SERVER_HOST_PROTOCOL"] = saved[:protocol]
    ENV["SERVER_HOST"] = saved[:host]
  end

  test "absolute_url is nil for an unattached asset" do
    file = DownloadableFile.create!(name: "nothing")
    assert_nil AssetService.absolute_url(file.file)
  end

  test "swap repoints redirect and proxy addresses whatever follows them, and changes nothing else" do
    from = ActiveStorage::Blob.create_and_upload!(io: StringIO.new("a"), filename: "a.png", content_type: "image/png")
    to = ActiveStorage::Blob.create_and_upload!(io: StringIO.new("a"), filename: "a.png", content_type: "image/png")
    redirect = ->(blob) { "https://cdn.example.com#{AssetService.path(blob)}" }
    proxy = ->(blob) { "https://api.example.com/rails/active_storage/blobs/proxy/#{blob.signed_id}/a.png" }
    html = lambda do |blob|
      "<img src=\"#{redirect[blob]}\"><script>const u = `#{redirect[blob]}`; let v = '#{proxy[blob]}';</script>" \
        "<i style=\"a:url(#{proxy[blob]});\"></i><div data-x=\"{&quot;src&quot;:&quot;#{proxy[blob]}&quot;}\"></div>"
    end

    swapped = AssetService.swap({ "html" => html[from], "list" => [redirect[from], 1] }, from, to)

    assert_equal({ "html" => html[to], "list" => [redirect[to], 1] }, swapped)
  end

  test "names? finds the signed id anywhere in nested values, reading it from the blob once" do
    blob = Struct.new(:calls) { def signed_id = (self.calls += 1) && "abc123" }.new(0)
    value = { "a" => ["x", { "b" => "no" }], "c" => [nil, 1, "has abc123 here"] }

    assert AssetService.names?(value, blob)
    assert_not AssetService.names?({ "a" => ["x", 2] }, blob)
    assert_equal 2, blob.calls
  end
end
