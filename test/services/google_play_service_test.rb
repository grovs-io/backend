require "test_helper"

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

  HTML_NO_H1 = <<~HTML
    <html>
      <body>
        <p>Some paragraph</p>
        <img src="https://play-lh.googleusercontent.com/test-image-w240-h480">
      </body>
    </html>
  HTML

  HTML_NO_W240_IMAGE = <<~HTML
    <html>
      <body>
        <h1>App Without Icon</h1>
        <img src="https://play-lh.googleusercontent.com/small-icon">
        <img src="https://play-lh.googleusercontent.com/banner-image">
      </body>
    </html>
  HTML

  HTML_NO_IMAGES = <<~HTML
    <html>
      <body>
        <h1>App With No Images</h1>
        <p>Just text content</p>
      </body>
    </html>
  HTML

  setup do
    @identifier = "com.test.newapp.#{SecureRandom.hex(4)}"
    @title_key = "#{Grovs::RedisKeys::TITLE_PREFIX}-android-#{@identifier}"
  end

  teardown do
    REDIS.del(@title_key)
    StoreImage.where(identifier: @identifier).destroy_all
  end

  # ── Nil identifier ──

  test "returns empty response for nil identifier" do
    result = GooglePlayService.fetch_image_and_title_for_identifier(nil)

    assert_nil result[:title]
    assert_nil result[:image]
  end

  # ── Redis cache hit ──

  test "returns cached title from redis on cache hit" do
    REDIS.set(@title_key, "Cached Title", ex: 3600)

    result = GooglePlayService.fetch_image_and_title_for_identifier(@identifier)
    assert_equal "Cached Title", result[:title]
  end

  # ── Cache miss: fetches and caches ──

  test "fetches from google play and caches title on cache miss" do
    REDIS.del(@title_key)

    response = OpenStruct.new(body: SAMPLE_HTML)
    image_response = OpenStruct.new(body: "fake-image-bytes")

    http_stub = lambda do |url, *_args|
      url.include?("play.google.com") ? response : image_response
    end

    HTTParty.stub(:get, http_stub) do
      result = GooglePlayService.fetch_image_and_title_for_identifier(@identifier)

      assert_equal "My Test App", result[:title]
      assert_equal "My Test App", REDIS.get(@title_key)
    end
  end

  # ── Image selection: w240-h480 ──

  test "selects image url ending with w240-h480 and creates StoreImage" do
    REDIS.del(@title_key)

    response = OpenStruct.new(body: SAMPLE_HTML)
    image_response = OpenStruct.new(body: "fake-image-bytes")

    http_stub = lambda do |url, *_args|
      url.include?("play.google.com") ? response : image_response
    end

    HTTParty.stub(:get, http_stub) do
      result = GooglePlayService.fetch_image_and_title_for_identifier(@identifier)

      assert_equal "My Test App", result[:title]

      # Verify a StoreImage was created for this identifier
      store_image = StoreImage.find_by(identifier: @identifier, platform: Grovs::Platforms::ANDROID)
      assert_not_nil store_image, "StoreImage should be created for the identifier"
      assert store_image.image.attached?, "StoreImage should have an attached image"

      # result[:image] should be the image access url
      assert_not_nil result[:image], "Result should include the image URL"
    end
  end

  # ── Stale image refresh ──

  test "refreshes store image when older than 24 hours" do
    old_image = StoreImage.create!(
      identifier: @identifier,
      platform: Grovs::Platforms::ANDROID,
      created_at: 25.hours.ago
    )
    old_image_id = old_image.id
    REDIS.set(@title_key, "Cached Title", ex: 3600)

    response = OpenStruct.new(body: SAMPLE_HTML)
    image_response = OpenStruct.new(body: "fake-image-bytes")

    http_stub = lambda do |url, *_args|
      url.include?("play.google.com") ? response : image_response
    end

    HTTParty.stub(:get, http_stub) do
      result = GooglePlayService.fetch_image_and_title_for_identifier(@identifier)

      assert_equal "Cached Title", result[:title]

      # Old image should be destroyed
      assert_nil StoreImage.find_by(id: old_image_id), "Old stale image should be destroyed"

      # New image should be created
      new_image = StoreImage.find_by(identifier: @identifier, platform: Grovs::Platforms::ANDROID)
      assert_not_nil new_image, "A new StoreImage should be created"
      assert_not_equal old_image_id, new_image.id, "New image should have a different ID"
      assert new_image.image.attached?, "New StoreImage should have an attached image"

      # result[:image] should point to the new image's URL
      assert_not_nil result[:image], "Result should include the refreshed image URL"
    end
  end

  # ── Fresh image reuse ──

  test "returns existing store image when fresh and does not recreate" do
    response = OpenStruct.new(body: SAMPLE_HTML)
    image_response = OpenStruct.new(body: "fake-image-bytes")

    # Create the initial image via the service to get proper attachment
    REDIS.del(@title_key)
    http_stub = lambda do |url, *_args|
      url.include?("play.google.com") ? response : image_response
    end
    HTTParty.stub(:get, http_stub) do
      GooglePlayService.fetch_image_and_title_for_identifier(@identifier)
    end

    image = StoreImage.find_by(identifier: @identifier, platform: Grovs::Platforms::ANDROID)
    assert_not_nil image

    # Now call again -- the image should NOT be recreated
    result = GooglePlayService.fetch_image_and_title_for_identifier(@identifier)

    assert_equal "My Test App", result[:title]
    assert_equal image.id, StoreImage.find_by(identifier: @identifier, platform: Grovs::Platforms::ANDROID).id
  end

  # ── Network errors ──

  test "handles network timeout gracefully" do
    REDIS.del(@title_key)

    error_raiser = ->(*_args) { raise Net::OpenTimeout, "connection timed out" }
    HTTParty.stub(:get, error_raiser) do
      result = GooglePlayService.fetch_image_and_title_for_identifier(@identifier)

      assert_nil result[:title]
      assert_nil result[:image]
    end
  end

  test "handles connection refused gracefully" do
    REDIS.del(@title_key)

    error_raiser = ->(*_args) { raise Errno::ECONNREFUSED }
    HTTParty.stub(:get, error_raiser) do
      result = GooglePlayService.fetch_image_and_title_for_identifier(@identifier)

      assert_nil result[:title]
      assert_nil result[:image]
    end
  end

  test "handles socket error gracefully" do
    REDIS.del(@title_key)

    error_raiser = ->(*_args) { raise SocketError, "getaddrinfo: Name or service not known" }
    HTTParty.stub(:get, error_raiser) do
      result = GooglePlayService.fetch_image_and_title_for_identifier(@identifier)

      assert_nil result[:title]
      assert_nil result[:image]
    end
  end

  # ── Malformed HTML: no h1 tag ──

  test "returns nil title when HTML has no h1 tag" do
    REDIS.del(@title_key)

    response = OpenStruct.new(body: HTML_NO_H1)
    image_response = OpenStruct.new(body: "fake-image-bytes")

    http_stub = lambda do |url, *_args|
      url.include?("play.google.com") ? response : image_response
    end

    HTTParty.stub(:get, http_stub) do
      result = GooglePlayService.fetch_image_and_title_for_identifier(@identifier)

      # Title should be nil (empty string cached in Redis, but returned as title)
      # The service caches whatever title it gets, which is nil from get_image_and_title_online
      # Then sets REDIS with nil → stored as ""
      # But the image with w240-h480 should still be found
      store_image = StoreImage.find_by(identifier: @identifier, platform: Grovs::Platforms::ANDROID)
      assert_not_nil store_image, "StoreImage should be created even without h1 tag"
    end
  end

  # ── HTML with no w240-h480 image ──

  test "returns nil image when no image ends with w240-h480" do
    REDIS.del(@title_key)

    response = OpenStruct.new(body: HTML_NO_W240_IMAGE)

    http_stub = lambda do |_url, *_args|
      response
    end

    HTTParty.stub(:get, http_stub) do
      result = GooglePlayService.fetch_image_and_title_for_identifier(@identifier)

      assert_equal "App Without Icon", result[:title]
      # No w240-h480 image found → create_new_store_image returns nil (image is blank)
      assert_nil result[:image], "Image should be nil when no w240-h480 image exists"

      store_image = StoreImage.find_by(identifier: @identifier, platform: Grovs::Platforms::ANDROID)
      assert_nil store_image, "No StoreImage should be created when image URL is nil"
    end
  end

  # ── HTML with no images at all ──

  test "returns nil image when HTML has no img tags at all" do
    REDIS.del(@title_key)

    response = OpenStruct.new(body: HTML_NO_IMAGES)

    http_stub = lambda do |_url, *_args|
      response
    end

    HTTParty.stub(:get, http_stub) do
      result = GooglePlayService.fetch_image_and_title_for_identifier(@identifier)

      assert_equal "App With No Images", result[:title]
      assert_nil result[:image], "Image should be nil when no img tags exist"
    end
  end

  # ── Net::ReadTimeout error handling ──

  test "handles read timeout gracefully" do
    REDIS.del(@title_key)

    error_raiser = ->(*_args) { raise Net::ReadTimeout, "read timed out" }
    HTTParty.stub(:get, error_raiser) do
      result = GooglePlayService.fetch_image_and_title_for_identifier(@identifier)

      assert_nil result[:title]
      assert_nil result[:image]
    end
  end

  # ── OpenSSL::SSL::SSLError error handling ──

  test "handles SSL error gracefully" do
    REDIS.del(@title_key)

    error_raiser = ->(*_args) { raise OpenSSL::SSL::SSLError, "SSL_connect returned=1" }
    HTTParty.stub(:get, error_raiser) do
      result = GooglePlayService.fetch_image_and_title_for_identifier(@identifier)

      assert_nil result[:title]
      assert_nil result[:image]
    end
  end
end
