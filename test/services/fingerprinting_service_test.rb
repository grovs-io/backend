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

class FingerprintingMatchingTest < ActiveSupport::TestCase
  IOS_UA = "Mozilla/5.0 (iPhone; CPU iPhone OS 17_4 like Mac OS X) " \
           "AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.4 Mobile/15E148 Safari/604.1".freeze
  ANDROID_UA = "Mozilla/5.0 (Linux; Android 14; Pixel 8) AppleWebKit/537.36 " \
               "(KHTML, like Gecko) Chrome/124.0.6367.82 Mobile Safari/537.36".freeze
  ANDROID_UA_OLD = "Mozilla/5.0 (Linux; Android 14; Pixel 8) AppleWebKit/537.36 " \
                   "(KHTML, like Gecko) Chrome/119.0.6045.66 Mobile Safari/537.36".freeze

  EXTRA = { screen_width: 390, screen_height: 844, timezone: "Europe/Bucharest",
            webgl_vendor: "Apple", webgl_renderer: "Apple GPU", language: "en-US" }.freeze

  setup do
    @project_id = SecureRandom.random_number(1_000_000_000..9_999_999_999)
    @project = OpenStruct.new(id: @project_id)
    uid = SecureRandom.uuid
    @ip = "fpmatch-#{uid}"
    @request = OpenStruct.new(ip: @ip, remote_ip: @ip)
    @keys_to_clean = ["fp:#{@ip}:#{@ip}"]
  end

  teardown do
    REDIS.del(*@keys_to_clean)
  end

  def cache(device)
    FingerprintingService.cache_device(device, @request, @project_id)
    @keys_to_clean << "di:#{device.id}:#{@project_id}"
    device
  end

  def make_device(ua:, **overrides) # rubocop:disable Naming/MethodParameterName
    Device.create!(user_agent: ua, ip: "9.9.9.9", remote_ip: "9.9.9.9",
                   platform: "web", **EXTRA.merge(overrides))
  end

  test "returns the single device whose user agent matches and removes it from cache" do
    cached = cache(make_device(ua: ANDROID_UA))
    current = make_device(ua: ANDROID_UA)

    result = FingerprintingService.match_device_for_project(@request, ANDROID_UA, @project, current)

    assert_equal cached.id, result.id
    assert_nil FingerprintingService.match_device_for_project(@request, ANDROID_UA, @project, current),
      "matched device must be consumed from the fingerprint cache"
  end

  test "does not match a cached device from a different platform" do
    cache(make_device(ua: IOS_UA))
    current = make_device(ua: ANDROID_UA)

    assert_nil FingerprintingService.match_device_for_project(@request, ANDROID_UA, @project, current)
  end

  test "does not match the same browser at a different major version" do
    cache(make_device(ua: ANDROID_UA_OLD))
    current = make_device(ua: ANDROID_UA)

    assert_nil FingerprintingService.match_device_for_project(@request, ANDROID_UA, @project, current)
  end

  test "matches iOS webkit devices on webkit version" do
    cached = cache(make_device(ua: IOS_UA))
    current = make_device(ua: IOS_UA)

    result = FingerprintingService.match_device_for_project(@request, IOS_UA, @project, current)
    assert_equal cached.id, result.id
  end

  test "UA collision is resolved by extra device info" do
    cache(make_device(ua: ANDROID_UA, timezone: "America/New_York"))
    winner = cache(make_device(ua: ANDROID_UA, timezone: "Europe/Bucharest"))
    current = make_device(ua: ANDROID_UA, timezone: "Europe/Bucharest")

    result = FingerprintingService.match_device_for_project(@request, ANDROID_UA, @project, current)
    assert_equal winner.id, result.id
  end

  test "fully ambiguous collision attributes nothing" do
    cache(make_device(ua: ANDROID_UA))
    cache(make_device(ua: ANDROID_UA))
    current = make_device(ua: ANDROID_UA)

    assert_nil FingerprintingService.match_device_for_project(@request, ANDROID_UA, @project, current),
      "two indistinguishable devices must not be attributed to either"
  end

  test "collision with nil extra fields attributes nothing" do
    cache(make_device(ua: ANDROID_UA, timezone: nil))
    cache(make_device(ua: ANDROID_UA, timezone: nil))
    current = make_device(ua: ANDROID_UA, timezone: nil)

    assert_nil FingerprintingService.match_device_for_project(@request, ANDROID_UA, @project, current),
      "nil comparison fields must never count as a match"
  end

  test "returns nil when nothing is cached for the fingerprint" do
    current = make_device(ua: ANDROID_UA)
    assert_nil FingerprintingService.match_device_for_project(@request, ANDROID_UA, @project, current)
  end

  test "non-browser user agents still match on identical raw strings" do
    cached = cache(make_device(ua: "weird-raw-agent/1"))
    current = make_device(ua: "weird-raw-agent/1")

    result = FingerprintingService.match_device_for_project(@request, "weird-raw-agent/1", @project, current)
    assert_equal cached.id, result.id
  end
end
