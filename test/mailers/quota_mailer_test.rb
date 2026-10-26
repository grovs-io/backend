require "test_helper"

class QuotaMailerTest < ActionMailer::TestCase
  fixtures :users, :instances, :projects

  setup do
    @user = users(:admin_user)
    @instance = instances(:one)
  end

  # === quota_exceeded ===

  test "quota_exceeded sends to user email" do
    email = QuotaMailer.quota_exceeded(@user, 120, 12_000, 10_000, @instance.id)

    assert_equal [@user.email], email.to
    assert_equal ["noreply@grovs.io"], email.from
  end

  test "quota_exceeded has correct subject" do
    email = QuotaMailer.quota_exceeded(@user, 120, 12_000, 10_000, @instance.id)

    assert_equal "Quota exceeded - Grovs", email.subject
  end

  test "quota_exceeded body shows current MAU count" do
    email = QuotaMailer.quota_exceeded(@user, 120, 12_000, 10_000, @instance.id)
    body = email.body.encoded

    assert_match "12.000", body, "Should show formatted current MAUs"
  end

  test "quota_exceeded body shows plan MAU limit" do
    email = QuotaMailer.quota_exceeded(@user, 120, 12_000, 10_000, @instance.id)
    body = email.body.encoded

    assert_match "10.000", body, "Should show formatted plan MAU limit"
  end

  test "quota_exceeded body contains upgrade link with instance_id" do
    email = QuotaMailer.quota_exceeded(@user, 120, 12_000, 10_000, @instance.id)
    body = email.body.encoded

    assert_match "instance_id=#{@instance.id}", body
    assert_match "Upgrade Your Plan", body
  end

  test "quota_exceeded body contains support email" do
    email = QuotaMailer.quota_exceeded(@user, 120, 12_000, 10_000, @instance.id)
    body = email.body.encoded

    assert_match "support@grovs.io", body
  end

  test "quota_exceeded is deliverable" do
    assert_emails 1 do
      QuotaMailer.quota_exceeded(@user, 120, 12_000, 10_000, @instance.id).deliver_now
    end
  end

  # === quota_progress ===

  test "quota_progress sends to user email" do
    email = QuotaMailer.quota_progress(@user, 85, 8_500, 10_000, @instance.id)

    assert_equal [@user.email], email.to
    assert_equal ["noreply@grovs.io"], email.from
  end

  test "quota_progress has correct subject" do
    email = QuotaMailer.quota_progress(@user, 85, 8_500, 10_000, @instance.id)

    assert_equal "You're nearing your monthly usage limit - Grovs", email.subject
  end

  test "quota_progress body shows usage percentage" do
    email = QuotaMailer.quota_progress(@user, 85, 8_500, 10_000, @instance.id)
    body = email.body.encoded

    assert_match "85%", body
  end

  test "quota_progress body shows current and plan MAUs" do
    email = QuotaMailer.quota_progress(@user, 85, 8_500, 10_000, @instance.id)
    body = email.body.encoded

    assert_match "8.500", body, "Should show formatted current MAUs"
    assert_match "10.000", body, "Should show formatted plan MAU limit"
  end

  test "quota_progress body contains upgrade link with instance_id" do
    email = QuotaMailer.quota_progress(@user, 85, 8_500, 10_000, @instance.id)
    body = email.body.encoded

    assert_match "instance_id=#{@instance.id}", body
    assert_match "View Upgrade Options", body
  end

  test "quota_progress is deliverable" do
    assert_emails 1 do
      QuotaMailer.quota_progress(@user, 85, 8_500, 10_000, @instance.id).deliver_now
    end
  end

  # === different users get different emails ===

  test "quota_exceeded targets the specific user email passed in" do
    admin_email = QuotaMailer.quota_exceeded(users(:admin_user), 120, 12_000, 10_000, @instance.id)
    member_email = QuotaMailer.quota_exceeded(users(:member_user), 120, 12_000, 10_000, @instance.id)

    assert_equal ["admin@example.com"], admin_email.to
    assert_equal ["member@example.com"], member_email.to
  end

  test "band_exceeded goes to a plain address and says nothing is paused" do
    mail = QuotaMailer.band_exceeded("owner@grovs-test.invalid", 120, 300_000, 250_000, 42)
    assert_equal ["owner@grovs-test.invalid"], mail.to
    assert_equal "You've passed your plan's MAU band (project 42) - Grovs", mail.subject
    assert_includes mail.body.encoded, "Nothing is paused"
  end

  test "band_progress goes to a plain address" do
    mail = QuotaMailer.band_progress("a@b.invalid", 90, 225_000, 250_000, 42)
    assert_equal ["a@b.invalid"], mail.to
    assert_equal "You're nearing your plan's MAU band (project 42) - Grovs", mail.subject
  end

  test "band_exceeded sets reply_to from BILLING_ALERT_EMAIL" do
    original = ENV["BILLING_ALERT_EMAIL"]
    ENV["BILLING_ALERT_EMAIL"] = "billing@grovs-test.invalid"

    mail = QuotaMailer.band_exceeded("owner@grovs-test.invalid", 120, 300_000, 250_000, 42)
    assert_equal ["billing@grovs-test.invalid"], mail.reply_to
  ensure
    ENV["BILLING_ALERT_EMAIL"] = original
  end

  test "band_progress has no reply_to when BILLING_ALERT_EMAIL is unset" do
    original = ENV["BILLING_ALERT_EMAIL"]
    ENV.delete("BILLING_ALERT_EMAIL")

    mail = QuotaMailer.band_progress("a@b.invalid", 90, 225_000, 250_000, 42)
    assert_nil mail.reply_to
  ensure
    ENV["BILLING_ALERT_EMAIL"] = original
  end

  test "band subject uses the instance's production project name when present" do
    mail = QuotaMailer.band_exceeded("owner@grovs-test.invalid", 120, 300_000, 250_000, @instance.id)
    assert_equal "You've passed your plan's MAU band (#{@instance.production.name}) - Grovs", mail.subject
  end

  test "band subject falls back to project id when the instance does not exist" do
    mail = QuotaMailer.band_progress("a@b.invalid", 90, 225_000, 250_000, 999_999)
    assert_equal "You're nearing your plan's MAU band (project 999999) - Grovs", mail.subject
  end

  test "band templates use the same number format throughout" do
    mail = QuotaMailer.band_exceeded("owner@grovs-test.invalid", 120, 300_000, 250_000, 42)
    body = mail.body.encoded

    assert_includes body, "300,000"
    assert_includes body, "250,000"
    assert_not_includes body, "300.000"
    assert_not_includes body, "250.000"
  end
end
