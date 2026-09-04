require "test_helper"

class MailDeliveryJobTest < ActiveJob::TestCase
  include ActionMailer::TestHelper

  fixtures :users

  setup { ActionMailer::Base.deliveries.clear }

  test "discards the delivery when the mailer's record was destroyed before performing" do
    user = User.create!(email: "gone@example.com", password: "Password123!", name: "Gone")
    WelcomeMailer.welcome(user).deliver_later
    user.destroy!

    assert_nothing_raised do
      assert_no_emails { perform_enqueued_jobs }
    end
  end

  test "discards the delivery when a non-recipient argument was destroyed" do
    instance = Instance.create!(uri_scheme: "doomed", api_key: SecureRandom.hex(8))
    NewMemberMailer.new_member(instance, users(:admin_user)).deliver_later
    instance.destroy!

    assert_nothing_raised do
      assert_no_emails { perform_enqueued_jobs }
    end
  end

  test "deliver_later routes through the discarding delivery job" do
    assert_enqueued_with(job: MailDeliveryJob) do
      WelcomeMailer.welcome(users(:admin_user)).deliver_later
    end
  end

  test "delivers normally when the record still exists" do
    WelcomeMailer.welcome(users(:admin_user)).deliver_later

    assert_emails 1 do
      perform_enqueued_jobs
    end
  end
end
