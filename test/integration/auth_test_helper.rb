module AuthTestHelper
  API_PREFIX = "/api/v1".freeze
  SDK_PREFIX = "/api/v1/sdk".freeze
  IAP_PREFIX = "/api/v1/iap".freeze

  def api_host
    "api.example.com"
  end

  def sdk_host
    "sdk.example.com"
  end

  def doorkeeper_headers_for(user)
    app = Doorkeeper::Application.create!(
      name: "Integration Test",
      redirect_uri: "urn:ietf:wg:oauth:2.0:oob"
    )
    token = Doorkeeper::AccessToken.create!(
      resource_owner_id: user.id,
      application_id: app.id,
      expires_in: 7200
    )
    {
      "Authorization" => "Bearer #{token.token}",
      "Host" => api_host
    }
  end

  def expired_doorkeeper_headers_for(user)
    app = Doorkeeper::Application.create!(
      name: "Integration Test Expired",
      redirect_uri: "urn:ietf:wg:oauth:2.0:oob"
    )
    token = Doorkeeper::AccessToken.create!(
      resource_owner_id: user.id,
      application_id: app.id,
      expires_in: -1
    )
    {
      "Authorization" => "Bearer #{token.token}",
      "Host" => api_host
    }
  end

  def server_sdk_headers_for(project, environment: "production")
    {
      "PROJECT-KEY" => project.instance.api_key,
      "ENVIRONMENT" => environment,
      "Host" => sdk_host
    }
  end

  def sdk_headers_for(project, visitor, platform: "ios", identifier: nil)
    identifier ||= case platform
                   when "ios" then "com.test.iosapp"
                   when "android" then "com.test.androidapp"
                   else "com.test.app"
                   end

    {
      "PROJECT-KEY" => project.identifier,
      "PLATFORM" => platform,
      "IDENTIFIER" => identifier,
      "LINKSQUARED" => visitor.hashid,
      "Host" => sdk_host
    }
  end

  def sdk_auth_headers_for(project, platform: "ios", identifier: nil)
    identifier ||= case platform
                   when "ios" then "com.test.iosapp"
                   when "android" then "com.test.androidapp"
                   else "com.test.app"
                   end

    {
      "PROJECT-KEY" => project.identifier,
      "PLATFORM" => platform,
      "IDENTIFIER" => identifier,
      "Host" => sdk_host
    }
  end

  def api_headers
    { "Host" => api_host }
  end
end
