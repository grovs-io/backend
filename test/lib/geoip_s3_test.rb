require "test_helper"
require Rails.root.join("bin/geoip_s3")

class GeoipS3Test < ActiveSupport::TestCase
  class FakeS3
    attr_reader :uploads

    def initialize(objects = {})
      @objects = objects
      @uploads = {}
    end

    def head_object(bucket:, key:)
      obj = @objects.fetch("s3://#{bucket}/#{key}") { raise Aws::S3::Errors::NotFound.new(nil, "missing") }
      OpenStruct.new(last_modified: obj[:last_modified])
    end

    def get_object(bucket:, key:, response_target:)
      obj = @objects.fetch("s3://#{bucket}/#{key}")
      File.write(response_target, obj[:body])
    end

    def put_object(bucket:, key:, body:)
      @uploads["s3://#{bucket}/#{key}"] = body.read
    end
  end

  test "get downloads the object and returns its age in days" do
    uri = "s3://bucket/geoip/GeoLite2-City.mmdb"
    fake = FakeS3.new(uri => { body: "mmdb-bytes", last_modified: Time.now - (5 * 86_400) - 60 })

    Dir.mktmpdir do |dir|
      dest = File.join(dir, "db.mmdb")
      age = GeoipS3.new(client: fake).get(uri, dest)
      assert_equal 5, age
      assert_equal "mmdb-bytes", File.read(dest)
    end
  end

  test "get raises on a missing object" do
    fake = FakeS3.new
    Dir.mktmpdir do |dir|
      assert_raises(Aws::S3::Errors::NotFound) do
        GeoipS3.new(client: fake).get("s3://bucket/missing", File.join(dir, "x"))
      end
    end
  end

  test "put uploads the file body" do
    uri = "s3://bucket/geoip/GeoLite2-City.mmdb"
    fake = FakeS3.new
    Dir.mktmpdir do |dir|
      src = File.join(dir, "db.mmdb")
      File.write(src, "fresh-bytes")
      GeoipS3.new(client: fake).put(uri, src)
      assert_equal "fresh-bytes", fake.uploads[uri]
    end
  end

  test "rejects non-s3 uris and missing keys" do
    s3 = GeoipS3.new(client: FakeS3.new)
    assert_raises(ArgumentError) { s3.get("https://bucket/key", "/tmp/x") }
    assert_raises(ArgumentError) { s3.get("s3://bucket-only", "/tmp/x") }
  end
end
