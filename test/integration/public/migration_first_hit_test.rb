require "test_helper"

class MigrationFirstHitTest < ActionDispatch::IntegrationTest
  fixtures :instances, :users, :instance_roles, :projects, :domains,
           :redirect_configs, :applications,
           :ios_configurations, :android_configurations, :redirects,
           :custom_redirects, :links

  PRIMARY_HOST   = "new.acme.com".freeze
  MIGRATION_HOST = "old-branch.acme.com".freeze
  COLLISION_PATH = "promo".freeze

  setup do
    enable_migrations!
    REDIS.flushdb
    CustomHostname.delete_all
    MigrationSource.delete_all
    MigratedLink.delete_all

    @project = projects(:one)
    @domain  = domains(:one)

    @primary_ch = CustomHostname.create!(
      project: @project, domain: @domain,
      hostname: PRIMARY_HOST, status: "active", source: "saas",
      purpose: Grovs::Hostnames::PURPOSE_PRIMARY
    )
    @domain.update!(active_custom_host: PRIMARY_HOST)
    @domain.send(:clear_cache)

    @migration_ch = CustomHostname.create!(
      project: @project, domain: @domain,
      hostname: MIGRATION_HOST, status: "active", source: "saas",
      purpose: Grovs::Hostnames::PURPOSE_MIGRATION
    )

    @existing_link = links(:basic_link)
    @existing_link.update!(path: COLLISION_PATH)
    @existing_link.send(:clear_cache)

    @source = MigrationSource.create!(
      project: @project, old_host: MIGRATION_HOST,
      provider: Grovs::Migrations::PROVIDER_BRANCH,
      credentials: { "branch_key" => "key_live_test" }
    )
    @source.send(:invalidate_cache!)
  end

  teardown do
    disable_migrations!
  end

  def with_stubbed_branch_upstream(&block)
    calls = 0
    fake = lambda do |*|
      calls += 1
      OpenStruct.new(
        code: 200,
        parsed_response: { "data" => { "$ios_url" => "myapp://ios", "$og_title" => "From Branch" } },
        headers: {}
      )
    end
    HTTParty.stub(:get, fake, &block)
    calls
  end

  test "migration-host click with a path that collides with a Grovs link reaches MigrationResolver" do
    calls = with_stubbed_branch_upstream do
      get "/#{COLLISION_PATH}", headers: { "Host" => MIGRATION_HOST }
    end

    assert_equal 1, calls, "Branch upstream must be called — proof MigrationResolver ran"
    assert_response :moved_permanently

    location = response.headers["Location"]
    redirect_uri = URI.parse(location)
    assert_equal PRIMARY_HOST, redirect_uri.host,
      "301 must point at the primary host (display_host on the project's Domain)"
    assert_not_equal "/#{COLLISION_PATH}", redirect_uri.path,
      "the colliding pre-existing Grovs link must NOT have been served"

    materialized = MigratedLink.find_by(migration_source: @source, old_path: COLLISION_PATH)&.link
    assert_not_nil materialized, "expected a freshly-materialized Link"
    assert_not_equal @existing_link.id, materialized.id,
      "materialized link must be a NEW row, not the colliding pre-existing one"
  end

  test "primary-host click serves the existing Grovs link without invoking the migration path" do
    captured_link = nil
    device = Device.create!(user_agent: "Mozilla/5.0", ip: "1.2.3.4", remote_ip: "5.6.7.8", platform: "web")
    orchestration_stub = lambda do |**kwargs|
      captured_link = kwargs[:link]
      :ok
    end
    decision_stub = ->(**_kwargs) { { action: :default_redirect, name: "App" } }

    DeviceService.stub(:device_for_website_visit, device) do
      LinkOpenOrchestrationService.stub(:call, orchestration_stub) do
        PlatformRenderDecisionService.stub(:call, decision_stub) do
          HTTParty.stub(:get, ->(*) { raise "upstream must not be called on primary host" }) do
            get "/#{COLLISION_PATH}", headers: { "Host" => PRIMARY_HOST }
          end
        end
      end
    end

    assert_not_equal 301, response.status,
      "primary-host serves native orchestration (not a migration 301)"
    assert_nil MigratedLink.find_by(migration_source: @source, old_path: COLLISION_PATH),
      "no MigratedLink row should be written for a primary-host hit"
    assert_not_nil captured_link,
      "LinkOpenOrchestrationService should have received the resolved Grovs link"
    assert_equal @existing_link.id, captured_link.id,
      "the existing Grovs link (not a migration-materialized one) was served"
  end

  test "AASA on the migration host serves the project's iOS verification file" do
    get "/.well-known/apple-app-site-association", headers: { "Host" => MIGRATION_HOST }

    assert_response :ok
    body = JSON.parse(response.body)
    assert body.key?("applinks"),
      "AASA on the migration host must include the applinks block"
  end

  test "assetlinks.json on the migration host serves the project's Android verification file" do
    get "/.well-known/assetlinks.json", headers: { "Host" => MIGRATION_HOST }

    assert_response :ok
    body = JSON.parse(response.body)
    assert body.is_a?(Array), "assetlinks.json response is a JSON array"
    assert_not body.empty?, "assetlinks.json must include at least one target entry"
  end

  test "LinksService.link_for_redirect_url returns nil for a migration-host URL even on a colliding path" do
    assert_nil LinksService.link_for_redirect_url("https://#{MIGRATION_HOST}/#{COLLISION_PATH}")
  end

  test "LinksService.link_for_redirect_url returns the colliding link on the primary host (sanity)" do
    result = LinksService.link_for_redirect_url("https://#{PRIMARY_HOST}/#{COLLISION_PATH}")
    assert_equal @existing_link.id, result&.id
  end

  test "LinksService.link_for_url returns nil for a migration-host URL even on a colliding path" do
    assert_nil LinksService.link_for_url("https://#{MIGRATION_HOST}/#{COLLISION_PATH}", @project)
  end

  test "LinksService.link_for_url returns the colliding link on the primary host (sanity)" do
    result = LinksService.link_for_url("https://#{PRIMARY_HOST}/#{COLLISION_PATH}", @project)
    assert_equal @existing_link.id, result&.id
  end
end
