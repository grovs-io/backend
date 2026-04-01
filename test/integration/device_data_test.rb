require "test_helper"

class DeviceDataTest < ActionDispatch::IntegrationTest
  fixtures :instances, :projects, :domains, :devices

  setup do
    @domain = domains(:one)
    @host = "#{@domain.subdomain}.#{@domain.domain}"
    @device = devices(:ios_device)
  end

  # --- Happy path ---

  test "POST with valid cookie updates device screen_width and screen_height" do
    original_width = @device.screen_width

    post "/", params: { screen_width: "1440", screen_height: "3200" },
      headers: { "Host" => @host },
      env: { "rack.cookies" => { "LINKSQUARED" => @device.hashid } }

    # Stub the recache to avoid Redis calls
    FingerprintingService.stub(:cache_device, nil) do
      post "/", params: { screen_width: "1440", screen_height: "3200" },
        headers: { "Host" => @host, "Cookie" => "LINKSQUARED=#{@device.hashid}" }
    end

    @device.reload
    assert_equal 1440, @device.screen_width
    assert_equal 3200, @device.screen_height
  end

  test "POST with valid cookie updates timezone and language" do
    FingerprintingService.stub(:cache_device, nil) do
      post "/", params: { timezone: "Europe/London", language: "fr" },
        headers: { "Host" => @host, "Cookie" => "LINKSQUARED=#{@device.hashid}" }
    end

    @device.reload
    assert_equal "Europe/London", @device.timezone
    assert_equal "fr", @device.language
  end

  test "POST with valid cookie updates webgl fields" do
    FingerprintingService.stub(:cache_device, nil) do
      post "/", params: { webgl_vendor: "NVIDIA", webgl_renderer: "GeForce RTX 3080" },
        headers: { "Host" => @host, "Cookie" => "LINKSQUARED=#{@device.hashid}" }
    end

    @device.reload
    assert_equal "NVIDIA", @device.webgl_vendor
    assert_equal "GeForce RTX 3080", @device.webgl_renderer
  end

  # --- Partial updates ---

  test "partial update only changes sent fields, leaves others unchanged" do
    original_height = @device.screen_height
    original_language = @device.language

    FingerprintingService.stub(:cache_device, nil) do
      post "/", params: { screen_width: "999" },
        headers: { "Host" => @host, "Cookie" => "LINKSQUARED=#{@device.hashid}" }
    end

    @device.reload
    assert_equal 999, @device.screen_width
    assert_equal original_height, @device.screen_height
    assert_equal original_language, @device.language
  end

  # --- No-op when nothing changed ---

  test "POST with no params does not call save" do
    updated_at_before = @device.updated_at

    FingerprintingService.stub(:cache_device, nil) do
      post "/", params: {},
        headers: { "Host" => @host, "Cookie" => "LINKSQUARED=#{@device.hashid}" }
    end

    @device.reload
    assert_equal updated_at_before, @device.updated_at
  end

  # --- Missing/invalid cookie ---

  test "POST without cookie returns early without error" do
    post "/", params: { screen_width: "1440" },
      headers: { "Host" => @host }
    assert_includes [200, 204], response.status
  end

  test "POST with invalid cookie (nonexistent device) returns early" do
    post "/", params: { screen_width: "1440" },
      headers: { "Host" => @host, "Cookie" => "LINKSQUARED=nonexistent_hashid" }
    assert_includes [200, 204], response.status
  end

  # --- Recache verification ---

  test "recache is called after device update" do
    cache_called = false
    mock_cache = ->(*_args) { cache_called = true }

    FingerprintingService.stub(:cache_device, mock_cache) do
      post "/", params: { screen_width: "1440" },
        headers: { "Host" => @host, "Cookie" => "LINKSQUARED=#{@device.hashid}" }
    end

    assert cache_called, "FingerprintingService.cache_device should be called after update"
  end

  # --- CSRF not required ---

  test "POST succeeds without CSRF token" do
    FingerprintingService.stub(:cache_device, nil) do
      post "/", params: { screen_width: "800" },
        headers: { "Host" => @host, "Cookie" => "LINKSQUARED=#{@device.hashid}" }
    end
    # Should not get 422 ActionController::InvalidAuthenticityToken
    assert_not_equal 422, response.status
  end

  # --- No-cache headers ---

  test "no-cache headers are set" do
    post "/", params: {},
      headers: { "Host" => @host }
    assert_includes response.headers["Cache-Control"], "no-store"
  end
end
