require "test_helper"

# A marketing message must only render under its own project's host, never under
# another tenant's (custom or sqd.link) domain.
class MarketingMessageScopeTest < ActionDispatch::IntegrationTest
  fixtures :instances, :projects, :domains

  setup do
    @notification = Notification.create!(project: projects(:one), html: "<p>Hello tenant one</p>")
  end

  def host_for(domain)
    "#{domain.subdomain}.#{domain.domain}"
  end

  test "renders the marketing message on the notification's own project host" do
    get "/mm/#{@notification.hashid}", headers: { "Host" => host_for(domains(:one)) }
    assert_response :ok
    assert_includes response.body, "Hello tenant one"
  end

  test "does not render the message under another tenant's host" do
    get "/mm/#{@notification.hashid}", headers: { "Host" => host_for(domains(:two)) }
    assert_not_includes response.body, "Hello tenant one"
  end
end
