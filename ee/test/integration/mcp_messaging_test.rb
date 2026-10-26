require "test_helper"
require_relative "../../../test/integration/mcp_auth_test_helper"
require_relative "../../../test/integration/auth_test_helper"

class McpMessagingTest < ActionDispatch::IntegrationTest
  include McpAuthTestHelper
  include AuthTestHelper
  include AuditTestHelper
  include ClickhouseTestHelper
  include InAppFixtures
  include JourneyFixtures

  fixtures :instances, :users, :instance_roles, :projects, :visitors, :devices

  setup do
    skip_unless_clickhouse!
    @__clickhouse_test_started = true
    @project = projects(:one)
    entitle!(@project.instance)
    clear_in_app_stamps(@project)
    @headers = create_mcp_headers_for(users(:member_user))
    @base = "#{MCP_PREFIX}/projects/#{@project.hashid}"
  end

  def push!(**attrs)
    PushCampaign.create!({ project: @project, name: "Launch", title: "Hi", body: "There", audience_type: "visitors",
                           recipients: %w[a b c] }.merge(attrs))
  end

  def ch_on(&) = Clickhouse.stub(:read_enabled?, true, &)

  test "push list pages with next_after, and show drops the recipient list but keeps the report" do
    older = push!(name: "Older")
    push!(name: "Newer")
    post "#{@base}/push_campaigns/list", params: { limit: 1 }, headers: @headers, as: :json
    assert_response :ok
    assert_equal ["Newer"], json_response["push_campaigns"].map { |c| c["name"] }
    post "#{@base}/push_campaigns/list", params: { limit: 1, after: json_response["next_after"] }, headers: @headers, as: :json
    assert_equal [older.hashid], json_response["push_campaigns"].map { |c| c["id"] }

    post "#{@base}/push_campaigns/#{older.hashid}", headers: @headers, as: :json
    assert_response :ok
    audience = json_response["push_campaign"]["audience"]
    assert_equal 3, audience["recipients_count"]
    assert_not audience.key?("recipients")
    assert json_response["push_campaign"]["report"].key?("delivered")
  end

  test "an ordinary push has no experiment; an A/B push has one; the dashboard keeps its 422" do
    plain = push!
    ab = push!(control_group: 20)
    ch_on do
      post "#{@base}/push_campaigns/#{plain.hashid}/experiment", headers: @headers, as: :json
      assert_response :ok
      assert_nil json_response["experiment"]

      post "#{@base}/push_campaigns/#{ab.hashid}/experiment", headers: @headers, as: :json
      assert_response :ok
      assert_kind_of Hash, json_response["experiment"]

      get "#{API_PREFIX}/projects/#{@project.id}/push_campaigns/#{plain.hashid}/experiment", headers: doorkeeper_headers_for(users(:member_user))
      assert_response :unprocessable_entity
    end
  end

  test "in-app report, experiment under a project-wide control group, and survey comments" do
    plain = live_in_app_campaign(@project)
    survey = live_in_app_campaign(@project, name: "Survey", content: asking)
    ch_on do
      post "#{@base}/in_app_campaigns/#{plain.hashid}/report", headers: @headers, as: :json
      assert_response :ok
      assert json_response.key?("report")

      post "#{@base}/in_app_campaigns/#{plain.hashid}/experiment", headers: @headers, as: :json
      assert_response :ok
      assert_nil json_response["experiment"]

      InAppSetting.create!(project: @project, control_group: 5)
      post "#{@base}/in_app_campaigns/#{plain.hashid}/experiment", headers: @headers, as: :json
      assert_response :ok
      assert_kind_of Hash, json_response["experiment"], "project control alone makes the campaign measurable"

      post "#{@base}/in_app_campaigns/#{survey.hashid}/comments", headers: @headers, as: :json
      assert_response :ok

      post "#{@base}/in_app_campaigns/list", headers: @headers, as: :json
      assert_equal %w[Survey Welcome], json_response["in_app_campaigns"].map { |c| c["name"] }
    end
  end

  test "journey list and report" do
    j = live_journey(@project)
    ch_on do
      post "#{@base}/journeys/list", headers: @headers, as: :json
      assert_response :ok
      assert_equal [j.hashid], json_response["journeys"].map { |r| r["id"] }

      post "#{@base}/journeys/#{j.hashid}/report", headers: @headers, as: :json
      assert_response :ok
      assert json_response.key?("report")
    end
  end
end
