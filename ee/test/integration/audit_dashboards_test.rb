require "test_helper"
require_relative "../../../test/integration/auth_test_helper"

class AuditDashboardsTest < ActionDispatch::IntegrationTest
  include AuthTestHelper
  include AuditTestHelper

  fixtures :instances, :users, :instance_roles, :projects, :dashboards, :dashboard_widgets

  setup do
    @instance = instances(:one)
    @project = @instance.production
    entitle!(@instance)
    @headers = doorkeeper_headers_for(users(:admin_user))
    @base = "#{API_PREFIX}/projects/#{@project.id}/dashboards"
  end

  def events(action)
    AuditEvent.where(instance_id: @instance.id, action: action).order(:sequence)
  end

  def create_dashboard(name)
    post @base, params: { name: name }, headers: @headers, as: :json
    assert_response :ok
    JSON.parse(response.body)["dashboard"]["id"]
  end

  test "create, rename and delete each record one event with the dashboard as target" do
    id = create_dashboard("Audited")
    created = events("dashboard.created").last
    assert_equal({ "type" => "dashboard", "id" => id }, created.target)
    assert_equal "Audited", created.changes_data["after"]["name"]

    patch "#{@base}/#{id}", params: { name: "Renamed" }, headers: @headers, as: :json
    assert_response :ok
    renamed = events("dashboard.updated").last
    assert_equal "Audited", renamed.changes_data["before"]["name"]
    assert_equal "Renamed", renamed.changes_data["after"]["name"]

    assert_difference -> { events("dashboard.deleted").count }, 1 do
      delete "#{@base}/#{id}", headers: @headers
    end
    assert_response :ok
    assert_equal "Renamed", events("dashboard.deleted").last.changes_data["before"]["name"]
  end

  test "widget add, update and remove are recorded as dashboard updates naming the widget" do
    id = create_dashboard("Widgets")
    post "#{@base}/#{id}/widgets", headers: @headers, as: :json,
                                   params: { title: "Installs", viz: "number", size: "sm", query: { metric: "installs" }, filters: [] }
    assert_response :ok
    wid = JSON.parse(response.body)["widget"]["id"]
    added = events("dashboard.updated").last
    assert_equal({ "type" => "dashboard", "id" => id, "widget_id" => wid }, added.target)
    assert_equal({ "widget" => "added", "title" => "Installs" }, added.changes_data)

    patch "#{@base}/#{id}/widgets/#{wid}", params: { title: "All installs" }, headers: @headers, as: :json
    assert_response :ok
    assert_equal({ "widget" => "updated", "title" => "All installs" }, events("dashboard.updated").last.changes_data)

    delete "#{@base}/#{id}/widgets/#{wid}", headers: @headers
    assert_response :ok
    assert_equal({ "widget" => "removed", "title" => "All installs" }, events("dashboard.updated").last.changes_data)
  end

  test "rejected requests record nothing" do
    assert_no_difference -> { AuditEvent.where(instance_id: @instance.id).count } do
      post @base, params: { name: "" }, headers: @headers, as: :json
      assert_response :unprocessable_entity
      patch "#{@base}/0", params: { name: "x" }, headers: @headers, as: :json
      assert_response :not_found
    end
  end
end
