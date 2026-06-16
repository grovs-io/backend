require "test_helper"
require_relative "../../auth_test_helper"

class Api::V1::MigrationsControllerTest < ActionDispatch::IntegrationTest
  include AuthTestHelper

  fixtures :instances, :users, :instance_roles, :projects, :domains,
           :redirect_configs, :stripe_payment_intents, :stripe_subscriptions

  setup do
    enable_migrations!
    REDIS.flushdb
    CustomHostname.delete_all
    MigrationSource.delete_all
    @project     = projects(:one)
    @other       = projects(:two)
    @admin       = users(:admin_user)
    @member_only = users(:member_user)
  end

  teardown { disable_migrations! }

  def url(project = @project)
    "#{API_PREFIX}/projects/#{project.id}/migrations"
  end

  def admin_headers
    doorkeeper_headers_for(@admin)
  end

  def json_post(path, body, headers: admin_headers)
    post path, params: body.to_json, headers: headers.merge("CONTENT_TYPE" => "application/json")
  end

  def stub_cf_create(cf_id: "cf_mig", &block)
    CloudflareCustomHostnameService.stub(
      :create,
      {
        success: true,
        cf_id: cf_id,
        status: "pending",
        ssl_status: "pending_validation",
        ssl_method: "txt",
        txt_records: [
          { "name" => "_acme-challenge.old-branch.acme.com", "value" => "validation-token-xyz" }
        ],
        verification_errors: nil
      },
      &block
    )
  end

  # Onboarding now probes upstream credentials before provisioning. Stub the probe so
  # create tests don't make real network calls; defaults to a healthy (not_found) verdict.
  def stub_probe(outcome: :not_found, http_status: nil, &block)
    result = case outcome
             when :not_found       then MigrationLookupResult.not_found(http_status: http_status || 404)
             when :found           then MigrationLookupResult.found({}, http_status: http_status || 200)
             when :transient_error then MigrationLookupResult.transient_error(http_status: http_status)
             end
    fake = Object.new
    fake.define_singleton_method(:probe) { result }
    MigrationProviderClient.stub(:for, fake, &block)
  end

  def valid_branch_payload(host: "old-branch.acme.com")
    {
      hostname: host,
      provider: "branch",
      credentials: { branch_key: "key_live_test" }
    }
  end

  def without_contract_check
    previous = ENV["SKIP_API_CONTRACTS"]
    ENV["SKIP_API_CONTRACTS"] = "true"
    yield
  ensure
    ENV["SKIP_API_CONTRACTS"] = previous
  end

  test "happy path: POST /migrations creates CH + source atomically and returns both" do
    stub_probe do
      stub_cf_create do
        json_post url, valid_branch_payload
      end
    end
    assert_response :created

    body = JSON.parse(response.body)
    assert body.key?("custom_domain"),    "response missing custom_domain"
    assert body.key?("migration_source"), "response missing migration_source"

    ch_payload = body["custom_domain"]
    assert_equal "old-branch.acme.com", ch_payload["hostname"]
    assert_equal "migration",            ch_payload["purpose"]
    assert_equal "txt",                  ch_payload["ssl_method"]
    assert_equal [{ "name" => "_acme-challenge.old-branch.acme.com", "value" => "validation-token-xyz" }],
                 ch_payload["ssl_validation_txt_records"]

    src_payload = body["migration_source"]
    assert_equal "branch",              src_payload["provider"]
    assert_equal "old-branch.acme.com", src_payload["old_host"]
    assert_equal true,                  src_payload["enabled"]
    assert_not src_payload.key?("credentials"), "credentials must NOT be serialized"

    ch = CustomHostname.find_by!(hostname: "old-branch.acme.com")
    assert_equal Grovs::Hostnames::PURPOSE_MIGRATION, ch.purpose
    assert_equal @project.id, ch.project_id
    src = MigrationSource.find_by!(old_host: "old-branch.acme.com")
    assert_equal @project.id, src.project_id
    assert_equal "branch", src.provider
  end

  test "rollback: source validation failure tears down the freshly created CH" do
    cf_delete_calls = 0
    cf_delete_stub  = lambda do |*_|
      cf_delete_calls += 1
      true
    end

    # Underscore in the host bypasses MigrationsController + CustomHostname checks but
    # fails MigrationSource's bare-host regex, exercising the post-CH-create rollback.
    bad_payload = {
      hostname: "foo_bar.acme.com",
      provider: "branch",
      credentials: { branch_key: "key_live_test" }
    }

    stub_probe do
      CloudflareCustomHostnameService.stub(:delete, cf_delete_stub) do
        stub_cf_create do
          without_contract_check do
            json_post url, bad_payload
          end
        end
      end
    end

    assert_response :unprocessable_entity
    assert_match(/valid bare hostname/, response.body)
    assert_equal 0, CustomHostname.where(hostname: "foo_bar.acme.com").count,
                 "CH must be destroyed when source creation fails"
    assert_equal 0, MigrationSource.where(old_host: "foo_bar.acme.com").count
    assert_equal 1, cf_delete_calls, "CF delete must be called exactly once during rollback"
  end

  test "rollback with CF-delete failure returns 502 and leaves CH suspended for the orphan sweeper" do
    cf_delete_calls = 0
    cf_delete_stub  = lambda do |*_|
      cf_delete_calls += 1
      false
    end

    bad_payload = {
      hostname: "foo_bar.acme.com",
      provider: "branch",
      credentials: { branch_key: "key_live_test" }
    }

    warnings = []
    stub_probe do
      Rails.logger.stub(:warn, ->(payload) { warnings << payload }) do
        CloudflareCustomHostnameService.stub(:delete, cf_delete_stub) do
          stub_cf_create do
            without_contract_check do
              json_post url, bad_payload
            end
          end
        end
      end
    end

    assert_response :bad_gateway
    body = JSON.parse(response.body)
    assert_match(/cleanup/i, body["error"])
    assert(warnings.any? { |w| w.is_a?(Hash) && w[:message] == "migrations_create_cleanup_failed" },
           "expected a structured 'migrations_create_cleanup_failed' Rails.logger.warn")

    ch = CustomHostname.find_by(hostname: "foo_bar.acme.com")
    assert_not_nil ch, "CH row must remain when CF delete fails (retry-later state)"
    assert_equal "suspended", ch.status
    assert_equal 0, MigrationSource.where(old_host: "foo_bar.acme.com").count
    assert_equal 1, cf_delete_calls
  end

  test "credentials supplied as a String returns 422 (not 500) and provisions nothing" do
    bad_payload = {
      hostname: "old-branch.acme.com",
      provider: "branch",
      credentials: "branch_key=key_live_test"
    }

    CustomDomainProvisioningService.stub(:create, ->(*_) { flunk "must short-circuit before provisioning on a malformed body" }) do
      without_contract_check do
        json_post url, bad_payload
      end
    end

    assert_response :unprocessable_entity
    assert_equal 0, CustomHostname.where(hostname: "old-branch.acme.com").count
    assert_equal 0, MigrationSource.where(old_host: "old-branch.acme.com").count
  end

  test "credentials supplied as a non-pair Array returns 422 (not 500) and provisions nothing" do
    bad_payload = {
      hostname: "old-branch.acme.com",
      provider: "branch",
      credentials: [{ "branch_key" => "key_live_test" }]
    }

    CustomDomainProvisioningService.stub(:create, ->(*_) { flunk "must short-circuit before provisioning on a malformed body" }) do
      without_contract_check do
        json_post url, bad_payload
      end
    end

    assert_response :unprocessable_entity
    assert_equal 0, CustomHostname.where(hostname: "old-branch.acme.com").count
  end

  test "credentials supplied as an empty Array hits the presence-required 422" do
    bad_payload = {
      hostname: "old-branch.acme.com",
      provider: "branch",
      credentials: []
    }

    without_contract_check do
      json_post url, bad_payload
    end

    assert_response :unprocessable_entity
    assert_match(/credentials are required/, response.body)
  end

  test "bad provider returns 422 and never calls the provisioning service" do
    CustomDomainProvisioningService.stub(:create, ->(*_) { flunk "must not provision on bad provider" }) do
      without_contract_check do
        json_post url, { hostname: "old-branch.acme.com", provider: "unknown",
                         credentials: { branch_key: "x" } }
      end
    end
    assert_response :unprocessable_entity
    assert_match(/Provider is not included in the list/, response.body)
    assert_equal 0, CustomHostname.where(hostname: "old-branch.acme.com").count
  end

  test "cross-project hostname conflict returns 409 with no state change" do
    CustomHostname.create!(project: @other, domain: domains(:two),
                           hostname: "branch.tabkeep.uk",
                           status: "active", source: "saas",
                           purpose: Grovs::Hostnames::PURPOSE_MIGRATION)

    CustomDomainProvisioningService.stub(:create, ->(*_) { flunk "must short-circuit before provisioning" }) do
      json_post url, valid_branch_payload(host: "branch.tabkeep.uk")
    end
    assert_response :conflict
    assert_match(/different project/, response.body)

    # No new rows on @project, no mutation on @other.
    assert_equal 0, CustomHostname.where(project: @project).count
    assert_equal 0, MigrationSource.where(project: @project).count
    assert CustomHostname.exists?(project: @other, hostname: "branch.tabkeep.uk")
  end

  test "Cloudflare provisioning failure surfaces as 502 and no source is created" do
    bad_result = CustomDomainProvisioningService::Result.new(
      ok: false, error: "Cloudflare provisioning failed", status: :bad_gateway
    )
    stub_probe do
      CustomDomainProvisioningService.stub(:create, bad_result) do
        json_post url, valid_branch_payload
      end
    end
    assert_response :bad_gateway
    assert_match(/Cloudflare provisioning failed/, response.body)
    assert_equal 0, MigrationSource.where(project: @project).count
  end

  test "AppsFlyer credentials_invalid probe (401) blocks onboarding with a OneLink-API hint and provisions nothing" do
    CustomDomainProvisioningService.stub(:create, ->(*_) { flunk "must not provision when credentials are rejected" }) do
      stub_probe(outcome: :transient_error, http_status: 401) do
        without_contract_check do
          json_post url, { hostname: "af.acme.com", provider: "appsflyer",
                           credentials: { onelink_id: "le6K", api_token: "tok" } }
        end
      end
    end
    assert_response :unprocessable_entity
    body = JSON.parse(response.body)
    assert_match(/rejected by AppsFlyer/i, body["error"])
    assert_match(/OneLink API/i, body["error"])
    assert_equal 0, CustomHostname.where(hostname: "af.acme.com").count
    assert_equal 0, MigrationSource.where(old_host: "af.acme.com").count
  end

  test "credentials_invalid probe (400 bad onelink_id) blocks onboarding" do
    CustomDomainProvisioningService.stub(:create, ->(*_) { flunk "must not provision on a 400 onelink_id" }) do
      stub_probe(outcome: :transient_error, http_status: 400) do
        without_contract_check do
          json_post url, { hostname: "af.acme.com", provider: "appsflyer",
                           credentials: { onelink_id: "bad", api_token: "tok" } }
        end
      end
    end
    assert_response :unprocessable_entity
    assert_equal 0, MigrationSource.where(old_host: "af.acme.com").count
  end

  test "transient upstream error during the probe does NOT block onboarding (creates normally)" do
    stub_probe(outcome: :transient_error, http_status: 500) do
      stub_cf_create do
        json_post url, valid_branch_payload
      end
    end
    assert_response :created
    assert_equal 1, MigrationSource.where(project: @project).count
  end

  test "without doorkeeper token returns 401" do
    json_post url, valid_branch_payload, headers: { "Host" => api_host, "CONTENT_TYPE" => "application/json" }
    assert_response :unauthorized
  end

  test "authenticated but not admin returns 403" do
    json_post url, valid_branch_payload, headers: doorkeeper_headers_for(@member_only)
    assert_response :forbidden
  end

  test "feature flag off returns 503" do
    disable_migrations!
    json_post url, valid_branch_payload
    assert_response :service_unavailable
  end

  test "pre-validates Branch credentials shape before calling Cloudflare" do
    CustomDomainProvisioningService.stub(
      :create,
      ->(*_args, **_kwargs) { flunk "CF must not be called when credentials shape is invalid" }
    ) do
      without_contract_check do
        json_post url, { hostname: "old-branch.acme.com", provider: "branch",
                         credentials: { wrong_key: "x" } }
      end
    end
    assert_response :unprocessable_entity
    assert_match(/Credentials missing keys: branch_key/, response.body)
    assert_equal 0, CustomHostname.where(hostname: "old-branch.acme.com").count
  end

  test "pre-validates AppsFlyer credentials shape before calling Cloudflare" do
    CustomDomainProvisioningService.stub(
      :create,
      ->(*_args, **_kwargs) { flunk "CF must not be called when credentials shape is invalid" }
    ) do
      without_contract_check do
        json_post url, { hostname: "old-branch.acme.com", provider: "appsflyer",
                         credentials: { onelink_id: "X" } }
      end
    end
    assert_response :unprocessable_entity
    assert_match(/Credentials missing keys: api_token/, response.body)
    assert_equal 0, CustomHostname.where(hostname: "old-branch.acme.com").count
  end

  test "throttling: the 11th create in a minute returns 429" do
    limit = Api::V1::Concerns::CustomDomainOpsThrottling::CUSTOM_DOMAIN_OPS_RATE_LIMIT_PER_MINUTE
    bucket = Time.current.to_i / 60
    REDIS.with { |c| c.set("custom_domain_ops:rate:#{@project.id}:#{bucket}", limit, ex: 65) }

    CustomDomainProvisioningService.stub(:create, ->(*_) { flunk "throttled request must not provision" }) do
      json_post url, valid_branch_payload
    end
    assert_response :too_many_requests
    assert_equal "60", response.headers["Retry-After"]
  end

  test "unexpected exception during source.save! tears down the CH before propagating" do
    # PG disconnect / deadlock / Redis cache invalidation failure — anything other
    # than RecordInvalid/RecordNotUnique. Without the rescue StandardError clause,
    # the just-created CH would orphan until the lifecycle job reaps it.
    destroy_called_with = nil
    destroy_stub = lambda do |ch|
      destroy_called_with = ch
      true
    end

    MigrationSource.class_eval do
      alias_method :__orig_save_bang_for_test, :save!
      define_method(:save!) { raise PG::ConnectionBad, "connection lost" }
    end

    begin
      stub_probe do
        stub_cf_create do
          CustomDomainProvisioningService.stub(:destroy, destroy_stub) do
            # 500 isn't in the contract (and shouldn't be — it's a bug); bypass
            # contract validation. Integration tests don't surface re-raised
            # exceptions — they render the default 500 page — so we assert the
            # status code and verify destroy was called.
            without_contract_check do
              json_post url, valid_branch_payload
            end
          end
        end
      end
    ensure
      MigrationSource.class_eval do
        alias_method :save!, :__orig_save_bang_for_test
        remove_method :__orig_save_bang_for_test
      end
    end

    assert_response :internal_server_error,
                    "unexpected exception must propagate so the 500 is logged + alerted"
    assert_not_nil destroy_called_with,
                   "rescue StandardError must invoke destroy(custom_hostname) to release CF + DB"
    assert_equal "old-branch.acme.com", destroy_called_with.hostname
  end
end
