require "test_helper"
require "sidekiq/testing"

class GooglePlayServiceTest < ActiveSupport::TestCase
  fixtures :store_images

  SAMPLE_HTML = <<~HTML
    <html>
      <body>
        <h1>My Test App</h1>
        <img src="https://play-lh.googleusercontent.com/test-image-w240-h480">
        <img src="https://play-lh.googleusercontent.com/other-image">
      </body>
    </html>
  HTML

  HTML_NO_W240_IMAGE = <<~HTML
    <html>
      <body>
        <h1>App Without Icon</h1>
        <img src="https://play-lh.googleusercontent.com/small-icon">
      </body>
    </html>
  HTML

  setup do
    @identifier = "com.test.newapp.#{SecureRandom.hex(4)}"
    @title_key = "#{Grovs::RedisKeys::TITLE_PREFIX}-android-#{@identifier}"
    @refresh_key = "store_meta_refresh:android:#{@identifier}"
    Sidekiq::Testing.fake!
    RefreshStoreMetadataJob.jobs.clear
    REDIS.del(@title_key, @refresh_key)
  end

  teardown do
    REDIS.del(@title_key, @refresh_key)
    StoreImage.where(identifier: @identifier).destroy_all
    RefreshStoreMetadataJob.jobs.clear
    Sidekiq::Testing.disable!
  end

  def stub_get(html)
    lambda do |url, *_args|
      if url.include?("play.google.com")
        OpenStruct.new(body: html)
      else
        OpenStruct.new(code: 200, body: "fake-image-bytes")
      end
    end
  end

  # ── Hot path (read-only, never blocks) ──

  test "returns empty response for nil identifier" do
    result = GooglePlayService.fetch_image_and_title_for_identifier(nil)
    assert_nil result[:title]
    assert_nil result[:image]
    assert_equal 0, RefreshStoreMetadataJob.jobs.size
  end

  test "returns cached title from redis without any network call" do
    REDIS.set(@title_key, "Cached Title", ex: 3600)
    result = GooglePlayService.fetch_image_and_title_for_identifier(@identifier)
    assert_equal "Cached Title", result[:title]
  end

  test "enqueues a refresh when title is missing" do
    GooglePlayService.fetch_image_and_title_for_identifier(@identifier)
    assert_equal 1, RefreshStoreMetadataJob.jobs.size
    assert_equal [Grovs::Platforms::ANDROID, @identifier], RefreshStoreMetadataJob.jobs.first["args"]
  end

  test "does not enqueue when title cached and store image fresh" do
    REDIS.set(@title_key, "Cached Title", ex: 3600)
    StoreImage.create!(identifier: @identifier, platform: Grovs::Platforms::ANDROID)
    GooglePlayService.fetch_image_and_title_for_identifier(@identifier)
    assert_equal 0, RefreshStoreMetadataJob.jobs.size
  end

  test "enqueues a refresh when store image is stale" do
    REDIS.set(@title_key, "Cached Title", ex: 3600)
    StoreImage.create!(identifier: @identifier, platform: Grovs::Platforms::ANDROID, created_at: 25.hours.ago)
    GooglePlayService.fetch_image_and_title_for_identifier(@identifier)
    assert_equal 1, RefreshStoreMetadataJob.jobs.size
  end

  test "dedups refresh enqueues within the window" do
    GooglePlayService.fetch_image_and_title_for_identifier(@identifier)
    GooglePlayService.fetch_image_and_title_for_identifier(@identifier)
    assert_equal 1, RefreshStoreMetadataJob.jobs.size
  end

  # ── refresh! (the background work) ──

  test "refresh caches title and creates a StoreImage with attached artwork" do
    HTTParty.stub(:get, stub_get(SAMPLE_HTML)) do
      GooglePlayService.refresh!(@identifier)
    end
    assert_equal "My Test App", REDIS.get(@title_key)
    image = StoreImage.find_by(identifier: @identifier, platform: Grovs::Platforms::ANDROID)
    assert_not_nil image
    assert image.image.attached?
  end

  test "refresh reuses the existing StoreImage row and refreshes it (no duplicate rows)" do
    old = StoreImage.create!(identifier: @identifier, platform: Grovs::Platforms::ANDROID, created_at: 25.hours.ago)
    HTTParty.stub(:get, stub_get(SAMPLE_HTML)) do
      GooglePlayService.refresh!(@identifier)
    end
    assert StoreImage.exists?(old.id), "reuses the same row instead of destroy+create"
    assert_equal 1, StoreImage.where(identifier: @identifier, platform: Grovs::Platforms::ANDROID).count
    old.reload
    assert old.image.attached?, "artwork re-attached on the reused row"
    assert old.created_at > 1.day.ago, "freshness window reset so fetch_* stops re-enqueuing"
  end

  test "refresh caches nothing when the artwork download fails transiently" do
    responder = lambda do |url, *_args|
      url.include?("play.google.com") ? OpenStruct.new(body: SAMPLE_HTML) : OpenStruct.new(code: 500, body: "err")
    end
    HTTParty.stub(:get, responder) do
      GooglePlayService.refresh!(@identifier)
    end
    assert_nil REDIS.get(@title_key), "title must not be pinned for 24h when the image download failed"
    assert_nil StoreImage.find_by(identifier: @identifier, platform: Grovs::Platforms::ANDROID)
  end

  test "refresh creates no StoreImage when no w240-h480 image exists" do
    HTTParty.stub(:get, ->(*_) { OpenStruct.new(body: HTML_NO_W240_IMAGE) }) do
      GooglePlayService.refresh!(@identifier)
    end
    assert_nil StoreImage.find_by(identifier: @identifier, platform: Grovs::Platforms::ANDROID)
  end

  test "refresh swallows network errors and creates nothing" do
    [Net::OpenTimeout, Net::ReadTimeout, SocketError, Errno::ECONNREFUSED, OpenSSL::SSL::SSLError].each do |err|
      HTTParty.stub(:get, ->(*_) { raise err }) do
        assert_nothing_raised { GooglePlayService.refresh!(@identifier) }
      end
      assert_nil StoreImage.find_by(identifier: @identifier, platform: Grovs::Platforms::ANDROID)
    end
  end
end
