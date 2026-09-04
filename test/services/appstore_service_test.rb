require "test_helper"
require "sidekiq/testing"

class AppstoreServiceTest < ActiveSupport::TestCase
  setup do
    @bundle_id = "com.test.pipelining.#{SecureRandom.hex(4)}"
    @title_key = "#{Grovs::RedisKeys::TITLE_PREFIX}-ios-#{@bundle_id}"
    @appstore_id_key = "#{Grovs::RedisKeys::APPSTORE_PREFIX}-ios-#{@bundle_id}"
    @refresh_key = "store_meta_refresh:ios:#{@bundle_id}"
    Sidekiq::Testing.fake!
    RefreshStoreMetadataJob.jobs.clear
    cleanup_redis_keys
  end

  teardown do
    cleanup_redis_keys
    StoreImage.where(identifier: @bundle_id).destroy_all
    RefreshStoreMetadataJob.jobs.clear
    Sidekiq::Testing.disable!
  end

  # ── Hot path (read-only, never blocks) ──

  test "returns cached title and appstore_id without any network call" do
    REDIS.set(@title_key, "Cached App", ex: 3600)
    REDIS.set(@appstore_id_key, "12345", ex: 3600)

    result = AppstoreService.fetch_image_and_title_for_identifier(@bundle_id)
    assert_equal "Cached App", result[:title]
    assert_equal "12345", result[:appstore_id]
  end

  test "returns empty response for nil bundle_id" do
    result = AppstoreService.fetch_image_and_title_for_identifier(nil)
    assert_nil result[:title]
    assert_nil result[:image]
    assert_equal 0, RefreshStoreMetadataJob.jobs.size
  end

  test "enqueues a refresh when title is missing" do
    AppstoreService.fetch_image_and_title_for_identifier(@bundle_id)
    assert_equal 1, RefreshStoreMetadataJob.jobs.size
    assert_equal [Grovs::Platforms::IOS, @bundle_id], RefreshStoreMetadataJob.jobs.first["args"]
  end

  test "does not enqueue when title cached and store image fresh" do
    REDIS.set(@title_key, "Cached App", ex: 3600)
    StoreImage.create!(identifier: @bundle_id, platform: Grovs::Platforms::IOS)
    AppstoreService.fetch_image_and_title_for_identifier(@bundle_id)
    assert_equal 0, RefreshStoreMetadataJob.jobs.size
  end

  test "dedups refresh enqueues within the window" do
    AppstoreService.fetch_image_and_title_for_identifier(@bundle_id)
    AppstoreService.fetch_image_and_title_for_identifier(@bundle_id)
    assert_equal 1, RefreshStoreMetadataJob.jobs.size
  end

  private

  def cleanup_redis_keys
    REDIS.del(@title_key, @appstore_id_key, @refresh_key)
  end
end

class AppstoreLookupTest < ActiveSupport::TestCase
  HttpResponse = Struct.new(:code, :body)

  setup do
    @bundle_id = "com.test.lookup.#{SecureRandom.hex(4)}"
    @keys = ["#{Grovs::RedisKeys::TITLE_PREFIX}-ios-#{@bundle_id}",
             "#{Grovs::RedisKeys::APPSTORE_PREFIX}-ios-#{@bundle_id}"]
  end

  teardown do
    REDIS.del(*@keys)
    StoreImage.where(identifier: @bundle_id).destroy_all
  end

  def itunes_hit(title: "Test App", image: "https://img.example.com/a.jpg", id: 99)
    { "resultCount" => 1,
      "results" => [{ "trackName" => title, "artworkUrl512" => image, "trackId" => id }] }.to_json
  end

  test "lookup parses title, image and id from the iTunes response" do
    HTTParty.stub(:get, HttpResponse.new(200, itunes_hit)) do
      result = AppstoreService.send(:get_image_title_id_online, @bundle_id)
      assert_equal "Test App", result[:title]
      assert_equal "https://img.example.com/a.jpg", result[:image]
      assert_equal 99, result[:id]
    end
  end

  test "lookup with no results returns empty response" do
    HTTParty.stub(:get, HttpResponse.new(200, { "resultCount" => 0, "results" => [] }.to_json)) do
      assert_equal({ title: nil, image: nil }, AppstoreService.send(:get_image_title_id_online, @bundle_id))
    end
  end

  test "lookup with non-200 returns empty response" do
    HTTParty.stub(:get, HttpResponse.new(503, "down")) do
      assert_equal({ title: nil, image: nil }, AppstoreService.send(:get_image_title_id_online, @bundle_id))
    end
  end

  test "refresh caches title and creates a StoreImage with the downloaded artwork" do
    responder = lambda do |url|
      url.include?("itunes.apple.com") ? HttpResponse.new(200, itunes_hit) : HttpResponse.new(200, "fake-jpg-bytes")
    end

    HTTParty.stub(:get, responder) do
      AppstoreService.refresh!(@bundle_id)
    end

    assert_equal "Test App", REDIS.get(@keys[0])
    image = StoreImage.find_by(identifier: @bundle_id, platform: Grovs::Platforms::IOS)
    assert image.image.attached?, "artwork must be attached"
    assert_equal "#{@bundle_id}.jpg", image.image.filename.to_s
  end

  test "refresh reuses the existing StoreImage row and refreshes it (no duplicate rows)" do
    stale = StoreImage.create!(identifier: @bundle_id, platform: Grovs::Platforms::IOS, created_at: 2.days.ago)
    responder = lambda do |url|
      url.include?("itunes.apple.com") ? HttpResponse.new(200, itunes_hit) : HttpResponse.new(200, "bytes")
    end

    HTTParty.stub(:get, responder) do
      AppstoreService.refresh!(@bundle_id)
    end

    assert StoreImage.exists?(stale.id), "reuses the same row instead of destroy+create"
    assert_equal 1, StoreImage.where(identifier: @bundle_id, platform: Grovs::Platforms::IOS).count
    stale.reload
    assert stale.image.attached?, "artwork re-attached on the reused row"
    assert stale.created_at > 1.day.ago, "freshness window reset so fetch_* stops re-enqueuing"
  end

  test "refresh without artwork url creates no StoreImage" do
    HTTParty.stub(:get, HttpResponse.new(200, itunes_hit(image: nil))) do
      AppstoreService.refresh!(@bundle_id)
    end
    assert_not StoreImage.exists?(identifier: @bundle_id)
  end

  test "refresh caches nothing when the artwork download fails transiently" do
    responder = lambda do |url|
      url.include?("itunes.apple.com") ? HttpResponse.new(200, itunes_hit) : HttpResponse.new(500, "err")
    end

    HTTParty.stub(:get, responder) do
      AppstoreService.refresh!(@bundle_id)
    end

    assert_nil REDIS.get(@keys[0]), "title must not be pinned for 24h when the image download failed"
    assert_not StoreImage.exists?(identifier: @bundle_id)
  end
end
