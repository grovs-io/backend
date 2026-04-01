module UserAgentHelper
  SOCIAL_MEDIA_PREVIEW_AGENTS = [
    # === Facebook ===
    /facebookexternalhit/i,
    /facebot/i,

    # === X (Twitter) ===
    /twitterbot/i,

    # === LinkedIn ===
    /linkedinbot/i,

    # === WhatsApp ===
    /whatsapp/i,

    # === Slack ===
    /slackbot/i,
    /slack-imgproxy/i,

    # === Telegram ===
    /telegrambot/i,

    # === Discord ===
    /discordbot/i,

    # === Skype ===
    /skypeuripreview/i,

    # === Viber ===
    /viber/i,

    # === Pinterest ===
    /pinterest/i,

    # === Reddit ===
    /redditbot/i,

    # === Quora ===
    /quora link preview/i,

    # === Apple Mail & Outlook on Mac ===
    /macoutlook/i,
    %r{mozilla/5\.0.*macoutlook}i,

    # === iMessage / Safari Preview on macOS/iOS (not a bot, but fetches OG tags) ===
    /cfnetwork/i,               # iOS/macOS preview fetcher
    # /applewebkit.*\(KHTML, like Gecko\).*safari/i,  # generic Safari preview style UA (fallback)
    # /version\/.* safari/i,      # common in preview loaders

    # === Microsoft Teams / Office ===
    /teams/i,
    /msteams/i,
    /microsoft.*(office|preview)/i,

    # === Google Tools ===
    /google-structured-data-testing-tool/i,
    /google-inspectiontool/i,

    # === Embed / Aggregator tools ===
    /embedly/i,
    /nuzzel/i,
    /iframely/i,
    /ogpreview/i,
    /glimpsebot/i,

    # === VK / Yandex ===
    /vkshare/i,

    # === Outbrain / other native ad previewers ===
    /outbrain/i,

    # === Email clients that preview links ===
    /thunderbird/i,
    /easymail/i,
    /superhuman/i,

    # === Bing link previews ===
    /bingpreview/i,

    # === Generic "preview" fallback ===
    /preview/i
  ].freeze

  def social_media_preview?(user_agent)
    return false if user_agent.blank?

    SOCIAL_MEDIA_PREVIEW_AGENTS.any? { |pattern| user_agent =~ pattern }
  end
end