require "test_helper"

class DomainSerializerTest < ActiveSupport::TestCase
  fixtures :domains, :projects, :instances

  # ---------------------------------------------------------------------------
  # 1. VALUE VERIFICATION
  # ---------------------------------------------------------------------------

  test "serializes all declared attributes with correct values" do
    domain = domains(:one)
    result = DomainSerializer.serialize(domain)

    assert_equal "sqd.link", result["domain"]
    assert_equal "example", result["subdomain"]
    assert_equal "Grovs Demo App", result["generic_title"]
    assert_equal "Deep linking made simple", result["generic_subtitle"]
    assert_equal "G-TEST12345", result["google_tracking_id"]
  end

  test "serializes computed generic_image_url from image_url method" do
    domain = domains(:one)
    result = DomainSerializer.serialize(domain)

    assert_equal "https://cdn.example.com/og-image.jpg", result["generic_image_url"]
  end

  test "serializes domain two with nil for unset fields" do
    domain = domains(:two)
    result = DomainSerializer.serialize(domain)

    assert_equal "sqd.link", result["domain"]
    assert_equal "other", result["subdomain"]
    assert_nil result["generic_title"]
    assert_nil result["generic_subtitle"]
    assert_nil result["google_tracking_id"]
    assert_nil result["generic_image_url"]
  end

  # ---------------------------------------------------------------------------
  # 2. EXCLUSION
  # ---------------------------------------------------------------------------

  test "excludes updated_at created_at id and project_id" do
    result = DomainSerializer.serialize(domains(:one))

    %w[updated_at created_at id project_id].each do |field|
      assert_not_includes result.keys, field
    end
  end

  # ---------------------------------------------------------------------------
  # 3. NIL HANDLING
  # ---------------------------------------------------------------------------

  test "returns nil for nil input" do
    assert_nil DomainSerializer.serialize(nil)
  end

  # ---------------------------------------------------------------------------
  # 4. COLLECTION HANDLING
  # ---------------------------------------------------------------------------

  test "serializes a collection with correct size and distinct subdomains" do
    domain_list = [domains(:one), domains(:two)]
    results = DomainSerializer.serialize(domain_list)

    assert_equal 2, results.size
    assert_equal "example", results[0]["subdomain"]
    assert_equal "other", results[1]["subdomain"]
    assert_equal "sqd.link", results[0]["domain"]
    assert_equal "sqd.link", results[1]["domain"]
  end

  # ---------------------------------------------------------------------------
  # 5. EDGE CASES -- computed field variations
  # ---------------------------------------------------------------------------

  test "generic_image_url is nil when domain has no image and no generic_image_url" do
    domain = domains(:two)
    result = DomainSerializer.serialize(domain)

    # Domain two has no generic_image_url set and no attached generic_image
    assert_nil result["generic_image_url"]
  end

  test "generic_image_url returns generic_image_url column when set" do
    domain = domains(:one)
    result = DomainSerializer.serialize(domain)

    assert_equal "https://cdn.example.com/og-image.jpg", result["generic_image_url"]
  end
end
