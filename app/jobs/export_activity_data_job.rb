class ExportActivityDataJob
  include Sidekiq::Job
  sidekiq_options queue: :default

  def perform(instance_id, safe_params, current_user_id)
    instance = Instance.find_by(id: instance_id)
    return unless instance

    current_user = User.find_by(id: current_user_id)
    return unless current_user

    # Extract params
    start_date_param = safe_params["start_date"]
    end_date_param = safe_params["end_date"]

    csv_string = ActiveUsersReport.new(
        project_ids: [instance.production.id, instance.test.id],
        start_date: start_date_param,
        end_date:   end_date_param
      ).call

    # Create downloadable file
    filename = "activity_data_#{Time.now.strftime('%Y-%m-%d_%H-%M-%S')}"
    download = DownloadableFile.create_csv_file_with_expiration(
      content: csv_string,
      filename: filename
    )

    # Generate download file email
    DownloadFileMailer.download_file(download, current_user).deliver_now
  end
end