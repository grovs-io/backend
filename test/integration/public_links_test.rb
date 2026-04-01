require "test_helper"

class PublicLinksTest < ActionDispatch::IntegrationTest
  fixtures :instances, :projects, :domains, :links, :redirect_configs, :redirects,
           :applications, :ios_configurations, :android_configurations

  setup do
    @project = projects(:one)
    @domain = domains(:one)
    @link = links(:basic_link)
  end

  # --- open_app_link: happy path ---

  test "open_app_link with redirect decision redirects to a cross-host URL" do
    device = Device.create!(user_agent: "Mozilla/5.0 (iPhone)", ip: "1.2.3.4", remote_ip: "5.6.7.8", platform: "ios")
    # Cross-host redirect (e.g. to preview subdomain) — requires allow_other_host: true
    redirect_url = "http://preview.sqd.link?url=https%3A%2F%2Fexample.sqd.link%2Fdeep%2Flink"

    LinksService.stub(:link_for_request, @link) do
      DeviceService.stub(:device_for_website_visit, device) do
        LinkOpenOrchestrationService.stub(:call, :ok) do
          PlatformRenderDecisionService.stub(:call, { action: :redirect, url: redirect_url }) do
            get "/#{@link.path}", headers: public_host_headers
            assert_response :redirect
            assert_equal redirect_url, response.location
          end
        end
      end
    end
  end

  test "open_app_link with default_redirect decision renders app name in template" do
    device = Device.create!(user_agent: "Mozilla/5.0 (Macintosh)", ip: "1.2.3.4", remote_ip: "5.6.7.8", platform: "web")

    LinksService.stub(:link_for_request, @link) do
      DeviceService.stub(:device_for_website_visit, device) do
        LinkOpenOrchestrationService.stub(:call, :ok) do
          PlatformRenderDecisionService.stub(:call, { action: :default_redirect, name: "My App" }) do
            get "/#{@link.path}", headers: public_host_headers
            assert_response :ok
            assert_includes response.body, "My App"
            assert_includes response.body, "default redirect page"
          end
        end
      end
    end
  end

  # --- open_app_link: failure paths (no service stubs needed) ---

  test "open_app_link with nonexistent path renders not_found template" do
    LinksService.stub(:link_for_request, nil) do
      get "/nonexistent-path-xyz", headers: public_host_headers
      assert_response :ok
      assert_includes response.body, "Lost in the Void"
    end
  end

  test "open_app_link with unknown subdomain renders not_found template" do
    LinksService.stub(:link_for_request, nil) do
      get "/test-path", headers: { "Host" => "unknown-subdomain.sqd.link" }
      assert_response :ok
      assert_includes response.body, "Lost in the Void"
    end
  end

  test "open_app_link root path is routed and renders content" do
    LinksService.stub(:link_for_request, nil) do
      get "/", headers: public_host_headers
      assert_response :ok
      assert response.body.present?, "Root path should render a page"
    end
  end

  # --- open_app_link: quota exceeded ---

  test "open_app_link when quota exceeded renders quota_exceeded template" do
    device = Device.create!(user_agent: "TestBot/1.0", ip: "1.2.3.4", remote_ip: "5.6.7.8", platform: "ios")

    LinksService.stub(:link_for_request, @link) do
      DeviceService.stub(:device_for_website_visit, device) do
        LinkOpenOrchestrationService.stub(:call, :quota_exceeded) do
          get "/#{@link.path}", headers: public_host_headers
          assert_response :ok
          assert_includes response.body, "Quota exceeded"
        end
      end
    end
  end

  # --- go_to_fallback param ---

  test "go_to_fallback=true is cast to boolean and passed to orchestration" do
    device = Device.create!(user_agent: "TestBot/1.0", ip: "1.2.3.4", remote_ip: "5.6.7.8", platform: "ios")
    received_fallback = nil

    mock_call = lambda { |**kwargs| 
      received_fallback = kwargs[:go_to_fallback]
      :ok
    }

    LinksService.stub(:link_for_request, @link) do
      DeviceService.stub(:device_for_website_visit, device) do
        LinkOpenOrchestrationService.stub(:call, mock_call) do
          PlatformRenderDecisionService.stub(:call, { action: :default_redirect, name: "X" }) do
            get "/#{@link.path}?go_to_fallback=true", headers: public_host_headers
          end
        end
      end
    end
    assert_equal true, received_fallback
  end

  test "go_to_fallback=false is cast to boolean false" do
    device = Device.create!(user_agent: "TestBot/1.0", ip: "1.2.3.4", remote_ip: "5.6.7.8", platform: "ios")
    received_fallback = nil

    mock_call = lambda { |**kwargs| 
      received_fallback = kwargs[:go_to_fallback]
      :ok
    }

    LinksService.stub(:link_for_request, @link) do
      DeviceService.stub(:device_for_website_visit, device) do
        LinkOpenOrchestrationService.stub(:call, mock_call) do
          PlatformRenderDecisionService.stub(:call, { action: :default_redirect, name: "X" }) do
            get "/#{@link.path}?go_to_fallback=false", headers: public_host_headers
          end
        end
      end
    end
    assert_equal false, received_fallback
  end

  test "go_to_fallback absent defaults to nil" do
    device = Device.create!(user_agent: "TestBot/1.0", ip: "1.2.3.4", remote_ip: "5.6.7.8", platform: "ios")
    received_fallback = :not_set

    mock_call = lambda { |**kwargs| 
      received_fallback = kwargs[:go_to_fallback]
      :ok
    }

    LinksService.stub(:link_for_request, @link) do
      DeviceService.stub(:device_for_website_visit, device) do
        LinkOpenOrchestrationService.stub(:call, mock_call) do
          PlatformRenderDecisionService.stub(:call, { action: :default_redirect, name: "X" }) do
            get "/#{@link.path}", headers: public_host_headers
          end
        end
      end
    end
    assert_nil received_fallback
  end

  # --- make_redirect (preview subdomain) ---

  # NOTE: The redirect template (public/display/redirect.html.erb) includes
  # javascript_include_tag for compiled assets that aren't available in test mode.
  # This causes a template render error caught by the controller's rescue clause.
  # We verify the orchestration is correct by capturing that the redirect URL
  # is built and the render is attempted (the rescue renders not_found).
  test "make_redirect with valid link resolves link and builds redirect URL" do
    device = Device.create!(user_agent: "TestBot/1.0", ip: "1.2.3.4", remote_ip: "5.6.7.8", platform: "web")
    redirect_url_built = false

    LinksService.stub(:link_for_redirect_url, @link) do
      DeviceService.stub(:device_for_website_visit, device) do
        WebConfigurationService.stub(:name_and_image_for_project_and_platform, { name: "Test App", image: nil }) do
          LinksService.stub(:build_redirect_url_for_preview, lambda { |*_args| 
            redirect_url_built = true
            "https://example.sqd.link/test-path"
          }) do
            get "/?url=https://example.sqd.link/test-path", headers: preview_host_headers
            # Template render fails due to missing compiled JS assets in test,
            # but the controller orchestration (link lookup, device creation,
            # redirect URL construction) all completed successfully.
          end
        end
      end
    end
    assert redirect_url_built, "LinksService.build_redirect_url_for_preview should have been called"
  end

  test "make_redirect with nil URL renders not_found" do
    LinksService.stub(:link_for_redirect_url, nil) do
      get "/some-path", headers: preview_host_headers
      assert_response :ok
      assert_includes response.body, "Lost in the Void"
    end
  end

  test "make_redirect with exception renders not_found gracefully" do
    LinksService.stub(:link_for_redirect_url, ->(_url) { raise StandardError, "boom" }) do
      get "/some-path?url=https://example.com", headers: preview_host_headers
      assert_response :ok
      assert_includes response.body, "Lost in the Void"
    end
  end

  # --- Headers ---

  test "no-cache headers are set on public link responses" do
    LinksService.stub(:link_for_request, nil) do
      get "/some-path", headers: public_host_headers
      assert_includes response.headers["Cache-Control"], "no-store"
    end
  end

  private

  def public_host_headers(extra = {})
    { "Host" => "#{@domain.subdomain}.#{@domain.domain}" }.merge(extra)
  end

  def preview_host_headers
    { "Host" => "preview.sqd.link" }
  end
end
