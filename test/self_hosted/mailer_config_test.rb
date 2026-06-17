require "test_helper"

# Locks in the from-address fallback literals so MAILER_FROM unset = unchanged.
# The SMTP branch / MAILER_FROM override are boot-time config, not re-evaluable mid-test.
class SelfHostedMailerConfigTest < ActiveSupport::TestCase
  test "ApplicationMailer default from falls back to noreply@grovs.io when MAILER_FROM unset" do
    # In the test environment MAILER_FROM is not set, so the fallback literal applies.
    assert_equal "noreply@grovs.io", ApplicationMailer.default[:from]
  end

  test "Devise mailer_sender falls back to the branded Grovs address when MAILER_FROM unset" do
    assert_equal "Grovs <noreply@grovs.io>", Devise.mailer_sender
  end
end
