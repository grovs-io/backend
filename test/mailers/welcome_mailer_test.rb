require "test_helper"

class WelcomeMailerTest < ActionMailer::TestCase
  fixtures :users

  test "welcome sends to user email with correct subject" do
    user = users(:admin_user)
    email = WelcomeMailer.welcome(user)

    assert_equal [user.email], email.to
    assert_equal "Welcome!", email.subject
    assert_equal ["noreply@grovs.io"], email.from
  end

  test "welcome body contains user name in greeting" do
    user = users(:admin_user)
    email = WelcomeMailer.welcome(user)
    body = email.body.encoded

    assert_match user.name, body
  end

  test "welcome body contains product features" do
    user = users(:admin_user)
    email = WelcomeMailer.welcome(user)
    body = email.body.encoded

    assert_match "Deep Linking", body
    assert_match "Attribution Tracking", body
    assert_match "Analytics", body
  end

  test "welcome body contains support email" do
    user = users(:admin_user)
    email = WelcomeMailer.welcome(user)
    body = email.body.encoded

    assert_match "support@grovs.io", body
  end

  test "welcome email is deliverable" do
    user = users(:admin_user)

    assert_emails 1 do
      WelcomeMailer.welcome(user).deliver_now
    end
  end

  test "welcome sends to correct user when different users provided" do
    admin = users(:admin_user)
    member = users(:member_user)

    admin_email = WelcomeMailer.welcome(admin)
    member_email = WelcomeMailer.welcome(member)

    assert_equal [admin.email], admin_email.to
    assert_equal [member.email], member_email.to
    assert_not_equal admin_email.to, member_email.to
  end
end
