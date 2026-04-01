require "test_helper"

class ExportActivityDataJobTest < ActiveSupport::TestCase
  fixtures :instances, :projects, :users, :instance_roles, :devices, :visitors

  setup do
    @job = ExportActivityDataJob.new
    @instance = instances(:one)
    @user = users(:admin_user)

    # Ensure instance has both production and test projects
    unless @instance.test
      Project.create!(name: "Export Test (test)", identifier: "export-test-#{SecureRandom.hex(4)}", instance: @instance, test: true)
    end
    @instance.reload
  end

  # --- Real ActiveUsersReport integration ---

  test "creates CSV with real daily active user counts from VisitorDailyStatistic" do
    prod = @instance.production
    # Create 3 distinct visitors on March 10, 2 on March 11
    visitors_mar10 = create_visitors_with_stats(prod, 3, Date.parse("2026-03-10"))
    visitors_mar11 = create_visitors_with_stats(prod, 2, Date.parse("2026-03-11"))

    params = { "start_date" => "2026-03-10", "end_date" => "2026-03-11" }

    DownloadFileMailer.stub(:download_file, ->(_d, _u) { OpenStruct.new(deliver_now: true) }) do
      assert_difference "DownloadableFile.count", 1 do
        @job.perform(@instance.id, params, @user.id)
      end
    end

    file = DownloadableFile.last
    csv_content = file.file.download

    # Verify real counts appear in CSV
    assert_includes csv_content, "2026-03-10", "CSV should have March 10 date"
    assert_includes csv_content, "2026-03-11", "CSV should have March 11 date"
    # Parse CSV to verify actual counts
    lines = csv_content.split("\n")
    daily_lines = lines.select { |l| l.start_with?("2026-03-1") }
    mar10_line = daily_lines.find { |l| l.include?("2026-03-10") }
    mar11_line = daily_lines.find { |l| l.include?("2026-03-11") }
    assert_match(/,3\s*$/, mar10_line, "March 10 should show 3 active users")
    assert_match(/,2\s*$/, mar11_line, "March 11 should show 2 active users")
  end

  test "CSV includes monthly summary and total" do
    prod = @instance.production
    create_visitors_with_stats(prod, 5, Date.parse("2026-03-05"))

    params = { "start_date" => "2026-03-01", "end_date" => "2026-03-31" }

    DownloadFileMailer.stub(:download_file, ->(_d, _u) { OpenStruct.new(deliver_now: true) }) do
      @job.perform(@instance.id, params, @user.id)
    end

    csv_content = DownloadableFile.last.file.download
    assert_includes csv_content, "Sum of Monthly Unique Active Users", "CSV should have total header"
    assert_includes csv_content, "2026-03", "CSV should have monthly row"
    assert_includes csv_content, "Daily Unique Active Users", "CSV should have daily header"
  end

  test "creates DownloadableFile with correct name and content type" do
    create_visitors_with_stats(@instance.production, 1, Date.parse("2026-03-10"))
    params = { "start_date" => "2026-03-10", "end_date" => "2026-03-10" }

    DownloadFileMailer.stub(:download_file, ->(_d, _u) { OpenStruct.new(deliver_now: true) }) do
      @job.perform(@instance.id, params, @user.id)
    end

    file = DownloadableFile.last
    assert file.name.start_with?("activity_data_"), "File name should start with activity_data_"
    assert file.file.attached?, "File should have CSV attachment"
    assert_equal "text/csv", file.file.content_type
  end

  test "sends email to the requesting user" do
    create_visitors_with_stats(@instance.production, 1, Date.parse("2026-03-10"))
    params = { "start_date" => "2026-03-10", "end_date" => "2026-03-10" }
    emailed_user = nil

    DownloadFileMailer.stub(:download_file, lambda { |_download, user|
      emailed_user = user
      OpenStruct.new(deliver_now: true)
    }) do
      @job.perform(@instance.id, params, @user.id)
    end

    assert_equal @user.id, emailed_user.id, "Should email the requesting user"
  end

  # --- Guard clauses ---

  test "returns early when instance not found — no file created" do
    assert_no_difference "DownloadableFile.count" do
      @job.perform(999999, { "start_date" => "2026-03-01", "end_date" => "2026-03-15" }, @user.id)
    end
  end

  test "returns early when user not found — no file created" do
    assert_no_difference "DownloadableFile.count" do
      @job.perform(@instance.id, { "start_date" => "2026-03-01", "end_date" => "2026-03-15" }, 999999)
    end
  end

  private

  def create_visitors_with_stats(project, count, date)
    count.times do
      dev = Device.create!(
        user_agent: "ExportBot/#{SecureRandom.hex(3)}",
        ip: "172.#{rand(16..31)}.#{rand(256)}.#{rand(256)}",
        remote_ip: "172.#{rand(16..31)}.#{rand(256)}.#{rand(256)}",
        platform: "ios"
      )
      vis = Visitor.create!(device: dev, project: project)
      VisitorDailyStatistic.create!(
        visitor_id: vis.id,
        project_id: project.id,
        event_date: date,
        platform: "ios",
        views: 1
      )
    end
  end
end
