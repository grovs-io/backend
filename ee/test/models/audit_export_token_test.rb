require "test_helper"

class AuditExportTokenTest < ActiveSupport::TestCase
  fixtures :instances, :users

  setup do
    @instance = instances(:one)
    @user = users(:admin_user)
  end

  test "generate_token stores a SHA256 digest and round-trips through find_by_plain_token" do
    token = AuditExportToken.new(instance: @instance, created_by_user: @user, name: "Splunk")
    plain = token.generate_token
    token.save!

    assert_equal Digest::SHA256.hexdigest(plain), token.token_digest
    assert_equal token.id, AuditExportToken.find_by_plain_token(plain).id # rubocop:disable Rails/DynamicFindBy
  end

  test "revoked tokens are not found" do
    token = AuditExportToken.new(instance: @instance, created_by_user: @user, name: "Splunk")
    plain = token.generate_token
    token.save!
    token.revoke!

    assert_nil AuditExportToken.find_by_plain_token(plain) # rubocop:disable Rails/DynamicFindBy
  end

  test "blank token is not found" do
    assert_nil AuditExportToken.find_by_plain_token("") # rubocop:disable Rails/DynamicFindBy
  end
end
