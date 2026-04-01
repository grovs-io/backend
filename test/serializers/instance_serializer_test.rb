require "test_helper"

class InstanceSerializerTest < ActiveSupport::TestCase
  fixtures :instances, :projects, :domains

  # ---------------------------------------------------------------------------
  # 1. VALUE VERIFICATION — assert_equal for every attribute
  # ---------------------------------------------------------------------------

  test "serializes instance one with correct attribute values" do
    instance = instances(:one)
    result = InstanceSerializer.serialize(instance)

    assert_equal instance.id,      result["id"]
    assert_equal "test_api_key_001", result["api_key"]
    assert_equal "testapp",          result["uri_scheme"]
    assert_equal false,              result["get_started_dismissed"]
    assert_equal false,              result["quota_exceeded"]
    assert_equal true,               result["revenue_collection_enabled"]
  end

  test "serializes instance two with correct attribute values" do
    instance = instances(:two)
    result = InstanceSerializer.serialize(instance)

    assert_equal instance.id,      result["id"]
    assert_equal "test_api_key_002", result["api_key"]
    assert_equal "testapp2",         result["uri_scheme"]
    assert_equal false,              result["revenue_collection_enabled"]
  end

  # ---------------------------------------------------------------------------
  # 2. HASH_ID — uses hashid, not raw id
  # ---------------------------------------------------------------------------

  test "hash_id equals record hashid for instance one" do
    instance = instances(:one)
    result = InstanceSerializer.serialize(instance)

    assert_equal instance.hashid, result["hash_id"]
  end

  test "hash_id equals record hashid for instance two" do
    instance = instances(:two)
    result = InstanceSerializer.serialize(instance)

    assert_equal instance.hashid, result["hash_id"]
  end

  # ---------------------------------------------------------------------------
  # 3. NESTED PRODUCTION/TEST PROJECTS — verify actual values
  # ---------------------------------------------------------------------------

  test "nested production project has correct values" do
    instance = instances(:one)
    result = InstanceSerializer.serialize(instance)

    assert_instance_of Hash, result["production"]
    assert_equal instance.production.id, result["production"]["id"]
    assert_equal "Test Project",         result["production"]["name"]
    assert_equal "test-project-001",     result["production"]["identifier"]
    assert_equal false,                  result["production"]["test"]
    assert_equal instance.production.hashid, result["production"]["hash_id"]
  end

  test "nested test project has correct values" do
    instance = instances(:one)
    result = InstanceSerializer.serialize(instance)

    assert_instance_of Hash, result["test"]
    assert_equal instance.test.id, result["test"]["id"]
    assert_equal "Test Environment Project", result["test"]["name"]
    assert_equal "test-env-project-001",     result["test"]["identifier"]
    assert_equal true,                       result["test"]["test"]
    assert_equal instance.test.hashid,       result["test"]["hash_id"]
  end

  test "production and test are nil when instance has no projects" do
    instance = instances(:one)
    instance.stub(:production, nil) do
      instance.stub(:test, nil) do
        result = InstanceSerializer.serialize(instance)
        assert_nil result["production"]
        assert_nil result["test"]
      end
    end
  end

  # ---------------------------------------------------------------------------
  # 4. EXCLUSION — internal fields must NOT appear
  # ---------------------------------------------------------------------------

  test "excludes created_at test_id and production_id" do
    result = InstanceSerializer.serialize(instances(:one))

    %w[created_at test_id production_id].each do |field|
      assert_not_includes result.keys, field,
        "Expected serialized output to exclude '#{field}'"
    end
  end

  test "top-level keys include expected fields" do
    result = InstanceSerializer.serialize(instances(:one))

    expected_keys = %w[api_key get_started_dismissed hash_id id production quota_exceeded revenue_collection_enabled test updated_at uri_scheme]
    assert_equal expected_keys, result.keys.sort
  end

  # ---------------------------------------------------------------------------
  # 5. NIL HANDLING
  # ---------------------------------------------------------------------------

  test "returns nil for nil input" do
    assert_nil InstanceSerializer.serialize(nil)
  end

  # ---------------------------------------------------------------------------
  # 6. COLLECTION HANDLING
  # ---------------------------------------------------------------------------

  test "serializes a collection with correct size and distinct values" do
    instance_list = [instances(:one), instances(:two)]
    result = InstanceSerializer.serialize(instance_list)

    assert_equal 2, result.size
    assert_equal "testapp",              result[0]["uri_scheme"]
    assert_equal "testapp2",             result[1]["uri_scheme"]
    assert_equal instances(:one).hashid, result[0]["hash_id"]
    assert_equal instances(:two).hashid, result[1]["hash_id"]
  end

  test "collection items have distinct hash_ids" do
    instance_list = [instances(:one), instances(:two)]
    result = InstanceSerializer.serialize(instance_list)

    hash_ids = result.map { |r| r["hash_id"] }
    assert_equal 2, hash_ids.uniq.size
  end

  test "serializes empty collection as empty array" do
    result = InstanceSerializer.serialize([])
    assert_equal [], result
  end
end
