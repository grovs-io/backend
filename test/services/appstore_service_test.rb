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
