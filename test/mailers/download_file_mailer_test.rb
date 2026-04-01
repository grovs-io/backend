require "test_helper"

class DownloadFileMailerTest < ActionMailer::TestCase
  fixtures :users

  setup do
    @user = users(:admin_user)
    @file = OpenStruct.new(
      name: "activity-export-2026-03",
      file_resource: "https://s3.example.com/downloads/activity-export-2026-03.csv"
    )
  end

  test "download_file sends to user email" do
    email = DownloadFileMailer.download_file(@file, @user)

    assert_equal [@user.email], email.to
    assert_equal ["noreply@grovs.io"], email.from
  end

  test "download_file has correct subject" do
    email = DownloadFileMailer.download_file(@file, @user)

    assert_equal "Data export - grovs", email.subject
  end

  test "download_file body contains file name" do
    email = DownloadFileMailer.download_file(@file, @user)
    body = email.body.encoded

    assert_match @file.name, body
  end

  test "download_file body contains download link" do
    email = DownloadFileMailer.download_file(@file, @user)
    body = email.body.encoded

    assert_match @file.file_resource, body
  end

  test "download_file body mentions 24 hour expiration" do
    email = DownloadFileMailer.download_file(@file, @user)
    body = email.body.encoded

    assert_match "24 hours", body
  end

  test "download_file body contains support email" do
    email = DownloadFileMailer.download_file(@file, @user)
    body = email.body.encoded

    assert_match "support@grovs.io", body
  end

  test "download_file is deliverable" do
    assert_emails 1 do
      DownloadFileMailer.download_file(@file, @user).deliver_now
    end
  end

  test "download_file renders different file names correctly" do
    other_file = OpenStruct.new(
      name: "links-export-campaign-x",
      file_resource: "https://s3.example.com/downloads/links-export.csv"
    )
    email = DownloadFileMailer.download_file(other_file, @user)
    body = email.body.encoded

    assert_match "links-export-campaign-x", body
    assert_no_match(/activity-export/, body)
  end
end
