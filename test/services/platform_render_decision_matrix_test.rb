require "test_helper"

class PlatformRenderDecisionMatrixTest < ActiveSupport::TestCase
  fixtures :instances, :projects, :domains, :links, :redirect_configs, :redirects,
           :applications, :ios_configurations, :android_configurations, :desktop_configurations

  UAS = {
    browser: { "ios" => "Mozilla/5.0 (iPhone; CPU iPhone OS 17_5 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) " \
                        "Version/17.5 Mobile/15E148 Safari/604.1",
               "android" => "Mozilla/5.0 (Linux; Android 10; K) AppleWebKit/537.36 (KHTML, like Gecko) " \
                            "Chrome/127.0.0.0 Mobile Safari/537.36",
               "desktop" => "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/127.0.0.0 Safari/537.36" },
    iab: { "ios" => "Mozilla/5.0 (iPhone; CPU iPhone OS 17_5 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Mobile/15E148 Instagram 342.0.4.27.88",
           "android" => "Mozilla/5.0 (Linux; Android 14; Pixel 8; wv) AppleWebKit/537.36 (KHTML, like Gecko) " \
                        "Version/4.0 Chrome/127.0.0.0 Mobile Safari/537.36 Instagram 343.0.0.33.101 Android",
           "desktop" => "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) [FBAN/FBMAC]" },
    bot: { "ios" => "facebookexternalhit/1.1 Instagram", "android" => "facebookexternalhit/1.1 Instagram",
           "desktop" => "facebookexternalhit/1.1 Instagram" }
  }.freeze

  PREVIEW_URL = "https://preview.example.com/?url=x"

  setup do
    @link = links(:no_custom_redirect_link)
    @project = projects(:one)
    @counts = Hash.new(0)
  end

  test "invariants hold for every combination" do
    each_case do |c|
      new_decision = decide(PlatformRenderDecisionService, c)
      legacy = decide(LegacyPlatformRenderDecisionService, c)
      label = c.inspect

      if c[:ua] != :iab
        assert_equal normalize(decide(PlatformRenderDecisionService, c.merge(eligible: !c[:eligible]))),
                     normalize(new_decision), "I1 #{label}"
      end
      assert_equal normalize(legacy), normalize(new_decision), "I2 #{label}" unless c[:eligible]
      if c[:go_to_fallback] || c[:grovs_redirect]
        assert_equal normalize(legacy), normalize(new_decision), "I3 #{label}"
      end

      routed = c[:ua] == :iab && c[:eligible] && c[:platform] != "desktop" && !c[:go_to_fallback] && !c[:grovs_redirect]
      if routed
        assert_equal({ action: :redirect, url: PREVIEW_URL }, new_decision, "routed #{label}")
        @counts[:routed] += 1
      elsif c[:platform] == "desktop" || !(c[:ua] == :iab && c[:eligible])
        assert_equal normalize(legacy), normalize(new_decision), "unrouted #{label}"
      end
      @counts[:cases] += 1
    end

    assert_equal 864, @counts[:cases]
    assert_operator @counts[:routed], :>, 0
  end

  test "routed preview carries no gd when only the in-app browser rule shows it" do
    @link.update_columns(show_preview_ios: false, copy_to_clipboard_ios: true)
    gd_args = []
    stub_eligible(true) do
      LinksService.stub(:build_preview_url, lambda { |_link, gd_device: nil|
        gd_args << gd_device
        PREVIEW_URL
      }) do
        PlatformRenderDecisionService.call(device: device_for("ios", :iab), link: @link, project: @project, go_to_fallback: nil)
      end
    end
    assert_equal [nil], gd_args
  end

  private

  def each_case
    %w[ios android desktop].product(%i[browser iab bot], [true, false], [true, false], [true, false, nil],
                                    [true, false], [nil, true], [nil, "https://x.example"]).each do |p, ua, el, pp, lp, cb, gtf, gr|
      yield(platform: p, ua: ua, eligible: el, project_preview: pp, link_preview: lp, clipboard: cb,
            go_to_fallback: gtf, grovs_redirect: gr)
    end
  end

  def decide(service, combo)
    @project.redirect_config.update_columns(show_preview_ios: combo[:project_preview], show_preview_android: combo[:project_preview])
    @link.update_columns(show_preview_ios: combo[:link_preview], show_preview_android: combo[:link_preview],
                         copy_to_clipboard_ios: combo[:clipboard], copy_to_clipboard_android: combo[:clipboard])
    link = Link.find(@link.id)
    args = { device: device_for(combo[:platform], combo[:ua]), link: link, project: Project.find(@project.id),
             go_to_fallback: combo[:go_to_fallback] }
    args[:grovs_redirect] = combo[:grovs_redirect] if service == PlatformRenderDecisionService

    stub_eligible(combo[:eligible]) do
      LinksService.stub(:build_preview_url, PREVIEW_URL) do
        ClipboardActivityService.stub(:stamp, nil) do
          AppstoreService.stub(:fetch_image_and_title_for_identifier, { title: "T", image: "https://i", appstore_id: "1" }) do
            GooglePlayService.stub(:fetch_image_and_title_for_identifier, { title: "T", image: "https://i" }) do
              service.call(**args)
            end
          end
        end
      end
    end
  end

  def stub_eligible(value, &block)
    InAppBrowserPage.stub(:eligible?, value, &block)
  end

  def device_for(platform, ua_kind)
    @devices ||= {}
    @devices[[platform, ua_kind]] ||= Device.create!(user_agent: UAS[ua_kind][platform], platform: platform,
                                                    ip: "1.2.3.4", remote_ip: "1.2.3.4")
  end

  def normalize(decision)
    return decision unless decision.is_a?(Hash) && decision[:locals]

    locals = decision[:locals].transform_values { |json| JSON.parse(json) }
    decision.merge(locals: locals)
  end
end
