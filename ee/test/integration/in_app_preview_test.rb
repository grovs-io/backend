require "test_helper"
require_relative "../../../test/integration/auth_test_helper"

class InAppPreviewTest < ActionDispatch::IntegrationTest
  include AuthTestHelper

  def get_preview(headers = {})
    get "/in_app/preview", headers: { "Host" => api_host }.merge(headers)
  end

  test "renders ok with no auth" do
    get_preview
    assert_response :ok
    assert_equal "text/html", response.media_type
  end

  test "has no X-Frame-Options" do
    get_preview
    assert_nil response.headers["X-Frame-Options"]
  end

  test "sends the exact CSP with frame-ancestors built from the dashboard origins, local http hosts outside production" do
    get_preview
    origins = Grovs.in_app_preview_origins
    local = " http://localhost:* http://127.0.0.1:* http://*.lvh.me:* http://*.localhost:*"
    expected = "default-src 'none'; script-src 'unsafe-inline' https:; style-src 'unsafe-inline' https:#{local}; " \
               "img-src https: data:#{local}; media-src https:#{local}; font-src https: data:; connect-src https:; frame-src https:; " \
               "frame-ancestors #{origins.empty? ? "'none'" : origins.join(' ')}"
    assert_equal expected, response.headers["Content-Security-Policy"]
  end

  test "every local host the CSP allows is one validation accepts outside production" do
    hosts = Public::InAppPreviewController::LOCAL_MEDIA.split.map { |h| h.sub(":*", ":3000").sub("*.", "app.") }
    assert_equal 4, hosts.size
    hosts.each { |h| assert_match InAppDefinition::LOCAL_HTTP, "#{h}/a.png" }
  end

  test "embeds the current bridge.js verbatim, as a JSON string" do
    get_preview
    json = response.body[/var BRIDGE = ("(?:[^"\\]|\\.)*");/, 1]
    assert json, "expected the page to define BRIDGE as a JSON string"
    assert_equal File.read(Rails.root.join("ee/config/in_app/bridge.js")), JSON.parse(json)
  end

  test "embeds the allowed origins used for the CSP" do
    get_preview
    json = response.body[/var ALLOWED_ORIGINS = (\[.*?\]);/, 1]
    assert json, "expected the page to define ALLOWED_ORIGINS as a JSON array"
    assert_equal Grovs.in_app_preview_origins, JSON.parse(json)
  end

  test "the built page has exactly one </script per script tag in the template" do
    template = File.read(Rails.root.join("ee/config/in_app/preview.html"))
    expected = template.scan(%r{</script}i).size
    get_preview
    assert_equal expected, response.body.scan(%r{</script}i).size
  end
end
