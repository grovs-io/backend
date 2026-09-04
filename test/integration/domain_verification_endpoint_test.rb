require "test_helper"

class DomainVerificationEndpointTest < ActionDispatch::IntegrationTest
  fixtures :instances, :projects, :domains

  PATH = "/.well-known/grovs-domain-verification".freeze
  HOST = "links.selfhosted.com".freeze

  setup do
    REDIS.flushdb
    CustomHostname.delete_all
  end
  teardown { disable_custom_domains! }

  def manual_row(hostname: HOST, project: projects(:one), domain: domains(:one), purpose: "primary")
    CustomHostname.create!(project: project, domain: domain, hostname: hostname,
                           cf_custom_hostname_id: nil, status: "pending",
                           source: "enterprise", purpose: purpose)
  end

  test "returns this deployment's token for a manual host" do
    enable_manual_custom_domains!
    manual_row
    get PATH, headers: { "HOST" => HOST }

    assert_response :success
    assert_equal SelfHostedDomainVerificationService.expected_token(HOST),
                 JSON.parse(response.body)["token"]
  end

  test "the token is bound to the host" do
    enable_manual_custom_domains!
    manual_row
    manual_row(hostname: "other.selfhosted.com", project: projects(:two), domain: domains(:two))

    get PATH, headers: { "HOST" => HOST }
    first = JSON.parse(response.body)["token"]
    get PATH, headers: { "HOST" => "other.selfhosted.com" }

    assert_not_equal first, JSON.parse(response.body)["token"]
  end

  # An env change must not strand hostnames that already exist.
  test "keeps answering for an existing manual host after Cloudflare credentials are added" do
    enable_manual_custom_domains!
    manual_row
    enable_custom_domains!

    get PATH, headers: { "HOST" => HOST }
    assert_response :success
  end

  test "404s for a host with no custom hostname row" do
    enable_manual_custom_domains!
    get PATH, headers: { "HOST" => "stranger.example.com" }
    assert_response :not_found
  end

  test "404s for a Cloudflare-provisioned host" do
    enable_custom_domains!
    manual_row.update_columns(cf_custom_hostname_id: "cf_1")
    get PATH, headers: { "HOST" => HOST }
    assert_response :not_found
  end

  # Routes load globally and production sets config.hosts = nil.
  test "404s when custom domains are disabled" do
    enable_manual_custom_domains!
    manual_row
    disable_custom_domains!
    get PATH, headers: { "HOST" => HOST }
    assert_response :not_found
  end

  test "resolves ahead of the public link catch-all" do
    assert_equal "public/verification#domain_verification",
                 Rails.application.routes.recognize_path(PATH, method: :get).values_at(:controller, :action).join("#")
  end
end
