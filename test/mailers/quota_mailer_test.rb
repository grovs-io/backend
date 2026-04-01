require "test_helper"

class QuotaMailerTest < ActionMailer::TestCase
  fixtures :users, :instances

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
end
