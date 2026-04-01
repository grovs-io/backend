require "test_helper"

class PlatformRenderDecisionServiceTest < ActiveSupport::TestCase
  fixtures :projects, :instances, :domains, :links, :devices, :redirect_configs

  setup do
    @link = links(:basic_link)
    @project = projects(:one)
  end

  # --- iOS ---

  test "ios returns preview redirect when show_preview_ios is true" do
    @link.update_column(:show_preview_ios, true)
    device = devices(:ios_device)

    LinksService.stub(:build_preview_url, "https://preview.example.com/test") do
      result = PlatformRenderDecisionService.call(
        device: device, link: @link, project: @project, go_to_fallback: false
      )

      assert_equal :redirect, result[:action]
      assert_equal "https://preview.example.com/test", result[:url]
    end
  end

  test "ios renders template when config exists and has redirects" do
    device = devices(:ios_device)
    ios_config = { phone: { redirect: "https://apps.apple.com" }, tablet: {} }

    WebConfigurationService.stub(:configuration_for_ios, ios_config) do
      WebConfigurationService.stub(:configuration_has_redirect?, true) do
        result = PlatformRenderDecisionService.call(
          device: device, link: @link, project: @project, go_to_fallback: false
        )

        assert_equal :render, result[:action]
        assert_equal "public/display/ios_link_handling", result[:template]
        assert result[:locals].key?(:ios_config)
      end
    end
  end

  test "ios go_to_fallback redirects to fallback url" do
    device = devices(:ios_device)
    ios_config = { phone: { redirect: "https://apps.apple.com" }, tablet: {} }

    WebConfigurationService.stub(:configuration_for_ios, ios_config) do
      WebConfigurationService.stub(:configuration_has_redirect?, true) do
        LinkDisplayService.stub(:fallback_url, "https://fallback.example.com") do
          result = PlatformRenderDecisionService.call(
            device: device, link: @link, project: @project, go_to_fallback: true
          )

          assert_equal :redirect, result[:action]
          assert_equal "https://fallback.example.com", result[:url]
        end
      end
    end
  end

  test "ios returns default redirect when no config" do
    device = devices(:ios_device)

    WebConfigurationService.stub(:configuration_for_ios, nil) do
      result = PlatformRenderDecisionService.call(
        device: device, link: @link, project: @project, go_to_fallback: false
      )

      assert_equal :default_redirect, result[:action]
    end
  end

  test "ios returns default redirect when config has no redirects" do
    device = devices(:ios_device)
    ios_config = { phone: {}, tablet: {} }

    WebConfigurationService.stub(:configuration_for_ios, ios_config) do
      WebConfigurationService.stub(:configuration_has_redirect?, false) do
        result = PlatformRenderDecisionService.call(
          device: device, link: @link, project: @project, go_to_fallback: false
        )

        assert_equal :default_redirect, result[:action]
      end
    end
  end

  # --- Android ---

  test "android renders template when config exists and has redirects" do
    device = devices(:android_device)
    android_config = { phone: { redirect: "https://play.google.com" }, tablet: {} }

    WebConfigurationService.stub(:configure_for_android, android_config) do
      WebConfigurationService.stub(:configuration_has_redirect?, true) do
        result = PlatformRenderDecisionService.call(
          device: device, link: @link, project: @project, go_to_fallback: false
        )

        assert_equal :render, result[:action]
        assert_equal "public/display/android_link_handling", result[:template]
        assert result[:locals].key?(:android_config)
      end
    end
  end

  test "android returns default redirect when no config" do
    device = devices(:android_device)

    WebConfigurationService.stub(:configure_for_android, nil) do
      result = PlatformRenderDecisionService.call(
        device: device, link: @link, project: @project, go_to_fallback: false
      )

      assert_equal :default_redirect, result[:action]
    end
  end

  test "android returns default redirect when config has no redirects" do
    device = devices(:android_device)
    android_config = { phone: {}, tablet: {} }

    WebConfigurationService.stub(:configure_for_android, android_config) do
      WebConfigurationService.stub(:configuration_has_redirect?, false) do
        result = PlatformRenderDecisionService.call(
          device: device, link: @link, project: @project, go_to_fallback: false
        )

        assert_equal :default_redirect, result[:action]
      end
    end
  end

  test "android preview redirect when show_preview_android is true" do
    @link.update_column(:show_preview_android, true)
    device = devices(:android_device)

    LinksService.stub(:build_preview_url, "https://preview.example.com/android") do
      result = PlatformRenderDecisionService.call(
        device: device, link: @link, project: @project, go_to_fallback: false
      )

      assert_equal :redirect, result[:action]
      assert_equal "https://preview.example.com/android", result[:url]
    end
  end

  test "android go_to_fallback redirects to fallback url" do
    device = devices(:android_device)
    android_config = { phone: { redirect: "https://play.google.com" }, tablet: {} }

    WebConfigurationService.stub(:configure_for_android, android_config) do
      WebConfigurationService.stub(:configuration_has_redirect?, true) do
        LinkDisplayService.stub(:fallback_url, "https://fallback.android.example.com") do
          result = PlatformRenderDecisionService.call(
            device: device, link: @link, project: @project, go_to_fallback: true
          )

          assert_equal :redirect, result[:action]
          assert_equal "https://fallback.android.example.com", result[:url]
        end
      end
    end
  end

  # --- Desktop ---

  test "desktop renders template when config exists" do
    device = devices(:web_device)

    desktop_config = { redirect: "https://example.com" }
    WebConfigurationService.stub(:configure_for_desktop, desktop_config) do
      result = PlatformRenderDecisionService.call(
        device: device, link: @link, project: @project, go_to_fallback: false
      )

      assert_equal :render, result[:action]
      assert_equal "public/display/desktop_link_handling", result[:template]
    end
  end

  test "desktop returns default redirect when no config" do
    device = devices(:web_device)

    WebConfigurationService.stub(:configure_for_desktop, nil) do
      result = PlatformRenderDecisionService.call(
        device: device, link: @link, project: @project, go_to_fallback: false
      )

      assert_equal :default_redirect, result[:action]
    end
  end

  # --- Preview with go_to_fallback ---

  test "ios preview with go_to_fallback falls through to platform template" do
    @link.update_column(:show_preview_ios, true)
    device = devices(:ios_device)
    ios_config = { phone: { redirect: "https://apps.apple.com" }, tablet: {} }

    WebConfigurationService.stub(:configuration_for_ios, ios_config) do
      WebConfigurationService.stub(:configuration_has_redirect?, true) do
        LinkDisplayService.stub(:fallback_url, "https://fallback.example.com") do
          result = PlatformRenderDecisionService.call(
            device: device, link: @link, project: @project, go_to_fallback: true
          )

          assert_equal :redirect, result[:action]
          assert_equal "https://fallback.example.com", result[:url]
        end
      end
    end
  end

  test "android preview with go_to_fallback falls through to platform template" do
    @link.update_column(:show_preview_android, true)
    device = devices(:android_device)
    android_config = { phone: { redirect: "https://play.google.com" }, tablet: {} }

    WebConfigurationService.stub(:configure_for_android, android_config) do
      WebConfigurationService.stub(:configuration_has_redirect?, true) do
        LinkDisplayService.stub(:fallback_url, "https://fallback.android.example.com") do
          result = PlatformRenderDecisionService.call(
            device: device, link: @link, project: @project, go_to_fallback: true
          )

          assert_equal :redirect, result[:action]
          assert_equal "https://fallback.android.example.com", result[:url]
        end
      end
    end
  end

  # --- Preview fallback chain ---

  test "ios show_preview falls back to redirect_config when link field is nil" do
    @link.update_column(:show_preview_ios, nil)
    @project.redirect_config.update_column(:show_preview_ios, true)
    device = devices(:ios_device)

    LinksService.stub(:build_preview_url, "https://preview.example.com/fallback") do
      result = PlatformRenderDecisionService.call(
        device: device, link: @link, project: @project, go_to_fallback: false
      )

      assert_equal :redirect, result[:action]
      assert_equal "https://preview.example.com/fallback", result[:url]
    end
  end

  test "android show_preview falls back to redirect_config when link field is nil" do
    @link.update_column(:show_preview_android, nil)
    @project.redirect_config.update_column(:show_preview_android, true)
    device = devices(:android_device)

    LinksService.stub(:build_preview_url, "https://preview.example.com/android-fallback") do
      result = PlatformRenderDecisionService.call(
        device: device, link: @link, project: @project, go_to_fallback: false
      )

      assert_equal :redirect, result[:action]
      assert_equal "https://preview.example.com/android-fallback", result[:url]
    end
  end

  test "no preview when both link and redirect_config show_preview are false" do
    @link.update_column(:show_preview_ios, false)
    @project.redirect_config.update_column(:show_preview_ios, false)
    device = devices(:ios_device)
    ios_config = { phone: { redirect: "https://apps.apple.com" }, tablet: {} }

    WebConfigurationService.stub(:configuration_for_ios, ios_config) do
      WebConfigurationService.stub(:configuration_has_redirect?, true) do
        result = PlatformRenderDecisionService.call(
          device: device, link: @link, project: @project, go_to_fallback: false
        )

        # Should skip preview and go straight to platform template
        assert_equal :render, result[:action]
        assert_equal "public/display/ios_link_handling", result[:template]
      end
    end
  end

  # --- Unrecognized platform ---

  test "unrecognized platform returns default redirect" do
    device = devices(:ios_device)
    # Set platform to something not handled by any when clause
    device.define_singleton_method(:platform) { "smartwatch" }

    result = PlatformRenderDecisionService.call(
      device: device, link: @link, project: @project, go_to_fallback: false
    )

    assert_equal :default_redirect, result[:action]
    assert_equal @project.name, result[:name]
  end

  # --- Desktop ignores go_to_fallback ---

  test "desktop ignores go_to_fallback and still renders template" do
    device = devices(:web_device)
    desktop_config = { redirect: "https://example.com" }

    WebConfigurationService.stub(:configure_for_desktop, desktop_config) do
      result = PlatformRenderDecisionService.call(
        device: device, link: @link, project: @project, go_to_fallback: true
      )

      assert_equal :render, result[:action]
      assert_equal "public/display/desktop_link_handling", result[:template]
      assert_equal desktop_config.to_json, result[:locals][:desktop_config]
    end
  end

  # --- Mac platform routes to desktop template ---

  test "mac platform routes to desktop template" do
    device = devices(:web_device)
    device.define_singleton_method(:platform) { Grovs::Platforms::MAC }
    desktop_config = { redirect: "https://example.com/mac" }

    WebConfigurationService.stub(:configure_for_desktop, desktop_config) do
      result = PlatformRenderDecisionService.call(
        device: device, link: @link, project: @project, go_to_fallback: false
      )

      assert_equal :render, result[:action]
      assert_equal "public/display/desktop_link_handling", result[:template]
      assert_equal desktop_config.to_json, result[:locals][:desktop_config]
    end
  end

  # --- Windows platform routes to desktop template ---

  test "windows platform routes to desktop template" do
    device = devices(:web_device)
    device.define_singleton_method(:platform) { Grovs::Platforms::WINDOWS }
    desktop_config = { redirect: "https://example.com/windows" }

    WebConfigurationService.stub(:configure_for_desktop, desktop_config) do
      result = PlatformRenderDecisionService.call(
        device: device, link: @link, project: @project, go_to_fallback: false
      )

      assert_equal :render, result[:action]
      assert_equal "public/display/desktop_link_handling", result[:template]
      assert_equal desktop_config.to_json, result[:locals][:desktop_config]
    end
  end

  # --- iOS go_to_fallback with nil fallback_url falls through to render ---

  test "ios go_to_fallback with nil fallback_url falls through to render" do
    device = devices(:ios_device)
    ios_config = { phone: { redirect: "https://apps.apple.com" }, tablet: {} }

    WebConfigurationService.stub(:configuration_for_ios, ios_config) do
      WebConfigurationService.stub(:configuration_has_redirect?, true) do
        LinkDisplayService.stub(:fallback_url, nil) do
          result = PlatformRenderDecisionService.call(
            device: device, link: @link, project: @project, go_to_fallback: true
          )

          assert_equal :render, result[:action]
          assert_equal "public/display/ios_link_handling", result[:template]
          assert result[:locals].key?(:ios_config)
        end
      end
    end
  end

  # --- Android go_to_fallback with nil fallback_url falls through to render ---

  test "android go_to_fallback with nil fallback_url falls through to render" do
    device = devices(:android_device)
    android_config = { phone: { redirect: "https://play.google.com" }, tablet: {} }

    WebConfigurationService.stub(:configure_for_android, android_config) do
      WebConfigurationService.stub(:configuration_has_redirect?, true) do
        LinkDisplayService.stub(:fallback_url, nil) do
          result = PlatformRenderDecisionService.call(
            device: device, link: @link, project: @project, go_to_fallback: true
          )

          assert_equal :render, result[:action]
          assert_equal "public/display/android_link_handling", result[:template]
          assert result[:locals].key?(:android_config)
        end
      end
    end
  end
end
