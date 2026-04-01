require "test_helper"

class FingerprintingServiceTest < ActiveSupport::TestCase
  setup do
    @device = Device.create!(user_agent: "Test/1.0 iPhone", ip: "1.1.1.1", remote_ip: "2.2.2.2", platform: "ios")
    @device2 = Device.create!(user_agent: "Test/1.0 Android", ip: "1.1.1.2", remote_ip: "2.2.2.3", platform: "android")
    @test_uuid = SecureRandom.uuid
    # Use a large random project_id to avoid collisions across parallel workers.
    # Rails parallel tests fork separate databases with independent PG sequences,
    # so device IDs can collide. A random project_id keeps reverse-index keys unique.
    @project_id = SecureRandom.random_number(1_000_000_000..9_999_999_999)
    @unique_ip = "fptest-#{@test_uuid}"
    @request = OpenStruct.new(ip: @unique_ip, remote_ip: @unique_ip)
    @fp_key = "fp:#{@unique_ip}:#{@unique_ip}"
    @index_key = "di:#{@device.id}:#{@project_id}"
    @index_key2 = "di:#{@device2.id}:#{@project_id}"
    @keys_to_clean = [@fp_key, @index_key, @index_key2]
  end

  teardown do
    REDIS.del(*@keys_to_clean) unless @keys_to_clean.empty?
  end

  # --- cache_device pipeline: 4 writes in 1 round-trip ---

  test "cache_device stores member in sorted set" do
    freeze_time do
      FingerprintingService.cache_device(@device, @request, @project_id)

      members = REDIS.zrangebyscore(@fp_key, "-inf", "+inf")
      assert_equal 1, members.size
      assert members.first.start_with?("#{@device.id}:#{@project_id}:")
    end
  end

  test "cache_device sets TTL on fingerprint and index keys" do
    FingerprintingService.cache_device(@device, @request, @project_id)

    expected_ttl = Grovs::Links::VALIDITY_MINUTES * 60
    fp_ttl = REDIS.ttl(@fp_key)
    idx_ttl = REDIS.ttl(@index_key)
    assert fp_ttl > 0 && fp_ttl <= expected_ttl, "Expected fp TTL <= #{expected_ttl}, got #{fp_ttl}"
    assert idx_ttl > 0 && idx_ttl <= expected_ttl, "Expected index TTL <= #{expected_ttl}, got #{idx_ttl}"
  end

  test "cache_device adds fingerprint key to reverse index" do
    FingerprintingService.cache_device(@device, @request, @project_id)

    members = REDIS.smembers(@index_key)
    assert_includes members, @fp_key
  end

  test "cache_device stores multiple devices under same fingerprint key" do
    FingerprintingService.cache_device(@device, @request, @project_id)
    FingerprintingService.cache_device(@device2, @request, @project_id)

    members = REDIS.zrangebyscore(@fp_key, "-inf", "+inf")
    assert_equal 2, members.size

    device_ids = members.map { |m| m.split(":").first.to_i }
    assert_includes device_ids, @device.id
    assert_includes device_ids, @device2.id
  end

  # --- find_devices pipeline: cleanup + fetch in 1 round-trip ---

  test "find_devices returns cached devices for the correct project" do
    FingerprintingService.cache_device(@device, @request, @project_id)

    result = FingerprintingService.find_devices(@request, @project_id)
    assert_includes result.map(&:id), @device.id
  end

  test "find_devices returns empty when no cached data exists" do
    result = FingerprintingService.find_devices(@request, @project_id)
    assert_empty result.to_a
  end

  test "find_devices filters by project_id" do
    other_project_id = @project_id + 1
    FingerprintingService.cache_device(@device, @request, other_project_id)
    @keys_to_clean << "di:#{@device.id}:#{other_project_id}"

    result = FingerprintingService.find_devices(@request, @project_id)
    assert_empty result.to_a
  end

  test "find_devices removes expired entries" do
    old_timestamp = (Grovs::Links::VALIDITY_MINUTES + 1).minutes.ago.to_i
    old_member = "#{@device.id}:#{@project_id}:#{old_timestamp}"
    REDIS.zadd(@fp_key, old_timestamp, old_member)

    result = FingerprintingService.find_devices(@request, @project_id)
    assert_empty result.to_a
  end

  # --- remove_device_from_cache_by_id: two-phase pipeline ---

  test "remove_device_from_cache_by_id removes device and cleans index" do
    FingerprintingService.cache_device(@device, @request, @project_id)
    assert_equal 1, REDIS.zcard(@fp_key)

    FingerprintingService.remove_device_from_cache_by_id(@device.id, @project_id)

    assert_equal 0, REDIS.zcard(@fp_key)
    assert_equal false, REDIS.exists?(@index_key)
  end

  test "remove_device_from_cache_by_id is a no-op when device not cached" do
    FingerprintingService.remove_device_from_cache_by_id(@device.id, @project_id)
    assert_equal false, REDIS.exists?(@index_key)
  end

  test "remove_device_from_cache_by_id only removes the targeted device" do
    FingerprintingService.cache_device(@device, @request, @project_id)
    FingerprintingService.cache_device(@device2, @request, @project_id)
    pre_count = REDIS.zcard(@fp_key)
    assert_equal 2, pre_count, "Expected 2 cached devices before removal"

    FingerprintingService.remove_device_from_cache_by_id(@device.id, @project_id)

    remaining = REDIS.zrangebyscore(@fp_key, "-inf", "+inf")
    assert_equal 1, remaining.size
    assert remaining.first.start_with?("#{@device2.id}:")
  end

  # --- round-trip integration ---

  test "full lifecycle: cache, find, remove, verify empty" do
    # Cache
    FingerprintingService.cache_device(@device, @request, @project_id)

    # Verify cached
    cached = REDIS.zrange(@fp_key, 0, -1)
    assert_equal 1, cached.size, "Device should be cached"

    # Find
    found = FingerprintingService.find_devices(@request, @project_id)
    assert_equal 1, found.count

    # Remove and verify at Redis level
    FingerprintingService.remove_device_from_cache_by_id(@device.id, @project_id)
    remaining = REDIS.zrange(@fp_key, 0, -1)
    assert_equal 0, remaining.size, "Sorted set should be empty after removal"

    # Find should return empty
    found_after = FingerprintingService.find_devices(@request, @project_id)
    assert_empty found_after.to_a
  end
end
