class ExportLinkDataJob
  include Sidekiq::Job
  sidekiq_options queue: :default

  include LinkMetricsHelper

  def perform(project_id, safe_params, current_user_id)
    project = Project.find_by(id: project_id)
    return unless project

    current_user = User.find_by(id: current_user_id)
    return unless current_user

    # Extract params
    active = safe_params["active"]
    sdk = safe_params["sdk"]
    start_date_param = safe_params["start_date"]
    end_date_param = safe_params["end_date"]
    campaign_id_param = safe_params["campaign_id"]

    links = fetch_links_for_search_params(
      project.id,
      current_user.id,
      active,
      sdk,
      campaign_id_param
    )

    csv_string = export_links_metrics_to_csv(
      links: links,
      project_id: project.id,
      start_date: start_date_param,
      end_date: end_date_param
    )

    # Create downloadable file
    filename = "links_data_#{Time.now.strftime('%Y-%m-%d_%H-%M-%S')}"
    download = DownloadableFile.create_csv_file_with_expiration(
      content: csv_string,
      filename: filename
    )

    # Generate download file email
    DownloadFileMailer.download_file(download, current_user).deliver_now
  end
end