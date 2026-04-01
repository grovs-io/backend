require "test_helper"

class NewMemberMailerTest < ActionMailer::TestCase
  fixtures :users, :instances

  setup do
    @user = users(:admin_user)
    @instance = instances(:one)
  end

  test "new_member sends to user email" do
    email = NewMemberMailer.new_member(@instance, @user)

    assert_equal [@user.email], email.to
    assert_equal ["noreply@grovs.io"], email.from
  end

  test "new_member has correct subject" do
    email = NewMemberMailer.new_member(@instance, @user)

    assert_equal "New project access - grovs.", email.subject
  end

  test "new_member body contains link to project with instance_id" do
    email = NewMemberMailer.new_member(@instance, @user)
    body = email.body.encoded

    assert_match "instance_id=#{@instance.id}", body
  end

  test "new_member body contains check project button" do
    email = NewMemberMailer.new_member(@instance, @user)
    body = email.body.encoded

    assert_match "Check project", body
  end

  test "new_member body contains support email" do
    email = NewMemberMailer.new_member(@instance, @user)
    body = email.body.encoded

    assert_match "support@grovs.io", body
  end

  test "new_member is deliverable" do
    assert_emails 1 do
      NewMemberMailer.new_member(@instance, @user).deliver_now
    end
  end

  test "new_member sends to different users correctly" do
    admin_email = NewMemberMailer.new_member(@instance, users(:admin_user))
    member_email = NewMemberMailer.new_member(@instance, users(:member_user))

    assert_equal ["admin@example.com"], admin_email.to
    assert_equal ["member@example.com"], member_email.to
  end

  test "new_member uses correct instance in project link" do
    email_one = NewMemberMailer.new_member(instances(:one), @user)
    email_two = NewMemberMailer.new_member(instances(:two), @user)

    assert_match "instance_id=#{instances(:one).id}", email_one.body.encoded
    assert_match "instance_id=#{instances(:two).id}", email_two.body.encoded
  end
end
