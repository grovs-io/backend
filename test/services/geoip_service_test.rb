# frozen_string_literal: true

require "test_helper"

class GeoipServiceTest < ActiveSupport::TestCase
  # Build a real MaxMindDB::Result from a raw hash, exercising the exact
  # same code path the gem uses when parsing an .mmdb file.
  def maxmind_result(data)
    MaxMindDB::Result.new(data)
  end

  # Wraps a MaxMindDB::Result in a fake DB object that returns it for any IP.
  def fake_db_returning(result)
    db = Object.new
    db.define_singleton_method(:lookup) { |_ip| result }
    db
  end

  # =====================================================================
  # Happy path — full data
  # =====================================================================

  test "returns country and city from a real MaxMindDB::Result" do
    result = maxmind_result(
      'country' => { 'iso_code' => 'US', 'names' => { 'en' => 'United States' } },
      'city' => { 'names' => { 'en' => 'San Francisco' } }
    )
    db = fake_db_returning(result)

    geo = GeoipService.lookup("8.8.8.8", db: db)
    assert_equal "US", geo[:country]
    assert_equal "San Francisco", geo[:city]
  end

  test "passes IP through to DB lookup" do
    received_ip = nil
    result = maxmind_result('country' => { 'iso_code' => 'DE' }, 'city' => { 'names' => { 'en' => 'Berlin' } })
    db = Object.new
    db.define_singleton_method(:lookup) { |ip| received_ip = ip; result }

    GeoipService.lookup("203.0.113.42", db: db)
    assert_equal "203.0.113.42", received_ip
  end

  test "handles IPv6 address" do
    received_ip = nil
    result = maxmind_result('country' => { 'iso_code' => 'JP' }, 'city' => { 'names' => { 'en' => 'Tokyo' } })
    db = Object.new
    db.define_singleton_method(:lookup) { |ip| received_ip = ip; result }

    geo = GeoipService.lookup("2001:4860:4860::8888", db: db)
    assert_equal "2001:4860:4860::8888", received_ip
    assert_equal "JP", geo[:country]
    assert_equal "Tokyo", geo[:city]
  end

  # =====================================================================
  # Partial results — real-world: VPNs, proxies, satellite IPs
  # =====================================================================

  test "country present but city missing returns empty city string" do
    result = maxmind_result('country' => { 'iso_code' => 'GB' })
    db = fake_db_returning(result)

    geo = GeoipService.lookup("1.2.3.4", db: db)
    assert_equal "GB", geo[:country]
    assert_equal "", geo[:city], "Missing city should be empty string, not nil"
  end

  test "city present but country iso_code missing returns empty country string" do
    result = maxmind_result('city' => { 'names' => { 'en' => 'Somewhere' } })
    db = fake_db_returning(result)

    geo = GeoipService.lookup("1.2.3.4", db: db)
    assert_equal "", geo[:country], "Missing iso_code should be empty string, not nil"
    assert_equal "Somewhere", geo[:city]
  end

  test "country exists but iso_code is nil returns empty string" do
    result = maxmind_result('country' => { 'names' => { 'en' => 'Unknown' } })
    db = fake_db_returning(result)

    geo = GeoipService.lookup("1.2.3.4", db: db)
    assert_equal "", geo[:country], "nil iso_code must become empty string via .to_s"
  end

  test "both country and city objects exist but have no name data" do
    result = maxmind_result('country' => {}, 'city' => { 'names' => {} })
    db = fake_db_returning(result)

    geo = GeoipService.lookup("1.2.3.4", db: db)
    assert_equal "", geo[:country]
    assert_equal "", geo[:city]
  end

  # =====================================================================
  # Not found — DB has no entry for this IP
  # =====================================================================

  test "returns empty strings when IP not found in DB" do
    result = maxmind_result({})
    assert_not result.found?, "Precondition: empty hash should not be found"

    db = fake_db_returning(result)

    geo = GeoipService.lookup("198.51.100.1", db: db)
    assert_equal "", geo[:country]
    assert_equal "", geo[:city]
  end

  # =====================================================================
  # Nil / blank input guards
  # =====================================================================

  test "nil IP returns empty strings without touching DB" do
    geo = GeoipService.lookup(nil)
    assert_equal "", geo[:country]
    assert_equal "", geo[:city]
  end

  test "empty string IP returns empty strings without touching DB" do
    geo = GeoipService.lookup("")
    assert_equal "", geo[:country]
    assert_equal "", geo[:city]
  end

  test "nil DB returns empty strings" do
    geo = GeoipService.lookup("8.8.8.8", db: nil)
    assert_equal "", geo[:country]
    assert_equal "", geo[:city]
  end

  # =====================================================================
  # Error handling — DB corrupt, network issue, etc.
  # =====================================================================

  test "rescues StandardError from lookup and returns empty strings" do
    db = Object.new
    db.define_singleton_method(:lookup) { |_ip| raise StandardError, "corrupt DB" }

    geo = GeoipService.lookup("8.8.8.8", db: db)
    assert_equal "", geo[:country]
    assert_equal "", geo[:city]
  end

  test "rescues IOError from lookup" do
    db = Object.new
    db.define_singleton_method(:lookup) { |_ip| raise IOError, "file read error" }

    geo = GeoipService.lookup("8.8.8.8", db: db)
    assert_equal "", geo[:country]
    assert_equal "", geo[:city]
  end

  # =====================================================================
  # Return value contract — callers depend on :country and :city keys
  # =====================================================================

  test "return value always has exactly :country and :city keys" do
    scenarios = [
      -> { GeoipService.lookup(nil) },
      -> { GeoipService.lookup("", db: nil) },
      -> { GeoipService.lookup("8.8.8.8", db: fake_db_returning(maxmind_result({}))) },
      -> { GeoipService.lookup("8.8.8.8", db: fake_db_returning(maxmind_result('country' => { 'iso_code' => 'FR' }, 'city' => { 'names' => { 'en' => 'Paris' } }))) }
    ]

    scenarios.each_with_index do |scenario, i|
      result = scenario.call
      assert_instance_of Hash, result, "Scenario #{i}: must return Hash"
      assert result.key?(:country), "Scenario #{i}: must have :country key"
      assert result.key?(:city), "Scenario #{i}: must have :city key"
      assert_instance_of String, result[:country], "Scenario #{i}: :country must be String"
      assert_instance_of String, result[:city], "Scenario #{i}: :city must be String"
    end
  end
end
