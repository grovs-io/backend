require "test_helper"
require_relative "../../../test/integration/auth_test_helper"

class AuditExportTokensApiTest < ActionDispatch::IntegrationTest
  include AuthTestHelper
  include AuditTestHelper

  fixtures :instances, :users, :instance_roles

  setup do
    @instance = instances(:one)
    @admin = users(:admin_user)
    @member = users(:member_user)
    entitle!(@instance)
  end

  test "admin creates a token, sees the plain value once, and an audit event is written" do
    post "#{API_PREFIX}/instances/#{@instance.id}/audit_export_tokens", params: { name: "Splunk" },
         headers: doorkeeper_headers_for(@admin)
    assert_response :created
    json = JSON.parse(response.body)
    assert json["token"].start_with?("aet_")
    assert_equal "Splunk", json["audit_export_token"]["name"]
    assert_equal 1, AuditEvent.where(instance_id: @instance.id, action: "audit_export_token.created").count

    get "#{API_PREFIX}/instances/#{@instance.id}/audit_export_tokens", headers: doorkeeper_headers_for(@admin)
    assert_response :ok
    list = JSON.parse(response.body)["audit_export_tokens"]
    assert_equal 1, list.size
    assert_not list[0].key?("token")
  end

  test "revoke stops the token working and is audited" do
    token = AuditExportToken.new(instance: @instance, created_by_user: @admin, name: "X")
    plain = token.generate_token
    token.save!

    delete "#{API_PREFIX}/instances/#{@instance.id}/audit_export_tokens/#{token.hashid}", headers: doorkeeper_headers_for(@admin)
    assert_response :ok
    assert_nil AuditExportToken.find_by_plain_token(plain) # rubocop:disable Rails/DynamicFindBy
    assert_equal 1, AuditEvent.where(instance_id: @instance.id, action: "audit_export_token.revoked").count
  end

  test "member cannot manage tokens" do
    post "#{API_PREFIX}/instances/#{@instance.id}/audit_export_tokens", params: { name: "X" },
         headers: doorkeeper_headers_for(@member)
    assert_response :forbidden
  end

  test "unentitled instance cannot create tokens" do
    unentitle!(@instance)
    post "#{API_PREFIX}/instances/#{@instance.id}/audit_export_tokens", params: { name: "X" },
         headers: doorkeeper_headers_for(@admin)
    assert_response :forbidden
  end

  test "name is required" do
    post "#{API_PREFIX}/instances/#{@instance.id}/audit_export_tokens", params: {},
         headers: doorkeeper_headers_for(@admin)
    assert_response :unprocessable_entity
  end
end
