require "test_helper"
require "csv"

class ExportLinkDataJobTest < ActiveSupport::TestCase
  fixtures :instances, :projects, :users, :instance_roles, :links, :domains, :redirect_configs

  setup do
    @job = ExportLinkDataJob.new
    @project = projects(:one)
    @user = users(:admin_user)
    # Avoid .map on string fixture data
    Link.where(domain: @project.domain).update_all(data: nil)
    # Clear pre-existing stats so we control the numbers
    LinkDailyStatistic.where(project_id: @project.id).delete_all
  end

  test "CSV contains correct per-link metric values from LinkDailyStatistic" do
    link = links(:basic_link)
    LinkDailyStatistic.create!(
      project_id: @project.id, link: link, event_date: Date.parse("2026-03-10"),
      platform: "ios", views: 42, opens: 15, installs: 3
    )

    params = { "active" => true, "sdk" => false, "start_date" => "2026-03-01", "end_date" => "2026-03-15", "campaign_id" => nil }

    DownloadFileMailer.stub(:download_file, ->(_d, _u) { OpenStruct.new(deliver_now: true) }) do
      @job.perform(@project.id, params, @user.id)
    end

    csv = CSV.parse(DownloadableFile.last.file.download, headers: true)
    link_row = csv.find { |row| row["Link ID"].to_i == link.id }
    assert_not_nil link_row, "CSV should contain a row for the link"
    assert_equal "42", link_row["View"], "View column should be 42"
    assert_equal "15", link_row["Open"], "Open column should be 15"
    assert_equal "3", link_row["Install"], "Install column should be 3"
  end

  test "CSV has correct headers" do
    params = { "active" => true, "sdk" => false, "start_date" => "2026-03-01", "end_date" => "2026-03-15", "campaign_id" => nil }

    DownloadFileMailer.stub(:download_file, ->(_d, _u) { OpenStruct.new(deliver_now: true) }) do
      @job.perform(@project.id, params, @user.id)
    end

    csv = CSV.parse(DownloadableFile.last.file.download, headers: true)
    %w[Link\ ID Name Title View Open Install Reinstall].each do |header|
      assert_includes csv.headers, header, "CSV should have '#{header}' header"
    end
  end

  test "links with no stats show zero metrics" do
    link = links(:basic_link)
    # No LinkDailyStatistic created for this link in this date range

    params = { "active" => true, "sdk" => false, "start_date" => "2026-03-01", "end_date" => "2026-03-15", "campaign_id" => nil }

    DownloadFileMailer.stub(:download_file, ->(_d, _u) { OpenStruct.new(deliver_now: true) }) do
      @job.perform(@project.id, params, @user.id)
    end

    csv = CSV.parse(DownloadableFile.last.file.download, headers: true)
    link_row = csv.find { |row| row["Link ID"].to_i == link.id }
    assert_not_nil link_row
    assert_equal "0", link_row["View"], "Link with no stats should show 0 views"
  end

  test "sends email to requesting user" do
    params = { "active" => nil, "sdk" => nil, "start_date" => "2026-03-01", "end_date" => "2026-03-15", "campaign_id" => nil }
    emailed_user = nil

    DownloadFileMailer.stub(:download_file, lambda { |_d, user|
      emailed_user = user
      OpenStruct.new(deliver_now: true)
    }) do
      @job.perform(@project.id, params, @user.id)
    end

    assert_equal @user.id, emailed_user.id
  end

  test "returns early when project not found — no file created" do
    assert_no_difference "DownloadableFile.count" do
      @job.perform(999999, { "start_date" => "2026-03-01", "end_date" => "2026-03-15" }, @user.id)
    end
  end

  test "returns early when user not found — no file created" do
    assert_no_difference "DownloadableFile.count" do
      @job.perform(@project.id, { "start_date" => "2026-03-01", "end_date" => "2026-03-15" }, 999999)
    end
  end
end
