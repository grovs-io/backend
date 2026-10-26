require "test_helper"
require "sidekiq/testing"
require_relative "../../../test/integration/auth_test_helper"

class InAppCampaignsApiTest < ActionDispatch::IntegrationTest
  include AuthTestHelper
  include AuditTestHelper
  include InAppFixtures
  fixtures :instances, :users, :instance_roles, :projects, :visitors, :devices

  setup do
    @project = projects(:one)
    entitle!(@project.instance)
    @admin = doorkeeper_headers_for(users(:admin_user))
    @member = doorkeeper_headers_for(users(:member_user))
    clear_in_app_stamps(@project)
  end

  def base = "#{API_PREFIX}/projects/#{@project.id}/in_app_campaigns"
  def body = response.parsed_body
  def valid = { name: "Welcome", content: CONTENT, triggers: TRIGGERS, caps: { lifetime: 3 }, priority: 4 }

  def created(headers = @admin, **attrs)
    post base, params: valid.merge(attrs), headers: headers, as: :json
    assert_response :created
    body["in_app_campaign"]["id"]
  end

  test "needs a token, and membership of the project's instance" do
    get base, headers: { "Host" => "api.sqd.link" }
    assert_response :unauthorized
    get "#{API_PREFIX}/projects/#{projects(:two).id}/in_app_campaigns", headers: @member
    assert_response :forbidden
  end

  test "the list leaves html out of the content and each variant's content; the detail keeps it" do
    campaign = in_app_campaign(@project, template: "html", content: { "html" => "<p>A</p>", "layout" => "modal" },
                                         variants: [{ "id" => "b", "content" => { "html" => "<p>B</p>", "layout" => "modal" } }])
    get base, headers: @member
    row = body["in_app_campaigns"].find { |c| c["id"] == campaign.hashid }
    assert_equal({ "layout" => "modal" }, row["content"])
    assert_equal [{ "id" => "b", "content" => { "layout" => "modal" } }], row["variants"]

    get "#{base}/#{campaign.hashid}", headers: @member
    assert_equal "<p>A</p>", body["in_app_campaign"]["content"]["html"]
    assert_equal "<p>B</p>", body["in_app_campaign"]["variants"][0]["content"]["html"]
  end

  test "a member drafts and edits a campaign, and the draft is audited" do
    id = created(@member)
    assert_equal ["draft", 1, 4, { "lifetime" => 3 }], body["in_app_campaign"].values_at("status", "revision", "priority", "caps")
    assert_equal({ "type" => "all", "segment_id" => nil, "segment_definition_hash" => nil, "segment_changed" => false }, body["in_app_campaign"]["audience"])
    assert AuditEvent.exists?(action: "in_app_campaign.created")

    patch "#{base}/#{id}", params: { name: "Renamed", start_at: "2030-01-01T09:00:00Z" }, headers: @member, as: :json
    assert_response :ok
    assert_equal ["Renamed", "2030-01-01T09:00:00.000Z"], body["in_app_campaign"].values_at("name", "start_at")
  end

  test "refuses a field of the wrong kind and a time that is not one" do
    post base, params: valid.merge(content: "text"), headers: @admin, as: :json
    assert_response :unprocessable_entity
    post base, params: valid.merge(triggers: { type: "event" }), headers: @admin, as: :json
    assert_response :unprocessable_entity
    post base, params: valid.merge(end_at: "tomorrow"), headers: @admin, as: :json
    assert_response :unprocessable_entity
    assert_equal 0, InAppCampaign.count
  end

  test "a member launches, pauses, resumes and ends" do
    id = created(@member)
    { "launch" => :accepted, "pause" => :ok, "resume" => :ok, "end" => :ok }.each do |action, code|
      post "#{base}/#{id}/#{action}", headers: @member, as: :json
      assert_response code, action
    end
    assert_equal "ended", InAppCampaign.last.status
  end

  test "the life of a campaign: launch, pause, resume, end" do
    id = created
    { "launch" => [:accepted, "live"], "pause" => [:ok, "paused"], "resume" => [:ok, "live"], "end" => [:ok, "ended"] }.each do |action, (code, status)|
      post "#{base}/#{id}/#{action}", headers: @admin, as: :json
      assert_response code
      assert_equal status, body["in_app_campaign"]["status"]
    end
    assert_equal %w[in_app_campaign.created in_app_campaign.ended in_app_campaign.launched in_app_campaign.paused in_app_campaign.resumed],
                 AuditEvent.where("action LIKE 'in_app_campaign.%'").pluck(:action).sort
    assert_not_nil InAppCampaign.last.ended_at
  end

  test "each step refuses a campaign in the wrong state" do
    id = created
    %w[pause resume end].each do |action|
      post "#{base}/#{id}/#{action}", headers: @admin, as: :json
      assert_response :conflict
    end
    post "#{base}/#{id}/launch", headers: @admin, as: :json
    post "#{base}/#{id}/launch", headers: @admin, as: :json
    assert_response :conflict
  end

  test "launch answers with the reason when the campaign is not ready" do
    id = created(triggers: [])
    post "#{base}/#{id}/launch", headers: @admin, as: :json
    assert_response :unprocessable_entity
    assert_match(/triggers/, body["error"])
  end

  test "a live campaign is edited by a member, keeps its audience, and gains a revision" do
    id = created
    post "#{base}/#{id}/launch", headers: @admin, as: :json
    patch "#{base}/#{id}", params: { audience: { type: "all" } }, headers: @member, as: :json
    assert_response :unprocessable_entity
    patch "#{base}/#{id}", params: { priority: 9 }, headers: @member, as: :json
    assert_response :ok
    assert_equal [9, 2], body["in_app_campaign"].values_at("priority", "revision")
  end

  test "an ended campaign cannot be edited and only a draft can be deleted" do
    id = created
    post "#{base}/#{id}/launch", headers: @admin, as: :json
    delete "#{base}/#{id}", headers: @admin, as: :json
    assert_response :conflict
    post "#{base}/#{id}/end", headers: @admin, as: :json
    patch "#{base}/#{id}", params: { priority: 9 }, headers: @admin, as: :json
    assert_response :conflict

    draft = created
    delete "#{base}/#{draft}", headers: @admin, as: :json
    assert_response :ok
    assert_equal 1, InAppCampaign.count
  end

  test "a copy is a draft with the same content" do
    id = created
    post "#{base}/#{id}/launch", headers: @admin, as: :json
    post "#{base}/#{id}/duplicate", headers: @admin, as: :json
    assert_response :created
    assert_equal ["Welcome copy", "draft", 1, 4], body["in_app_campaign"].values_at("name", "status", "revision", "priority")
    assert_not_equal id, body["in_app_campaign"]["id"]
  end

  test "a segment audience names a segment of the project, and launching it waits for the audience" do
    segment = Segment.create!(project: @project, name: "S", definition: SEGMENT_DEFINITION)
    post base, params: valid.merge(audience: { type: "segment", segment_id: "nope" }), headers: @admin, as: :json
    assert_response :unprocessable_entity
    id = created(audience: { type: "segment", segment_id: segment.hashid })
    Sidekiq::Testing.fake! { post "#{base}/#{id}/launch", headers: @admin, as: :json }
    assert_response :accepted
    assert_equal "preparing", body["in_app_campaign"]["status"]
    segment.update!(definition: SEGMENT_DEFINITION.merge("operator" => "and"))
    get "#{base}/#{id}", headers: @admin
    assert body["in_app_campaign"]["audience"]["segment_changed"]
  end

  test "the list is newest first, filtered by status and paged" do
    first = created
    second = created
    post "#{base}/#{second}/launch", headers: @admin, as: :json
    get base, headers: @member
    assert_equal [second, first], body["in_app_campaigns"].pluck("id")
    get base, params: { status: "live" }, headers: @member
    assert_equal [second], body["in_app_campaigns"].pluck("id")
    get base, params: { limit: 1 }, headers: @member
    assert_equal [[second], true, second], [body["in_app_campaigns"].pluck("id"), body["truncated"], body["next_after"]]
    get base, params: { limit: 1, after: second }, headers: @member
    assert_equal [[first], false], [body["in_app_campaigns"].pluck("id"), body["truncated"]]
    get base, params: { after: "???" }, headers: @member
    assert_response :unprocessable_entity
  end

  test "another project's campaign is not found" do
    foreign = in_app_campaign(projects(:two))
    get "#{base}/#{foreign.hashid}", headers: @admin
    assert_response :not_found
  end

  test "two people editing at once: the one who saves second is told to reload" do
    id = created
    seen = body["in_app_campaign"]["lock_version"]
    patch "#{base}/#{id}", params: { priority: 2, lock_version: seen }, headers: @admin, as: :json
    assert_response :ok
    assert_equal seen + 1, body["in_app_campaign"]["lock_version"]

    patch "#{base}/#{id}", params: { priority: 9, lock_version: seen }, headers: @member, as: :json
    assert_response :conflict
    assert_equal 2, InAppCampaign.last.priority

    patch "#{base}/#{id}", params: { priority: 9, lock_version: "soon" }, headers: @member, as: :json
    assert_response :unprocessable_entity
  end

  test "settings: read and changed by a member, and a change sends devices back to sync" do
    url = "#{API_PREFIX}/projects/#{@project.id}/in_app_settings"
    get url, headers: @member
    assert_equal({ "enabled" => true, "session_cap" => 10, "day_cap" => 10, "control_group" => 0, "push_daily_cap" => nil }, body["in_app_settings"])
    before = InAppStamps.campaigns(@project.id)
    patch url, params: { day_cap: 3, enabled: false, control_group: 5 }, headers: @member, as: :json
    assert_equal({ "enabled" => false, "session_cap" => 10, "day_cap" => 3, "control_group" => 5, "push_daily_cap" => nil }, body["in_app_settings"])
    assert_not_equal before, InAppStamps.campaigns(@project.id)
    patch url, params: { day_cap: 0 }, headers: @admin, as: :json
    assert_response :unprocessable_entity
    patch url, params: { control_group: 21 }, headers: @admin, as: :json
    assert_response :unprocessable_entity
  end

  B = { "id" => "b", "content" => { "title" => "Hi", "message" => "Back again" } }.freeze

  test "an experiment is set, cleared with null, refused when malformed, and a copy can keep one variant" do
    id = created(control_group: 10, conversion: { event: "checkout", window_hours: 72 }, variants: [B])
    assert_equal [10, { "event" => "checkout", "window_hours" => 72 }, [B]], body["in_app_campaign"].values_at("control_group", "conversion", "variants")

    patch "#{base}/#{id}", params: { variants: "b" }, headers: @admin, as: :json
    assert_response :unprocessable_entity
    patch "#{base}/#{id}", params: { conversion: { event: "" } }, headers: @admin, as: :json
    assert_response :unprocessable_entity
    patch "#{base}/#{id}", params: { conversion: nil, control_group: nil }, headers: @admin, as: :json
    assert_response :ok
    assert_equal [nil, nil, [B]], body["in_app_campaign"].values_at("control_group", "conversion", "variants")

    post "#{base}/#{id}/duplicate", params: { variant: "b" }, headers: @admin, as: :json
    assert_response :created
    copy = body["in_app_campaign"]
    assert_equal ["Hi", nil, nil, nil], [copy["content"]["title"], *copy.values_at("variants", "control_group", "conversion")]
    post "#{base}/#{id}/duplicate", params: { variant: "z" }, headers: @admin, as: :json
    assert_response :unprocessable_entity
    post "#{base}/#{id}/duplicate", headers: @admin, as: :json
    assert_response :created
    assert_equal [B], body["in_app_campaign"]["variants"]
  end
  test "two first saves of the settings at once both succeed" do
    InAppSetting.where(project_id: @project.id).delete_all
    fresh = InAppSetting.new(project: @project)
    calls = 0
    first = lambda do |project|
      calls += 1
      calls == 1 ? fresh.tap { InAppSetting.create!(project: project) } : InAppSetting.find_by!(project_id: project.id)
    end
    InAppSetting.stub(:for, first) do
      patch "#{API_PREFIX}/projects/#{@project.id}/in_app_settings", params: { session_cap: 3 }, headers: @admin, as: :json
    end
    assert_response :ok
    assert_equal [3], InAppSetting.where(project_id: @project.id).pluck(:session_cap)
  end

  test "a value that is missing, out of range or too large answers 422, never 500" do
    big = Array.new(10) { { "type" => "user_attribute", "key" => "k", "op" => "eq", "value" => "v" * 2_000 } }
    link = { "title" => "a", "tap_action" => { "type" => "open_url", "url" => "https:///{{ user.host }}/p" } }
    # These break the request contract on purpose, so the contract check stands aside for them.
    ENV["SKIP_API_CONTRACTS"] = "true"
    [{ priority: nil }, { priority: 10**12 }, { delay_seconds: 3601 }, { conditions: big }].each do |bad|
      post base, params: valid.merge(bad), headers: @admin, as: :json
      assert_response :unprocessable_entity, bad.keys.first.to_s
    end
    patch "#{API_PREFIX}/projects/#{@project.id}/in_app_settings", params: { enabled: nil }, headers: @admin, as: :json
    assert_response :unprocessable_entity
    ENV.delete("SKIP_API_CONTRACTS")

    id = created(content: link)
    post "#{base}/#{id}/launch", headers: @admin, as: :json
    assert_response :unprocessable_entity
  ensure
    ENV.delete("SKIP_API_CONTRACTS")
  end

  test "a member sends a test to a person by identifier; an unknown one and a broken message are refused" do
    visitors(:ios_visitor).update_columns(sdk_identifier: "ana@example.com")
    id = created(@member)
    post "#{base}/#{id}/test", params: { identifier: "ana@example.com" }, headers: @member, as: :json
    assert_response :accepted
    assert_equal 1, body["devices"]
    logged = AuditEvent.order(:id).last
    assert_equal "in_app_campaign.tested", logged.action
    assert_not_includes logged.attributes.to_json, "ana@example.com"

    post "#{base}/#{id}/test", params: { identifier: "nobody" }, headers: @admin, as: :json
    assert_response :unprocessable_entity
    post "#{base}/#{id}/test", params: {}, headers: @admin, as: :json
    assert_response :unprocessable_entity

    broken = created(@member, triggers: [])
    post "#{base}/#{broken}/test", params: { identifier: "ana" }, headers: @admin, as: :json
    assert_response :unprocessable_entity
    assert_match(/triggers/i, body["error"])
  end

  test "a member updates the audience of a launched segment campaign; nothing else has one to update" do
    Sidekiq::Testing.fake! do
      segment = Segment.create!(project: @project, name: "S", definition: SEGMENT_DEFINITION)
      campaign = in_app_campaign(@project, audience_type: "segment", segment: segment)
      post "#{base}/#{campaign.hashid}/update_audience", headers: @admin, as: :json
      assert_response :conflict

      campaign.launch!
      campaign.transition!(from: %w[preparing], to: "live")
      InAppAudienceUpdateJob.jobs.clear
      post "#{base}/#{campaign.hashid}/update_audience", headers: @member, as: :json
      assert_response :conflict
      assert_match(/up to date/, body["error"])
      segment.update_columns(definition_hash: "d" * 64)
      post "#{base}/#{campaign.hashid}/update_audience", headers: @admin, as: :json
      assert_response :accepted
      assert_equal [[campaign.id]], InAppAudienceUpdateJob.jobs.pluck("args")

      post "#{base}/#{created}/update_audience", headers: @admin, as: :json
      assert_response :conflict
    end
  end

end
