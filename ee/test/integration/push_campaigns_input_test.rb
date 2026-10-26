require "test_helper"
require_relative "../../../test/integration/auth_test_helper"

class PushCampaignsInputTest < ActionDispatch::IntegrationTest
  include AuthTestHelper
  include AuditTestHelper
  fixtures :instances, :users, :instance_roles, :projects, :visitors, :devices, :domains, :links

  setup do
    @project = projects(:one)
    entitle!(@project.instance)
    @admin = doorkeeper_headers_for(users(:admin_user))
  end

  def base = "#{API_PREFIX}/projects/#{@project.id}/push_campaigns"
  def draft = { name: "n", title: "t", body: "b", audience: { type: "visitors", recipients: [visitors(:ios_visitor).uuid] } }

  def create!(**extra)
    post base, params: draft.merge(extra), headers: @admin, as: :json
    JSON.parse(response.body)
  end

  test "an image that is not a file is refused with its own error and nothing is saved" do
    assert_no_difference(-> { PushCampaign.count }) { create!(image: "https://example.com/x.png") }
    assert_response :unprocessable_entity
    assert_equal({ "error" => "image must be a file" }, JSON.parse(response.body))
  end

  test "an image that is not a file leaves a draft unchanged" do
    id = create!["push_campaign"]["id"]
    patch "#{base}/#{id}", params: { title: "changed", image: "nope" }, headers: @admin, as: :json
    assert_response :unprocessable_entity
    assert_equal({ "error" => "image must be a file" }, JSON.parse(response.body))
    c = PushCampaign.find_by_hashid(id)
    assert_equal "t", c.title
    assert_not c.image.attached?
  end

  test "data is stored as the object sent, nested values included" do
    data = { "screen" => "offer", "meta" => { "id" => 7, "tags" => %w[a b] } }
    c = create!(data: data)["push_campaign"]
    assert_response :created
    assert_equal data, PushCampaign.find_by_hashid(c["id"]).data
  end

  test "data that is not an object is refused with an exact error" do
    assert_no_difference(-> { PushCampaign.count }) { create!(data: %w[a b]) }
    assert_response :unprocessable_entity
    assert_equal({ "error" => "data must be an object" }, JSON.parse(response.body))
  end

  test "a link of the project is attached; a blank link_id detaches it" do
    id = create!(link_id: links(:basic_link).id)["push_campaign"]["id"]
    assert_response :created
    assert_equal links(:basic_link), PushCampaign.find_by_hashid(id).link
    patch "#{base}/#{id}", params: { link_id: "" }, headers: @admin, as: :json
    assert_response :ok
    assert_nil PushCampaign.find_by_hashid(id).link
  end

  test "another project's link or an unknown id is Link not found and nothing is saved" do
    [links(:second_link).id, 999_999_999].each do |link_id|
      assert_no_difference(-> { PushCampaign.count }) { create!(link_id: link_id) }
      assert_response :unprocessable_entity
      assert_equal({ "error" => "Link not found" }, JSON.parse(response.body))
    end
  end

  test "a patch with a foreign link keeps the draft's link" do
    id = create!(link_id: links(:basic_link).id)["push_campaign"]["id"]
    patch "#{base}/#{id}", params: { link_id: links(:second_link).id, title: "changed" }, headers: @admin, as: :json
    assert_response :unprocessable_entity
    c = PushCampaign.find_by_hashid(id)
    assert_equal [links(:basic_link), "t"], [c.link, c.title]
  end

  test "variants sent as broken JSON text reach validation as text, a 422 and not a crash" do
    assert_no_difference(-> { PushCampaign.count }) { create!(variants: '[{"id": "b",') }
    assert_response :unprocessable_entity
    assert_equal({ "error" => "Variants must be a list of at most two" }, JSON.parse(response.body))
  end

  test "variants sent as JSON text are parsed like an array" do
    c = create!(variants: '[{"id":"b","title":"B","body":"bb"}]')["push_campaign"]
    assert_response :created
    assert_equal [{ "id" => "b", "title" => "B", "body" => "bb" }], c["variants"]
  end
end
