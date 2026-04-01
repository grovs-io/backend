class DailyProjectMetric < ApplicationRecord
  def self.increment!(project_id, platform, event_date, revenue: 0, units_sold: 0, cancellations: 0)
    ActiveRecord::Base.with_connection do |conn|
      sql = <<~SQL
        INSERT INTO daily_project_metrics
          (project_id, event_date, platform, revenue, units_sold, cancellations, created_at, updated_at)
        VALUES
          (#{conn.quote(project_id)}, #{conn.quote(event_date)}, #{conn.quote(platform)},
           #{revenue.to_i}, #{units_sold.to_i}, #{cancellations.to_i}, NOW(), NOW())
        ON CONFLICT (project_id, event_date, platform)
        DO UPDATE SET
          revenue = COALESCE(daily_project_metrics.revenue, 0) + #{revenue.to_i},
          units_sold = COALESCE(daily_project_metrics.units_sold, 0) + #{units_sold.to_i},
          cancellations = COALESCE(daily_project_metrics.cancellations, 0) + #{cancellations.to_i},
          updated_at = NOW()
      SQL

      conn.execute(sql)
    end
  end
end
