require "test_helper"

class MarketingMessagesTest < ActionDispatch::IntegrationTest
  fixtures :instances, :projects, :domains, :notifications

  setup do
    @domain = domains(:one)
    @notification = notifications(:one)
  end

  test "renders notification HTML with allowed tags intact" do
    @notification.update_columns(html: "<p>Hello <strong>world</strong></p>")

    get "/mm/#{@notification.hashid}", headers: public_host_headers
    assert_response :ok
    assert_includes response.body, "<p>"
    assert_includes response.body, "<strong>"
    assert_includes response.body, "Hello"
  end

  test "strips script tags from notification HTML" do
    @notification.update_columns(html: '<p>Safe</p><script>alert("xss")</script>')

    get "/mm/#{@notification.hashid}", headers: public_host_headers
    assert_response :ok
    assert_includes response.body, "<p>Safe</p>"
    assert_not_includes response.body, "<script>"
  end

  test "strips event handler attributes from HTML elements" do
    @notification.update_columns(html: '<img src="x" onerror="alert(1)"><a href="https://ok.com" onclick="steal()">click</a>')

    get "/mm/#{@notification.hashid}", headers: public_host_headers
    assert_response :ok
    assert_not_includes response.body, "onerror"
    assert_not_includes response.body, "onclick"
    assert_includes response.body, "<a"  # tag preserved, handler stripped
  end

  test "strips dangerous CSS url() from style attributes" do
    @notification.update_columns(html: '<div style="background: url(https://evil.com/steal)">content</div>')

    get "/mm/#{@notification.hashid}", headers: public_host_headers
    assert_response :ok
    assert_includes response.body, "content"
    assert_not_includes response.body, "url("
  end

  test "strips javascript protocol from CSS" do
    @notification.update_columns(html: '<div style="background: javascript:alert(1)">content</div>')

    get "/mm/#{@notification.hashid}", headers: public_host_headers
    assert_response :ok
    assert_not_includes response.body, "javascript:"
  end

  test "returns not_found template for nonexistent notification ID" do
    get "/mm/nonexistent_hashid_xyz", headers: public_host_headers
    assert_response :ok
    assert_includes response.body, "Lost in the Void"
  end

  test "removes X-Frame-Options header to allow iframe embedding" do
    @notification.update_columns(html: "<p>Embeddable</p>")

    get "/mm/#{@notification.hashid}", headers: public_host_headers
    assert_response :ok
    assert_nil response.headers["X-Frame-Options"]
  end

  # --- Additional XSS vectors ---

  test "strips IE behavior CSS pattern" do
    @notification.update_columns(html: '<div style="behavior: url(xss.htc)">content</div>')

    get "/mm/#{@notification.hashid}", headers: public_host_headers
    assert_response :ok
    assert_not_includes response.body, "behavior"
    assert_includes response.body, "content"
  end

  test "strips Firefox -moz-binding CSS pattern" do
    @notification.update_columns(html: '<div style="-moz-binding: url(xss.xml)">content</div>')

    get "/mm/#{@notification.hashid}", headers: public_host_headers
    assert_response :ok
    assert_not_includes response.body, "-moz-binding"
  end

  test "strips IE expression() CSS pattern" do
    @notification.update_columns(html: '<div style="width: expression(alert(1))">content</div>')

    get "/mm/#{@notification.hashid}", headers: public_host_headers
    assert_response :ok
    assert_not_includes response.body, "expression("
  end

  test "strips @import CSS pattern" do
    @notification.update_columns(html: '<div style="@import url(evil.css)">content</div>')

    get "/mm/#{@notification.hashid}", headers: public_host_headers
    assert_response :ok
    assert_not_includes response.body, "@import"
  end

  test "javascript: protocol in href is stripped" do
    @notification.update_columns(html: '<a href="javascript:alert(1)">click</a>')

    get "/mm/#{@notification.hashid}", headers: public_host_headers
    assert_response :ok
    assert_includes response.body, "click"
    assert_not_includes response.body, "javascript:"
  end

  test "data: URI scheme in href is stripped" do
    @notification.update_columns(html: '<a href="data:text/html,&lt;script&gt;alert(1)&lt;/script&gt;">click</a>')

    get "/mm/#{@notification.hashid}", headers: public_host_headers
    assert_response :ok
    assert_includes response.body, "click"
    assert_not_includes response.body, "data:"
  end

  # --- Allowed content preserved ---

  test "safe inline styles are preserved" do
    @notification.update_columns(html: '<div style="color: red; font-size: 16px;">styled</div>')

    get "/mm/#{@notification.hashid}", headers: public_host_headers
    assert_response :ok
    assert_includes response.body, 'style="color: red; font-size: 16px;"'
  end

  test "complex allowed HTML structure is preserved" do
    html = '<h1>Title</h1><p>Text</p><ul><li>Item 1</li><li>Item 2</li></ul>' \
           '<a href="https://safe.com" target="_blank">Link</a>' \
           '<img src="https://img.com/x.jpg" alt="image">'
    @notification.update_columns(html: html)

    get "/mm/#{@notification.hashid}", headers: public_host_headers
    assert_response :ok
    assert_includes response.body, "<h1>Title</h1>"
    assert_includes response.body, "<li>Item 1</li>"
    assert_includes response.body, 'href="https://safe.com"'
    assert_includes response.body, 'alt="image"'
  end

  test "disallowed tags are unwrapped but content preserved" do
    @notification.update_columns(html: '<form><input type="text" value="evil"></form>')

    get "/mm/#{@notification.hashid}", headers: public_host_headers
    assert_response :ok
    assert_not_includes response.body, "<form>"
    # Content from disallowed children is preserved as text
  end

  # --- Headers ---

  test "no-cache headers are set" do
    get "/mm/#{@notification.hashid}", headers: public_host_headers
    assert_response :ok
    assert_includes response.headers["Cache-Control"], "no-store"
  end

  test "content type is HTML" do
    get "/mm/#{@notification.hashid}", headers: public_host_headers
    assert_response :ok
    assert_match "text/html", response.content_type
  end

  private

  def public_host_headers
    { "Host" => "#{@domain.subdomain}.#{@domain.domain}" }
  end
end
