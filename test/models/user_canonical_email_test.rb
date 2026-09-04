require "test_helper"

class UserCanonicalEmailTest < ActiveSupport::TestCase
  test "finds a user regardless of case and surrounding whitespace" do
    email = "canon_#{SecureRandom.hex(4)}@test.com"
    user = User.create!(email: email, password: "password123")

    assert_equal user.id, User.find_for_email(email).id
    assert_equal user.id, User.find_for_email(email.upcase).id
    assert_equal user.id, User.find_for_email("  #{email.upcase}  ").id
  end

  test "returns nil for blank input instead of matching an arbitrary row" do
    assert_nil User.find_for_email(nil)
    assert_nil User.find_for_email("   ")
  end

  test "password reset locates a mixed-case address instead of silently doing nothing" do
    email = "reset_#{SecureRandom.hex(4)}@test.com"
    user = User.create!(email: email, password: "password123")

    found = UserAccountService.request_password_reset(email: "  #{email.upcase}  ")

    assert_equal user.id, found&.id, "the endpoint reports success either way, so a miss is silent"
    assert_not_nil user.reload.reset_password_token, "a reset token must actually be issued"
  end
end
