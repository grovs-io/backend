require "test_helper"

class DomainTest < ActiveSupport::TestCase
  fixtures :domains, :projects, :instances

  # === full_domain ===

  test "full_domain returns bare domain when subdomain is nil" do
    domain = domains(:one)
    domain.subdomain = nil
    assert_equal "sqd.link", domain.full_domain
  end

  test "full_domain returns bare domain when subdomain is blank" do
    domain = domains(:one)
    domain.subdomain = ""
    assert_equal "sqd.link", domain.full_domain
  end

  test "full_domain prepends subdomain with dot separator" do
    domain = domains(:one)
    domain.subdomain = "myapp"
    assert_equal "myapp.sqd.link", domain.full_domain
  end

  # === image_url ===

  test "image_url returns generic_image_url when set" do
    domain = domains(:one)
    domain.generic_image_url = "https://cdn.example.com/img.png"
    assert_equal "https://cdn.example.com/img.png", domain.image_url
  end

  test "image_url delegates to AssetHelper when generic_image_url is nil" do
    domain = domains(:one)
    domain.generic_image_url = nil
    # Stub AssetHelper to return a known URL — proves the fallback path actually calls it
    AssetService.stub(:permanent_url, "https://s3.example.com/fallback.png") do
      assert_equal "https://s3.example.com/fallback.png", domain.image_url
    end
  end

  # === serialization ===

  test "serializer serializes domain attributes and computed image_url" do
    domain = domains(:one)
    domain.generic_image_url = "https://cdn.example.com/img.png"
    domain.generic_title = "My Title"
    domain.subdomain = "app"

    json = DomainSerializer.serialize(domain)

    # Computed field uses image_url method
    assert_equal "https://cdn.example.com/img.png", json["generic_image_url"]
    # Standard fields are present
    assert_equal "My Title", json["generic_title"]
    assert_equal "app", json["subdomain"]
    assert_equal "sqd.link", json["domain"]
  end

  # === cache_keys_to_clear ===

  test "cache_keys_to_clear includes multi-condition key matching domain+subdomain lookup" do
    domain = domains(:one)
    domain.subdomain = "myapp"
    expected_key = domain.send(:multi_condition_cache_key, { domain: domain.domain, subdomain: "myapp" })
    keys = domain.cache_keys_to_clear
    assert_includes keys, expected_key
  end
end
