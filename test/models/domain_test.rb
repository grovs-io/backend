require "test_helper"

class DomainTest < ActiveSupport::TestCase
  fixtures :domains, :projects, :instances

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

  test "image_url returns generic_image_url when set" do
    domain = domains(:one)
    domain.generic_image_url = "https://cdn.example.com/img.png"
    assert_equal "https://cdn.example.com/img.png", domain.image_url
  end

  test "image_url delegates to AssetHelper when generic_image_url is nil" do
    domain = domains(:one)
    domain.generic_image_url = nil
    AssetService.stub(:permanent_url, "https://s3.example.com/fallback.png") do
      assert_equal "https://s3.example.com/fallback.png", domain.image_url
    end
  end

  test "serializer serializes domain attributes and computed image_url" do
    domain = domains(:one)
    domain.generic_image_url = "https://cdn.example.com/img.png"
    domain.generic_title = "My Title"
    domain.subdomain = "app"

    json = DomainSerializer.serialize(domain)

    assert_equal "https://cdn.example.com/img.png", json["generic_image_url"]
    assert_equal "My Title", json["generic_title"]
    assert_equal "app", json["subdomain"]
    assert_equal "sqd.link", json["domain"]
  end

  test "cache_keys_to_clear includes multi-condition key matching domain+subdomain lookup" do
    domain = domains(:one)
    domain.subdomain = "myapp"
    expected_key = domain.send(:multi_condition_cache_key, { domain: domain.domain, subdomain: "myapp" })
    keys = domain.cache_keys_to_clear
    assert_includes keys, expected_key
  end

  test "active_custom_host updates are reflected in redis_find_by(:id) (no stale cache)" do
    domain = domains(:one)
    domain.update!(active_custom_host: nil)

    primed = Domain.redis_find_by(:id, domain.id)
    assert_nil primed.active_custom_host

    domain.update!(active_custom_host: "new.example.com")

    refreshed = Domain.redis_find_by(:id, domain.id)
    assert_equal "new.example.com", refreshed.active_custom_host
  end

  test "display_host falls back to full_domain when the project has only a migration CustomHostname" do
    domain = domains(:one)
    domain.update!(active_custom_host: nil, subdomain: "app")

    Grovs.stub(:custom_domains_enabled?, true) do
      assert_equal "app.sqd.link", domain.display_host,
        "display_host must ignore migration-purpose CHs and serve the sqd.link full_domain"
    end
  end

  test "display_host returns active_custom_host when a primary CustomHostname has been activated" do
    domain = domains(:one)
    domain.update!(active_custom_host: "links.brand.com", subdomain: "app")

    Grovs.stub(:custom_domains_enabled?, true) do
      assert_equal "links.brand.com", domain.display_host,
        "display_host must serve the active custom host when one is set"
    end
  end
end
