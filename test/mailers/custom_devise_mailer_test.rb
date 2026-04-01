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
end
