require "test_helper"

class BackfillLast3DaysJobTest < ActiveSupport::TestCase
  fixtures :instances, :projects, :devices, :visitors

  setup do
    @job = BackfillLast3DaysJob.new
    @project = projects(:one)
    @visitor = visitors(:ios_visitor)
  end

  test "generates DailyProjectMetric with correct aggregated values from visitor stats" do
    VisitorDailyStatistic.create!(
      visitor: @visitor, project_id: @project.id,
      event_date: Date.today, platform: "ios",
      views: 10, opens: 5, installs: 2
    )

    @job.perform

    metric = DailyProjectMetric.find_by(project_id: @project.id, event_date: Date.today)
    assert_not_nil metric, "Should generate DailyProjectMetric"
    assert_equal 10, metric.views, "Should aggregate views from VDS"
    assert_equal 5, metric.opens, "Should aggregate opens from VDS"
    assert_equal 2, metric.installs, "Should aggregate installs from VDS"
  end

  test "generates metrics for multiple days in the 3-day window" do
    [Date.today - 2, Date.today - 1, Date.today].each_with_index do |date, i|
      VisitorDailyStatistic.create!(
        visitor: @visitor, project_id: @project.id,
        event_date: date, platform: "ios",
        views: (i + 1) * 5
      )
    end

    @job.perform

    (Date.today - 2..Date.today).each do |date|
      metric = DailyProjectMetric.find_by(project_id: @project.id, event_date: date)
      assert_not_nil metric, "Should generate metric for #{date}"
    end
  end
end
