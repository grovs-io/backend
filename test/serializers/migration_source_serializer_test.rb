require "test_helper"

class MigrationSourceSerializerTest < ActiveSupport::TestCase
  fixtures :projects, :instances, :domains, :redirect_configs, :custom_hostnames, :migration_sources

  setup do
    @source = migration_sources(:acme_branch)
    @source.update!(credentials: { "branch_key" => "key_live_SHOULD_NOT_LEAK" })
  end

  test "credentials NEVER appear in serializer output (security-critical)" do
    h = MigrationSourceSerializer.serialize(@source)
    assert_not h.key?("credentials"), "credentials key leaked into serialized output"
    assert_not h.values.any? { |v| v.to_s.include?("SHOULD_NOT_LEAK") }, "credential value leaked into output"
  end

  test "emits the declared attributes plus computed health" do
    h = MigrationSourceSerializer.serialize(@source)
    expected_keys = %w[id provider old_host enabled consecutive_failures
                       first_failure_at last_error_status created_at updated_at health]
    expected_keys.each { |k| assert h.key?(k), "missing key #{k}" }
  end

  test "health is the string form of the model method (matches contract enum)" do
    @source.update_columns(consecutive_failures: 5, first_failure_at: Time.current)
    h = MigrationSourceSerializer.serialize(@source.reload)
    assert_equal "degraded", h["health"]
  end

  test "serializes a list" do
    arr = MigrationSourceSerializer.serialize([@source])
    assert_kind_of Array, arr
    assert_equal 1, arr.size
    assert_not arr.first.key?("credentials")
  end
end
