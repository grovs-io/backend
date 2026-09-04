require "test_helper"
require_relative "auth_test_helper"

class InstancesApiTest < ActionDispatch::IntegrationTest
  include AuthTestHelper

  fixtures :instances, :users, :instance_roles, :projects, :domains,
           :redirect_configs, :applications, :ios_configurations,
           :android_configurations, :web_configurations

  setup do
    @admin_user = users(:admin_user)
    @member_user = users(:member_user)
    @super_admin = users(:super_admin_user)
    @instance = instances(:one)
    @instance_two = instances(:two)
  end

  # --- List Instances ---

  test "list returns only instances user belongs to" do
    headers = doorkeeper_headers_for(@admin_user)
    get "#{API_PREFIX}/instances", headers: headers
    assert_response :ok
    json = JSON.parse(response.body)
    instance_ids = json["instances"].map { |i| i["id"] }
    assert_includes instance_ids, @instance.id
    assert_not_includes instance_ids, @instance_two.id, "must not return instances user doesn't belong to"
  end

  test "list omits an instance that has lost its test project" do
    @instance.test.destroy!
    headers = doorkeeper_headers_for(@admin_user)
    get "#{API_PREFIX}/instances", headers: headers
    assert_response :ok
    instance_ids = JSON.parse(response.body)["instances"].map { |i| i["id"] }
    assert_not_includes instance_ids, @instance.id, "an instance without both projects is not a dashboard instance"
  end

  # --- Instance Details ---

  test "member gets correct instance details with all SDK setup flags" do
    headers = doorkeeper_headers_for(@member_user)
    get "#{API_PREFIX}/instances/#{@instance.id}", headers: headers
    assert_response :ok
    json = JSON.parse(response.body)
    assert_equal @instance.id, json["instance"]["id"]

    setup = json["get_started_setup"]
    assert setup.key?("ios_sdk"), "must include ios_sdk flag"
    assert setup.key?("android_sdk"), "must include android_sdk flag"
    assert setup.key?("web_sdk"), "must include web_sdk flag"

    # Instance :one has ios, android, and web configurations via fixtures
    assert_equal true, setup["ios_sdk"], "ios_sdk should be true when configuration exists"
    assert_equal true, setup["android_sdk"], "android_sdk should be true when configuration exists"
    assert_equal true, setup["web_sdk"], "web_sdk should be true when configuration exists"
  end

  test "get_started_setup reports false for SDKs without configuration" do
    headers = doorkeeper_headers_for(@super_admin)
    # Instance :two has only an ios_app (second_ios_app) with no configuration
    get "#{API_PREFIX}/instances/#{@instance_two.id}", headers: headers
    assert_response :ok
    setup = JSON.parse(response.body)["get_started_setup"]

    assert_equal false, setup["ios_sdk"], "ios_sdk should be false without configuration"
    assert_equal false, setup["android_sdk"], "android_sdk should be false without application"
    assert_equal false, setup["web_sdk"], "web_sdk should be false without application"
  end

  test "non-member gets 403 with no data leak" do
    headers = doorkeeper_headers_for(@admin_user)
    get "#{API_PREFIX}/instances/#{@instance_two.id}", headers: headers
    assert_response :forbidden
    json = JSON.parse(response.body)
    assert_not json.key?("instance"), "403 must not contain instance data"
    assert_not json.key?("get_started_setup"), "403 must not leak setup data"
  end

  # --- Add Member (Admin-Only) ---

  test "admin can add member and role is persisted" do
    headers = doorkeeper_headers_for(@admin_user)
    assert_difference "InstanceRole.count", 1 do
      post "#{API_PREFIX}/instances/#{@instance.id}/members",
        params: { email: "newmember@example.com", role: "member" },
        headers: headers
    end
    assert_response :ok
    json = JSON.parse(response.body)
    assert_equal "member", json["role_added"]["role"]

    new_user = User.find_by(email: "newmember@example.com")
    assert_not_nil new_user
    assert InstanceRole.exists?(user_id: new_user.id, instance_id: @instance.id)
  end

  test "self-hosted mode returns a working copyable invite_url for a new member" do
    ENV["GROVS_SELF_HOSTED"] = "true"
    ENV["REACT_HOST_PROTOCOL"] = "https://"
    ENV["REACT_HOST"] = "dash.example.com"
    headers = doorkeeper_headers_for(@admin_user)

    post "#{API_PREFIX}/instances/#{@instance.id}/members",
      params: { email: "sh-invitee@example.com", role: "member" },
      headers: headers

    assert_response :ok
    json = JSON.parse(response.body)
    assert json["invite_url"].present?, "self-hosted response must include invite_url"
    assert_match %r{\Ahttps://dash\.example\.com/accept-invite\?token=.+}, json["invite_url"]

    # token in the URL must be a real, valid pending invitation
    token = json["invite_url"].split("token=").last
    found = User.find_by_invitation_token(token, true)
    assert_equal "sh-invitee@example.com", found&.email, "invite_url token must accept the invitation"
  ensure
    ENV.delete("GROVS_SELF_HOSTED")
    ENV.delete("REACT_HOST_PROTOCOL")
    ENV.delete("REACT_HOST")
  end

  test "self-hosted add_member succeeds without SMTP (no synchronous invitation email)" do
    ENV["GROVS_SELF_HOSTED"] = "true"
    ENV["REACT_HOST_PROTOCOL"] = "https://"
    ENV["REACT_HOST"] = "dash.example.com"
    headers = doorkeeper_headers_for(@admin_user)

    # Simulate a broken mailer (no SMTP): the synchronous Devise invite email would
    # 500 the request in production. Self-hosted must skip it and still return invite_url.
    Devise::Mailer.stub(:invitation_instructions, ->(*) { raise "SMTP unavailable" }) do
      post "#{API_PREFIX}/instances/#{@instance.id}/members",
        params: { email: "no-smtp-invitee@example.com", role: "member" },
        headers: headers
    end

    assert_response :ok
    assert JSON.parse(response.body)["invite_url"].present?,
           "invite_url must be returned even when the mailer is unavailable"
  ensure
    ENV.delete("GROVS_SELF_HOSTED")
    ENV.delete("REACT_HOST_PROTOCOL")
    ENV.delete("REACT_HOST")
  end

  test "self-hosted re-adding a pending invitee to another instance returns a fresh invite_url" do
    ENV["GROVS_SELF_HOSTED"] = "true"
    ENV["REACT_HOST_PROTOCOL"] = "https://"
    ENV["REACT_HOST"] = "dash.example.com"
    headers = doorkeeper_headers_for(@admin_user)

    post "#{API_PREFIX}/instances/#{@instance.id}/members",
      params: { email: "pending-twice@example.com", role: "member" }, headers: headers
    assert_response :ok
    first_url = JSON.parse(response.body)["invite_url"]

    InstanceRole.create!(role: Grovs::Roles::ADMIN, instance_id: @instance_two.id, user_id: @admin_user.id)
    post "#{API_PREFIX}/instances/#{@instance_two.id}/members",
      params: { email: "pending-twice@example.com", role: "member" }, headers: headers
    assert_response :ok
    second_url = JSON.parse(response.body)["invite_url"]
    assert second_url.present?, "a pending invitee must get a fresh invite link, not just the added-to-project mail"
    assert_not_equal first_url, second_url
  ensure
    ENV.delete("GROVS_SELF_HOSTED")
    ENV.delete("REACT_HOST_PROTOCOL")
    ENV.delete("REACT_HOST")
  end

  test "add_member returns 200 with invite_url when smtp delivery fails" do
    ENV["GROVS_SELF_HOSTED"] = "true"
    ENV["MAILER_DELIVERY_METHOD"] = "smtp"
    ENV["REACT_HOST_PROTOCOL"] = "https://"
    ENV["REACT_HOST"] = "dash.example.com"
    headers = doorkeeper_headers_for(@admin_user)

    boom = ->(*) { raise Net::SMTPFatalError, "554 Message rejected: Email address is not verified" }
    Devise::Mailer.stub(:invitation_instructions, boom) do
      post "#{API_PREFIX}/instances/#{@instance.id}/members",
        params: { email: "smtp-fail-member@example.com", role: "member" },
        headers: headers
    end

    assert_response :ok
    assert JSON.parse(response.body)["invite_url"].present?,
           "a rejected invite email must not 500 the request; the copyable link must survive"
  ensure
    ENV.delete("GROVS_SELF_HOSTED")
    ENV.delete("MAILER_DELIVERY_METHOD")
    ENV.delete("REACT_HOST_PROTOCOL")
    ENV.delete("REACT_HOST")
  end

  test "non-self-hosted add-member response has NO invite_url (SaaS response unchanged)" do
    ENV.delete("GROVS_SELF_HOSTED")
    headers = doorkeeper_headers_for(@admin_user)

    post "#{API_PREFIX}/instances/#{@instance.id}/members",
      params: { email: "saas-invitee@example.com", role: "member" },
      headers: headers

    assert_response :ok
    json = JSON.parse(response.body)
    assert_not json.key?("invite_url"), "SaaS response must not include invite_url"
    assert_equal "member", json["role_added"]["role"]
  end

  test "member cannot add member (admin-only) and no role is created" do
    headers = doorkeeper_headers_for(@member_user)
    assert_no_difference "InstanceRole.count" do
      post "#{API_PREFIX}/instances/#{@instance.id}/members",
        params: { email: "another@example.com", role: "member" },
        headers: headers
    end
    assert_response :forbidden
  end

  # --- Revenue Collection Toggle (Admin-Only) ---

  test "member cannot toggle revenue_collection_enabled" do
    @instance.update!(revenue_collection_enabled: false)
    headers = doorkeeper_headers_for(@member_user)
    put "#{API_PREFIX}/instances/#{@instance.id}/revenue_collection",
      params: { revenue_collection_enabled: true }, headers: headers
    assert_response :forbidden
    assert_not @instance.reload.revenue_collection_enabled,
      "member must not be able to flip the revenue flag"
  end

  test "admin can toggle revenue_collection_enabled" do
    @instance.update!(revenue_collection_enabled: false)
    headers = doorkeeper_headers_for(@admin_user)
    put "#{API_PREFIX}/instances/#{@instance.id}/revenue_collection",
      params: { revenue_collection_enabled: true }, headers: headers
    assert_response :ok
    assert @instance.reload.revenue_collection_enabled
  end

  # --- Remove Member (Admin-Only) ---

  test "admin can remove member and role is deleted" do
    headers = doorkeeper_headers_for(@admin_user)
    assert_difference "InstanceRole.count", -1 do
      delete "#{API_PREFIX}/instances/#{@instance.id}/members",
        params: { email: @member_user.email },
        headers: headers
    end
    assert_response :ok
    assert_equal "User deleted", JSON.parse(response.body)["message"]
    assert_not InstanceRole.exists?(user_id: @member_user.id, instance_id: @instance.id),
      "member role must be removed from DB"
  end

  test "admin cannot remove self" do
    headers = doorkeeper_headers_for(@admin_user)
    assert_no_difference "InstanceRole.count" do
      delete "#{API_PREFIX}/instances/#{@instance.id}/members",
        params: { email: @admin_user.email },
        headers: headers
    end
    assert_response :forbidden
  end

  # --- Members List ---

  test "member can list instance members with correct data" do
    headers = doorkeeper_headers_for(@member_user)
    get "#{API_PREFIX}/instances/#{@instance.id}/members", headers: headers
    assert_response :ok
    json = JSON.parse(response.body)
    assert_kind_of Array, json["members"]
    # Members are serialized as {role:, user: {email:, ...}}
    emails = json["members"].map { |m| m.dig("user", "email") }
    assert_includes emails, @admin_user.email
    assert_includes emails, @member_user.email
  end

  # --- User Role ---

  test "user gets correct role for instance" do
    headers = doorkeeper_headers_for(@member_user)
    get "#{API_PREFIX}/instances/#{@instance.id}/role", headers: headers
    assert_response :ok
    json = JSON.parse(response.body)
    assert_equal "member", json["role"]["role"]
  end

  # --- Delete Instance (Admin-Only) ---

  test "member cannot delete instance and record persists" do
    headers = doorkeeper_headers_for(@member_user)
    assert_no_difference "Instance.count" do
      delete "#{API_PREFIX}/instances/#{@instance.id}", headers: headers
    end
    assert_response :forbidden
  end

  test "admin can delete instance and roles are removed" do
    headers = doorkeeper_headers_for(@admin_user)
    # Instance deletion is async (DeleteInstanceJob), but roles are removed synchronously
    role_count = InstanceRole.where(instance_id: @instance.id).count
    assert role_count > 0, "precondition: instance must have roles"

    delete "#{API_PREFIX}/instances/#{@instance.id}", headers: headers
    assert_response :ok
    assert_equal "Instance deleted", JSON.parse(response.body)["message"]
    assert_equal 0, InstanceRole.where(instance_id: @instance.id).count,
      "all instance roles must be removed synchronously"
  end
end

class InstancesLifecycleTest < ActionDispatch::IntegrationTest
  include AuthTestHelper

  fixtures :instances, :users, :instance_roles, :projects, :domains, :redirect_configs

  setup do
    @admin_user = users(:admin_user)
    @member_user = users(:member_user)
    @instance = instances(:one)
    @admin_headers = doorkeeper_headers_for(@admin_user)
  end

  # --- create_instance ---

  test "create_instance provisions instance with two projects and admin role" do
    assert_difference ["Instance.count"], 1 do
      assert_difference ["Project.count"], 2 do
        post "#{API_PREFIX}/instances", params: { name: "Fresh Workspace" },
          headers: @admin_headers
      end
    end

    assert_response :ok
    created = Instance.order(:id).last
    assert created.production.present?, "must have a production project"
    assert created.test.present?, "must have a test project"
    assert_equal "Fresh Workspace", created.production.name
    role = InstanceRole.find_by(instance_id: created.id, user_id: @admin_user.id)
    assert_equal Grovs::Roles::ADMIN, role.role, "creator must be instance admin"
  end

  test "self-hosted create_instance returns invite_urls for members invited at creation" do
    ENV["GROVS_SELF_HOSTED"] = "true"
    ENV["REACT_HOST_PROTOCOL"] = "https://"
    ENV["REACT_HOST"] = "dash.example.com"

    post "#{API_PREFIX}/instances",
      params: { name: "SH Multi", members: [
        { email: "sh-create-a@example.com", role: "member" },
        { email: "sh-create-b@example.com", role: "admin" },
        { email: @member_user.email, role: "member" }
      ] },
      headers: @admin_headers

    assert_response :ok
    urls = JSON.parse(response.body)["invite_urls"]
    assert_equal %w[sh-create-a@example.com sh-create-b@example.com], urls.keys.sort,
                 "one link per freshly-invited user; existing users get none"
    urls.each_value do |url|
      assert_match %r{\Ahttps://dash\.example\.com/accept-invite\?token=.+}, url
      token = url.split("token=").last
      assert User.find_by_invitation_token(token, true), "each token must be a valid pending invitation"
    end
  ensure
    ENV.delete("GROVS_SELF_HOSTED")
    ENV.delete("REACT_HOST_PROTOCOL")
    ENV.delete("REACT_HOST")
  end

  test "create_instance returns 200 with invite_urls when smtp delivery fails" do
    ENV["GROVS_SELF_HOSTED"] = "true"
    ENV["MAILER_DELIVERY_METHOD"] = "smtp"
    ENV["REACT_HOST_PROTOCOL"] = "https://"
    ENV["REACT_HOST"] = "dash.example.com"

    boom = ->(*) { raise Net::SMTPFatalError, "554 Message rejected: Email address is not verified" }
    Devise::Mailer.stub(:invitation_instructions, boom) do
      post "#{API_PREFIX}/instances",
        params: { name: "SMTP Fail Multi", members: [{ email: "smtp-fail-create@example.com", role: "member" }] },
        headers: @admin_headers
    end

    assert_response :ok
    json = JSON.parse(response.body)
    assert json["invite_urls"]&.key?("smtp-fail-create@example.com"),
           "a rejected invite email must not 500 creation; the copyable link must survive"
  ensure
    ENV.delete("GROVS_SELF_HOSTED")
    ENV.delete("MAILER_DELIVERY_METHOD")
    ENV.delete("REACT_HOST_PROTOCOL")
    ENV.delete("REACT_HOST")
  end

  test "non-self-hosted create_instance response has NO invite_urls (SaaS unchanged)" do
    post "#{API_PREFIX}/instances",
      params: { name: "SaaS Multi", members: [{ email: "saas-create@example.com", role: "member" }] },
      headers: @admin_headers

    assert_response :ok
    assert_not JSON.parse(response.body).key?("invite_urls"), "SaaS response must not include invite_urls"
  end

  test "create_instance with blank name returns 400 and creates nothing" do
    assert_no_difference ["Instance.count", "Project.count"] do
      post "#{API_PREFIX}/instances", params: { name: "" }, headers: @admin_headers
    end
    assert_response :bad_request
  end

  # --- edit_instance ---

  test "edit_instance renames both production and test projects" do
    put "#{API_PREFIX}/instances/#{@instance.id}", params: { name: "Renamed" },
      headers: @admin_headers

    assert_response :ok
    assert_equal "Renamed", @instance.reload.production.name
    assert_equal "Renamed-test", @instance.test.name
  end

  test "edit_instance as member returns 403 and does not rename" do
    original = @instance.production.name
    put "#{API_PREFIX}/instances/#{@instance.id}", params: { name: "Hijacked" },
      headers: doorkeeper_headers_for(@member_user)

    assert_response :forbidden
    assert_equal original, @instance.reload.production.name
  end

  # --- dismiss_get_started ---

  test "dismiss_get_started persists the flag" do
    @instance.update_columns(get_started_dismissed: false)

    post "#{API_PREFIX}/instances/#{@instance.id}/dismiss_get_started",
      headers: @admin_headers

    assert_response :ok
    assert @instance.reload.get_started_dismissed
  end

  # --- setup progress ---

  test "complete_setup_step records the step and setup_progress lists it" do
    post "#{API_PREFIX}/instances/#{@instance.id}/setup_progress/complete",
      params: { category: "ios_setup", step_identifier: "add_sdk" },
      headers: @admin_headers
    assert_response :ok

    get "#{API_PREFIX}/instances/#{@instance.id}/setup_progress",
      headers: @admin_headers
    assert_response :ok
    steps = JSON.parse(response.body)["steps"]
    found = steps.find { |s| s["step_identifier"] == "add_sdk" }
    assert found, "completed step must be listed"
    assert_equal "ios_setup", found["category"]
    assert found["completed_at"].present?
  end

  test "complete_setup_step is idempotent and keeps the original completion time" do
    post "#{API_PREFIX}/instances/#{@instance.id}/setup_progress/complete",
      params: { category: "android_setup", step_identifier: "intent_filters" },
      headers: @admin_headers
    first_completed_at = @instance.setup_progress_steps
                                  .find_by(step_identifier: "intent_filters").completed_at

    post "#{API_PREFIX}/instances/#{@instance.id}/setup_progress/complete",
      params: { category: "android_setup", step_identifier: "intent_filters" },
      headers: @admin_headers
    assert_response :ok

    assert_equal 1, @instance.setup_progress_steps.where(step_identifier: "intent_filters").count
    assert_equal first_completed_at,
                 @instance.setup_progress_steps.find_by(step_identifier: "intent_filters").completed_at
  end

  test "setup_progress filters by category" do
    post "#{API_PREFIX}/instances/#{@instance.id}/setup_progress/complete",
      params: { category: "ios_setup", step_identifier: "register_app" }, headers: @admin_headers
    post "#{API_PREFIX}/instances/#{@instance.id}/setup_progress/complete",
      params: { category: "android_setup", step_identifier: "google_play_notifications" }, headers: @admin_headers

    get "#{API_PREFIX}/instances/#{@instance.id}/setup_progress",
      params: { category: "ios_setup" }, headers: @admin_headers

    steps = JSON.parse(response.body)["steps"]
    assert steps.any? { |s| s["step_identifier"] == "register_app" }
    assert_not steps.any? { |s| s["step_identifier"] == "google_play_notifications" },
      "category filter must exclude other categories"
  end
end
