class InAppBrowserDetector
  PATTERN = %r{FBAN/|FBAV/|FB_IAB|Instagram|Barcelona \d|musical_ly|BytedanceWebview|TikTok|LinkedInApp|Snapchat|Twitter for iPhone|TwitterAndroid}

  def self.match?(user_agent)
    user_agent.present? && PATTERN.match?(user_agent)
  end
end
