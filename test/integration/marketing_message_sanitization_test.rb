require "test_helper"

class MarketingMessageSanitizationTest < ActionDispatch::IntegrationTest
  fixtures :instances, :projects, :domains

  def render_message(html)
    notification = Notification.create!(project: projects(:one), html: html)
    domain = domains(:one)
    get "/mm/#{notification.hashid}", headers: { "Host" => "#{domain.subdomain}.#{domain.domain}" }
    response.body
  end

  test "scrubs script hoisted out of a disallowed tag" do
    body = render_message("<unknowntag><script>alert(1)</script></unknowntag>")
    assert_not_includes body, "<script"
    assert_not_includes body, "alert(1)"
  end

  test "scrubs script nested several disallowed tags deep" do
    body = render_message("<foo><bar><baz><script>alert(2)</script></baz></bar></foo>")
    assert_not_includes body, "<script"
    assert_not_includes body, "alert(2)"
  end

  test "keeps allowed children of a disallowed tag" do
    body = render_message("<unknowntag><p>kept text</p></unknowntag>")
    assert_includes body, "kept text"
    assert_not_includes body, "unknowntag"
  end

  test "strips javascript scheme with embedded whitespace" do
    body = render_message(%(<a href="java\tscript:alert(3)">x</a>))
    assert_not_includes body, "script:alert"
  end

  test "strips vbscript scheme" do
    body = render_message(%(<a href="vbscript:msgbox(1)">x</a>))
    assert_not_includes body, "vbscript"
  end

  test "keeps ordinary links and formatting" do
    body = render_message(%(<p><a href="https://example.com">ok</a> <b>bold</b></p>))
    assert_includes body, %(href="https://example.com")
    assert_includes body, "<b>bold</b>"
  end
end
