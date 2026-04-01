class CookieService

  COOKIE_NAME = "LINKSQUARED".freeze

  class << self
    def get_cookie_from_request(request)
      request.cookies[COOKIE_NAME]
    end

    def set_cookie_to_response(response, value)
      response.set_cookie(
          COOKIE_NAME,
          value: value,
          expires: 5.years.from_now,
          httponly: false,
          secure: false
        )
    end
  end

end
