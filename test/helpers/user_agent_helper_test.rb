require "test_helper"

class UserAgentHelperTest < ActiveSupport::TestCase
  include UserAgentHelper

  # ---------------------------------------------------------------------------
  # Known social media preview bots — must detect
  # ---------------------------------------------------------------------------

  test "detects Facebook crawler" do
    assert social_media_preview?("facebookexternalhit/1.1 (+http://www.facebook.com/externalhit_uatext.php)")
    assert social_media_preview?("facebot/1.0")
  end

  test "detects Twitter bot" do
    assert social_media_preview?("Twitterbot/1.0")
  end

  test "detects LinkedIn bot" do
    assert social_media_preview?("LinkedInBot/1.0 (compatible; Mozilla/5.0)")
  end

  test "detects WhatsApp" do
    assert social_media_preview?("WhatsApp/2.21.4.22 A")
  end

  test "detects Slack bot" do
    assert social_media_preview?("Slackbot-LinkExpanding 1.0 (+https://api.slack.com/robots)")
    assert social_media_preview?("Slack-ImgProxy (+https://api.slack.com/robots)")
  end

  test "detects Telegram bot" do
    assert social_media_preview?("TelegramBot (like TwitterBot)")
  end

  test "detects Discord bot" do
    assert social_media_preview?("Mozilla/5.0 (compatible; Discordbot/2.0; +https://discordapp.com)")
  end

  test "detects iMessage / CFNetwork preview fetcher" do
    assert social_media_preview?("CFNetwork/1485 Darwin/23.1.0")
  end

  test "detects Microsoft Teams" do
    assert social_media_preview?("Mozilla/5.0 Teams/1.0")
    assert social_media_preview?("Mozilla/5.0 MSTeams/1.0")
  end

  test "detects Bing preview" do
    assert social_media_preview?("Mozilla/5.0 (compatible; bingpreview/2.0)")
  end

  test "detects Google tools" do
    assert social_media_preview?("Mozilla/5.0 Google-InspectionTool/1.0")
    assert social_media_preview?("Google-Structured-Data-Testing-Tool")
  end

  # ---------------------------------------------------------------------------
  # Case insensitivity
  # ---------------------------------------------------------------------------

  test "detection is case insensitive" do
    assert social_media_preview?("FACEBOOKEXTERNALHIT/1.1")
    assert social_media_preview?("twitterbot/1.0")
    assert social_media_preview?("LINKEDINBOT/1.0")
    assert social_media_preview?("slackBot/1.0")
  end

  # ---------------------------------------------------------------------------
  # Real browser user agents — must NOT detect
  # ---------------------------------------------------------------------------

  test "does not flag Chrome desktop" do
    assert_not social_media_preview?(
      "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36"
    )
  end

  test "does not flag Safari mobile" do
    assert_not social_media_preview?(
      "Mozilla/5.0 (iPhone; CPU iPhone OS 17_1 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.1 Mobile/15E148 Safari/604.1"
    )
  end

  test "does not flag Firefox" do
    assert_not social_media_preview?(
      "Mozilla/5.0 (Windows NT 10.0; Win64; x64; rv:109.0) Gecko/20100101 Firefox/120.0"
    )
  end

  # ---------------------------------------------------------------------------
  # Edge cases
  # ---------------------------------------------------------------------------

  test "returns false for nil user agent" do
    assert_not social_media_preview?(nil)
  end

  test "returns false for empty string" do
    assert_not social_media_preview?("")
  end

  test "returns false for blank whitespace" do
    assert_not social_media_preview?("   ")
  end

  test "bot string embedded in longer user agent still detected" do
    assert social_media_preview?(
      "Mozilla/5.0 (compatible; facebookexternalhit/1.1; +http://www.facebook.com)"
    )
  end
end
