# app/helpers/link_metrics_helper.rb

require 'csv'

module LinkMetricsHelper

  def fetch_links_for_search_params(project_id, user_id, active, sdk, campaign_id_param)
    project = Project.redis_find_by(:id, project_id)
    if project.nil?
      return nil
    end

    unless InstanceRole.exists?(instance_id: project.instance_id, user_id: user_id)
      return nil
    end

    domain = project.domain
    unless domain
      return nil
    end

    links = domain.links.includes(:campaign)
    links = links.where(active: active)
    links = links.where(sdk_generated: sdk)

    if campaign_id_param
      # links = links.where(campaign_id: campaign_id_param)
    end

    order_by = "created_at"
    order = "desc"

    links.order("#{order_by} #{order}")

    
  end

  def export_links_metrics_to_csv(links:, project_id:, start_date:, end_date:)
    if links&.empty?
      return ""
    end
    
    # Step 1: Fetch link metrics from daily stats in the time window
    metrics = LinkDailyStatistic
                .where(project_id: project_id, link_id: links.map(&:id), event_date: start_date..end_date)
                .group(:link_id)
                .pluck(
                  :link_id,
                  Arel.sql("SUM(views)"),
                  Arel.sql("SUM(opens)"),
                  Arel.sql("SUM(installs)"),
                  Arel.sql("SUM(reinstalls)"),
                  Arel.sql("SUM(reactivations)"),
                  Arel.sql("SUM(time_spent)")
                )
                .to_h do |link_id, views, opens, installs, reinstalls, reactivations, time_spent|
                  [
                    link_id,
                    {
                      "view" => views.to_i,
                      "open" => opens.to_i,
                      "install" => installs.to_i,
                      "reinstall" => reinstalls.to_i,
                      "reactivation" => reactivations.to_i,
                      "time_spent" => time_spent.to_i,
                      "avg_engagement_time" => 0.0 # Could compute per-device if needed
                    }
                  ]
                end

    # Step 2: Prepare the CSV
    CSV.generate(headers: true) do |csv|
      csv << [
        'Link ID', 'Name', 'Title', 'Subtitle', 'Updated At', 'Generated From Platform',
        'SDK Generated', 'Tags', 'Active', 'Access Path',
        'View', 'Open', 'Install', 'Reinstall', 'Reactivation',
        'Avg Engagement Time', 'Time Spent', 'Data', 'Campaign'
      ]

      links.each do |link|
        metric = metrics[link.id] || default_metrics
        campaign_name = link.campaign&.name

        tags = link.tags || []
        data_string = (link.data || {}).map { |k, v| "#{k}=#{v}" }.join(", ")

        csv << [
          link.id,
          link.name,
          link.title,
          link.subtitle,
          link.updated_at,
          link.generated_from_platform,
          link.sdk_generated,
          tags.join(", "),
          link.active,
          link.access_path,
          metric["view"],
          metric["open"],
          metric["install"],
          metric["reinstall"],
          metric["reactivation"],
          metric["avg_engagement_time"],
          metric["time_spent"],
          data_string,
          campaign_name
        ]
      end
    end
  end

  private

  def default_metrics
    {
      "view" => 0,
      "open" => 0,
      "install" => 0,
      "reinstall" => 0,
      "reactivation" => 0,
      "avg_engagement_time" => 0.0,
      "time_spent" => 0
    }
  end
end
