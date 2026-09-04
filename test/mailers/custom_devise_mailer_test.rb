require "test_helper"

class CustomDeviseMailerTest < ActionMailer::TestCase
  setup do
    @mailer = CustomDeviseMailer.new
  end

  test "subject_for invitation_instructions returns custom subject" do
    assert_equal "You're invited to join Grovs.", @mailer.send(:subject_for, :invitation_instructions)
  end

  test "subject_for invitation_instructions works with string key" do
    assert_equal "You're invited to join Grovs.", @mailer.send(:subject_for, "invitation_instructions")
  end

  test "subject_for reset_password_instructions returns custom subject" do
    assert_equal "Change password link for Grovs.", @mailer.send(:subject_for, :reset_password_instructions)
  end

  test "subject_for reset_password_instructions works with string key" do
    assert_equal "Change password link for Grovs.", @mailer.send(:subject_for, "reset_password_instructions")
  end

  test "invitation subject is distinct from reset password subject" do
    invitation = @mailer.send(:subject_for, :invitation_instructions)
    reset = @mailer.send(:subject_for, :reset_password_instructions)

    assert_not_equal invitation, reset
  end

  test "devise mail templates render without the optional path env vars" do
    saved = {
      "REACT_HOST_CHANGE_PASSWORD_PATH" => ENV.delete("REACT_HOST_CHANGE_PASSWORD_PATH"),
      "REACT_HOST_ACCEPT_INVITE_PATH" => ENV.delete("REACT_HOST_ACCEPT_INVITE_PATH")
    }
    user = User.create!(email: "mail_render_#{SecureRandom.hex(4)}@test.com", password: "password123")

    reset = Devise.mailer.reset_password_instructions(user, "tok123")
    assert_includes reset.body.to_s, "/new-password/?token=tok123"

    invite = Devise.mailer.invitation_instructions(user, "tok456")
    assert_includes invite.body.to_s, "/accept-invite/?token=tok456"
  ensure
    saved.each { |k, v| ENV[k] = v if v }
  end
end
