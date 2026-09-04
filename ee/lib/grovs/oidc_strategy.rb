require "omniauth_openid_connect"

module Grovs
  class OidcStrategy < OmniAuth::Strategies::OpenIDConnect
    # Only the gem's own failures; StandardError would also swallow the Rails app run by super.
    RESCUED = [OpenIDConnect::Exception, JSON::JWT::Exception, SWD::Exception, Rack::OAuth2::Client::Error, Faraday::Error].freeze

    def request_phase
      return fail!(:setup_failed) if env[Grovs::SSO::ENV_SETUP_ERROR]

      super
    end

    def callback_phase
      return fail!(:setup_failed) if env[Grovs::SSO::ENV_SETUP_ERROR]

      super
    rescue *RESCUED => e
      fail!(:invalid_credentials, e)
    end
  end
end
