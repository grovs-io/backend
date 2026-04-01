require "test_helper"

class ProjectSerializerTest < ActiveSupport::TestCase
  fixtures :projects, :instances, :domains

  # ---------------------------------------------------------------------------
  # 1. VALUE VERIFICATION
  # ---------------------------------------------------------------------------

  test "serializes all declared attributes with correct values" do
    project = projects(:one)
    result = ProjectSerializer.serialize(project)

    assert_equal project.id, result["id"]
    assert_equal "Test Project", result["name"]
    assert_equal "test-project-001", result["identifier"]
    assert_equal false, result["test"]
  end

  test "serializes computed domain field from association" do
    project = projects(:one)
    result = ProjectSerializer.serialize(project)

    assert_equal "example.sqd.link", result["domain"]
  end

  test "serializes computed hash_id field as hashid" do
    project = projects(:one)
    result = ProjectSerializer.serialize(project)

    assert_equal project.hashid, result["hash_id"]
  end

  test "serializes project two with its own values" do
    project = projects(:two)
    result = ProjectSerializer.serialize(project)

    assert_equal project.id, result["id"]
    assert_equal "Test Project 2", result["name"]
    assert_equal "test-project-002", result["identifier"]
    assert_equal false, result["test"]
    assert_equal project.hashid, result["hash_id"]
  end

  # ---------------------------------------------------------------------------
  # 2. EXCLUSION
  # ---------------------------------------------------------------------------

  test "excludes created_at updated_at and instance_id" do
    result = ProjectSerializer.serialize(projects(:one))

    %w[created_at updated_at instance_id].each do |field|
      assert_not_includes result.keys, field
    end
  end

  # ---------------------------------------------------------------------------
  # 3. NIL HANDLING
  # ---------------------------------------------------------------------------

  test "returns nil for nil input" do
    assert_nil ProjectSerializer.serialize(nil)
  end

  # ---------------------------------------------------------------------------
  # 4. COLLECTION HANDLING
  # ---------------------------------------------------------------------------

  test "serializes a collection with correct size and distinct values" do
    projects_list = [projects(:one), projects(:two)]
    results = ProjectSerializer.serialize(projects_list)

    assert_equal 2, results.size
    assert_equal "Test Project", results[0]["name"]
    assert_equal "Test Project 2", results[1]["name"]
    assert_equal "test-project-001", results[0]["identifier"]
    assert_equal "test-project-002", results[1]["identifier"]
    assert_equal projects(:one).hashid, results[0]["hash_id"]
    assert_equal projects(:two).hashid, results[1]["hash_id"]
  end

  # ---------------------------------------------------------------------------
  # 5. EDGE CASES
  # ---------------------------------------------------------------------------

  test "hash_id differs between projects" do
    result_one = ProjectSerializer.serialize(projects(:one))
    result_two = ProjectSerializer.serialize(projects(:two))

    assert_not_equal result_one["hash_id"], result_two["hash_id"]
  end

  test "domain is nil when project has no domain association" do
    project = projects(:one)
    project.stub(:domain, nil) do
      result = ProjectSerializer.serialize(project)
      assert_nil result["domain"]
    end
  end
end
