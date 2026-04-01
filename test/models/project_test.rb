require "test_helper"

class ProjectTest < ActiveSupport::TestCase
  fixtures :projects, :instances, :domains

  # === serialization includes domain from associated domain ===

  test "serializer includes full_domain from associated domain" do
    project = projects(:one)
    # Use update! to go through normal association path
    domain = project.domain || project.create_domain!(domain: "test.sqd.link")
    domain.update!(subdomain: "app")

    json = ProjectSerializer.serialize(project.reload)
    assert_equal domain.full_domain, json["domain"]
  end

  test "serializer returns nil domain when no domain associated" do
    project = Project.create!(name: "NoDomain", identifier: "no-domain-proj", instance: instances(:one))
    json = ProjectSerializer.serialize(project)
    assert_nil json["domain"]
  end

  test "serializer includes hashid that differs from raw id" do
    project = projects(:one)
    json = ProjectSerializer.serialize(project)
    assert_equal project.hashid, json["hash_id"]
    assert_not_equal project.id, json["hash_id"]
  end

  # === test? ===

  test "test? reads the test column correctly for both states" do
    project_test = Project.create!(name: "Test", identifier: "is-test-true", instance: instances(:one), test: true)
    project_prod = Project.create!(name: "Prod", identifier: "is-test-false", instance: instances(:one), test: false)

    assert project_test.test?
    assert_not project_prod.test?
  end

  # === cache_keys_to_clear ===

  test "cache_keys_to_clear builds correct identifier key with instance includes" do
    project = projects(:one)
    keys = project.cache_keys_to_clear
    expected = "#{Project.cache_prefix}:find_by:identifier:#{project.identifier}:includes:instance"
    assert_includes keys, expected
  end

  test "cache_keys_to_clear omits identifier key when identifier is blank" do
    project = projects(:one)
    project.identifier = nil
    keys = project.cache_keys_to_clear
    assert_not keys.any? { |k| k.include?("identifier:") }
  end
end
