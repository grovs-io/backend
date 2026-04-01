require "test_helper"

class CookieServiceTest < ActiveSupport::TestCase
  test "reads the LINKSQUARED cookie from request" do
    request = OpenStruct.new(cookies: { "LINKSQUARED" => "abc123", "other" => "ignored" })
    assert_equal "abc123", CookieService.get_cookie_from_request(request)
  end

  test "returns nil when LINKSQUARED cookie is absent" do
    request = OpenStruct.new(cookies: {})
    assert_nil CookieService.get_cookie_from_request(request)
  end

  test "sets cookie with correct name, value, and ~5 year expiry" do
    captured = {}
    response = Object.new
    response.define_singleton_method(:set_cookie) do |name, opts| 
      captured[:name] = name
      captured[:opts] = opts
    end

    CookieService.set_cookie_to_response(response, "device-xyz")

    assert_equal "LINKSQUARED", captured[:name]
    assert_equal "device-xyz", captured[:opts][:value]
    assert_in_delta 5.years.from_now.to_f, captured[:opts][:expires].to_f, 60
  end
end
