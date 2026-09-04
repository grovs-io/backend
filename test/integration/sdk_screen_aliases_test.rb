require "test_helper"
require_relative "auth_test_helper"

class SdkScreenAliasesTest < ActionDispatch::IntegrationTest
  include AuthTestHelper

  fixtures :instances, :projects, :applications, :ios_configurations,
           :android_configurations, :devices, :visitors, :domains, :redirect_configs

  setup do
    @project = projects(:one)
    @visitor = visitors(:ios_visitor)
    @headers = sdk_headers_for(@project, @visitor, platform: "ios")
  end

  # --- Auth ---

  test "without SDK headers returns 403" do
    post "#{SDK_PREFIX}/screen_aliases",
      params: { screen_aliases: [{ identifier: "HomeVC", alias: "Home" }] },
      headers: { "Host" => sdk_host },
      as: :json
    assert_response :forbidden
  end

  # --- Validation ---

  test "non-array screen_aliases returns 400" do
    post "#{SDK_PREFIX}/screen_aliases",
      params: { screen_aliases: "not_an_array" },
      headers: @headers,
      as: :json
    assert_response :bad_request
    assert_equal "screen_aliases must be an array", JSON.parse(response.body)["error"]
  end

  test "empty array returns 400" do
    post "#{SDK_PREFIX}/screen_aliases",
      params: { screen_aliases: [] },
      headers: @headers,
      as: :json
    assert_response :bad_request
    assert_equal "screen_aliases must not be empty", JSON.parse(response.body)["error"]
  end

  test "exceeding max aliases returns 400" do
    aliases = 201.times.map { |i| { identifier: "Screen#{i}", alias: "S#{i}" } }
    post "#{SDK_PREFIX}/screen_aliases",
      params: { screen_aliases: aliases },
      headers: @headers,
      as: :json
    assert_response :bad_request
    assert_match(/max 200/, JSON.parse(response.body)["error"])
  end

  # --- Happy Path ---

  test "creates screen aliases and returns saved count" do
    count_before = ScreenAlias.where(project: @project).count

    post "#{SDK_PREFIX}/screen_aliases",
      params: {
        screen_aliases: [
          { identifier: "ChatViewController", alias: "Chat" },
          { identifier: "HomeViewController", alias: "Home" },
          { identifier: "CheckoutFragment", alias: "Checkout" }
        ]
      },
      headers: @headers,
      as: :json

    assert_response :ok
    json = JSON.parse(response.body)
    assert_equal 3, json["saved"]
    assert_equal count_before + 3, ScreenAlias.where(project: @project).count

    alias_record = ScreenAlias.find_by(project: @project, screen_identifier: "ChatViewController")
    assert_not_nil alias_record
    assert_equal "Chat", alias_record.alias_name
  end

  test "malformed (non-object) array entries are skipped, not 500" do
    post "#{SDK_PREFIX}/screen_aliases",
      params: { screen_aliases: ["bad", 42, { identifier: "RealVC", alias: "Real" }] },
      headers: @headers,
      as: :json

    assert_response :ok
    assert_equal 1, JSON.parse(response.body)["saved"], "only the valid object entry should be saved"
    assert ScreenAlias.exists?(project: @project, screen_identifier: "RealVC")
  end

  # --- Upsert ---

  test "upsert updates alias_name and updated_at for existing identifier" do
    # Create the record with an explicitly old updated_at so the DB's
    # CURRENT_TIMESTAMP during upsert is guaranteed to be newer.
    record = ScreenAlias.create!(project: @project, screen_identifier: "HomeVC", alias_name: "Old Home")
    record.update_columns(updated_at: 1.minute.ago)
    original_updated_at = record.reload.updated_at
    count_before = ScreenAlias.where(project: @project).count

    post "#{SDK_PREFIX}/screen_aliases",
      params: { screen_aliases: [{ identifier: "HomeVC", alias: "New Home" }] },
      headers: @headers,
      as: :json

    assert_response :ok
    assert_equal count_before, ScreenAlias.where(project: @project).count
    record.reload
    assert_equal "New Home", record.alias_name
    assert_operator record.updated_at, :>, original_updated_at, "updated_at must be bumped on upsert"
  end

  # --- Blank entries skipped ---

  test "blank identifier or alias entries are skipped" do
    post "#{SDK_PREFIX}/screen_aliases",
      params: {
        screen_aliases: [
          { identifier: "", alias: "Chat" },
          { identifier: "HomeVC", alias: "" },
          { identifier: "SettingsVC", alias: "Settings" }
        ]
      },
      headers: @headers,
      as: :json

    assert_response :ok
    json = JSON.parse(response.body)
    assert_equal 1, json["saved"]
    assert_not_nil ScreenAlias.find_by(project: @project, screen_identifier: "SettingsVC")
    assert_nil ScreenAlias.find_by(project: @project, screen_identifier: "HomeVC")
  end

  # --- Duplicate identifiers in same request ---

  test "duplicate identifiers in same request last one wins" do
    post "#{SDK_PREFIX}/screen_aliases",
      params: {
        screen_aliases: [
          { identifier: "HomeVC", alias: "Home v1" },
          { identifier: "HomeVC", alias: "Home v2" }
        ]
      },
      headers: @headers,
      as: :json

    assert_response :ok
    assert_equal 1, ScreenAlias.where(project: @project, screen_identifier: "HomeVC").count
    assert_equal "Home v2", ScreenAlias.find_by(project: @project, screen_identifier: "HomeVC").alias_name
  end

  # --- Tenant isolation ---

  test "aliases are isolated per project" do
    other_project = projects(:two)
    ScreenAlias.create!(project: other_project, screen_identifier: "HomeVC", alias_name: "Other Home")

    post "#{SDK_PREFIX}/screen_aliases",
      params: { screen_aliases: [{ identifier: "HomeVC", alias: "My Home" }] },
      headers: @headers,
      as: :json

    assert_response :ok
    assert_equal "My Home", ScreenAlias.find_by(project: @project, screen_identifier: "HomeVC").alias_name
    assert_equal "Other Home", ScreenAlias.find_by(project: other_project, screen_identifier: "HomeVC").alias_name,
      "other project's alias must not be affected"
  end
end
