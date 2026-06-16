require "test_helper"

class AppstoreServiceTest < ActiveSupport::TestCase
  setup do
    @bundle_id = "com.test.pipelining.#{SecureRandom.hex(4)}"
    @title_key = "#{Grovs::RedisKeys::TITLE_PREFIX}-ios-#{@bundle_id}"
    @appstore_id_key = "#{Grovs::RedisKeys::APPSTORE_PREFIX}-ios-#{@bundle_id}"
    cleanup_redis_keys
  end

  teardown do
    cleanup_redis_keys
  end

  test "returns cached title and appstore_id when present in redis" do
    REDIS.set(@title_key, "Cached App", ex: 3600)
    REDIS.set(@appstore_id_key, "12345", ex: 3600)

    StoreImage.stub(:find_by, nil) do
      AppstoreService.stub(:create_new_store_image, nil) do
        result = AppstoreService.fetch_image_and_title_for_identifier(@bundle_id)

        assert_equal "Cached App", result[:title]
        assert_equal "12345", result[:appstore_id]
      end
    end
  end

  test "fetches from API and caches both values when redis is empty" do
    api_response = { title: "New App", image: "https://example.com/icon.png", id: "67890" }

    AppstoreService.stub(:get_image_title_id_online, api_response) do
      StoreImage.stub(:find_by, nil) do
        AppstoreService.stub(:create_new_store_image, nil) do
          result = AppstoreService.fetch_image_and_title_for_identifier(@bundle_id)

          assert_equal "New App", result[:title]
          assert_equal "67890", result[:appstore_id]

          # Verify both values were cached in a single pipeline
          assert_equal "New App", REDIS.get(@title_key)
          assert_equal "67890", REDIS.get(@appstore_id_key)

          # Verify TTL was set on both keys
          assert REDIS.ttl(@title_key) > 0
          assert REDIS.ttl(@appstore_id_key) > 0
        end
      end
    end
  end

  test "returns empty response for nil bundle_id" do
    result = AppstoreService.fetch_image_and_title_for_identifier(nil)

    assert_nil result[:title]
    assert_nil result[:image]
  end

  test "does not call API when cache is populated" do
    REDIS.set(@title_key, "Already Cached", ex: 3600)
    REDIS.set(@appstore_id_key, "11111", ex: 3600)

    api_called = false
    AppstoreService.stub(:get_image_title_id_online, lambda { |_|
      api_called = true
      { title: "Should Not See", image: nil, id: "99999" }
    }) do
      StoreImage.stub(:find_by, nil) do
        AppstoreService.stub(:create_new_store_image, nil) do
          result = AppstoreService.fetch_image_and_title_for_identifier(@bundle_id)

          assert_equal "Already Cached", result[:title]
          assert_equal false, api_called
        end
      end
    end
  end

  test "caches nil title from API without error" do
    api_response = { title: nil, image: nil, id: nil }

    AppstoreService.stub(:get_image_title_id_online, api_response) do
      StoreImage.stub(:find_by, nil) do
        AppstoreService.stub(:create_new_store_image, nil) do
          result = AppstoreService.fetch_image_and_title_for_identifier(@bundle_id)

          assert_nil result[:title]
          assert_nil result[:appstore_id]
        end
      end
    end
  end

  private

  def cleanup_redis_keys
    REDIS.del(@title_key, @appstore_id_key)
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

  test "full fetch creates a StoreImage with the downloaded artwork attached" do
    responder = lambda do |url|
      url.include?("itunes.apple.com") ? HttpResponse.new(200, itunes_hit) : HttpResponse.new(200, "fake-jpg-bytes")
    end

    result = HTTParty.stub(:get, responder) do
      AppstoreService.fetch_image_and_title_for_identifier(@bundle_id)
    end

    assert_equal "Test App", result[:title]
    assert_equal 99, result[:appstore_id]
    image = StoreImage.find_by(identifier: @bundle_id, platform: Grovs::Platforms::IOS)
    assert image.image.attached?, "artwork must be attached"
    assert_equal "#{@bundle_id}.jpg", image.image.filename.to_s
  end

  test "stale StoreImage is replaced on fetch" do
    stale = StoreImage.create!(identifier: @bundle_id, platform: Grovs::Platforms::IOS,
                               created_at: 2.days.ago)
    responder = lambda do |url|
      url.include?("itunes.apple.com") ? HttpResponse.new(200, itunes_hit) : HttpResponse.new(200, "bytes")
    end

    HTTParty.stub(:get, responder) do
      AppstoreService.fetch_image_and_title_for_identifier(@bundle_id)
    end

    assert_not StoreImage.exists?(stale.id), "stale image row must be destroyed"
    assert StoreImage.exists?(identifier: @bundle_id, platform: Grovs::Platforms::IOS)
  end

  test "fetch without artwork url returns nil image and creates no StoreImage" do
    HTTParty.stub(:get, HttpResponse.new(200, itunes_hit(image: nil))) do
      result = AppstoreService.fetch_image_and_title_for_identifier(@bundle_id)
      assert_nil result[:image]
    end
    assert_not StoreImage.exists?(identifier: @bundle_id)
  end
end
