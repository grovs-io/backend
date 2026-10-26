require "test_helper"
require_relative "../../../test/integration/auth_test_helper"

class AuditSmartBannersTest < ActionDispatch::IntegrationTest
  include AuthTestHelper
  include AuditTestHelper
  include SmartBannerTestHelper

  fixtures :instances, :users, :instance_roles, :projects, :domains, :redirect_configs

  setup do
    @instance = instances(:one)
    @project = projects(:one)
    entitle!(@instance)
    @headers = doorkeeper_headers_for(users(:admin_user))
    @base = "#{API_PREFIX}/projects/#{@project.id}/smart_banners"
  end

  def events
    AuditEvent.where(instance_id: @instance.id).order(:sequence)
  end

  test "create, update, reorder and delete are audited" do
    post @base, params: { smart_banner: { name: "Main", title: "Get the app" } }, headers: @headers, as: :json
    assert_response :created
    id = JSON.parse(response.body)["smart_banner"]["id"]
    other = create_test_banner(@project, name: "Other", priority: 5)

    patch "#{@base}/#{id}", params: { smart_banner: { title: "New title" } }, headers: @headers, as: :json
    assert_response :ok
    patch "#{@base}/reorder", params: { ids: [other.id, id] }, headers: @headers, as: :json
    assert_response :ok
    delete "#{@base}/#{id}", headers: @headers
    assert_response :ok

    assert_equal %w[smart_banner.created smart_banner.updated smart_banner.reordered smart_banner.deleted],
                 events.pluck(:action)
    updated = events.find_by(action: "smart_banner.updated")
    assert_equal "New title", updated.changes_data["after"]["title"]
    assert_equal "Main", events.find_by(action: "smart_banner.deleted").target["name"]
  end

  test "duplicate is audited as a creation" do
    banner = create_test_banner(@project, name: "Original")

    post "#{@base}/#{banner.id}/duplicate", headers: @headers
    assert_response :created

    created = events.where(action: "smart_banner.created").order(:sequence).last
    assert_equal "Original (copy)", created.target["name"]
  end
end
