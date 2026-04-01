class Api::V1::Sdk::EventsController < Api::V1::Sdk::BaseController
  def add_event
    link_to_log = nil
    begin
      if link_param.present?
        link = LinksService.link_for_url(link_param, @project)
        link_to_log = link if link
      end

      if optional_path_param.present?
        link = LinksService.link_for_project_and_path(@project, optional_path_param)
        link_to_log = link if link
      end
    rescue StandardError => e
      Rails.logger.warn("Sdk::EventsController#add_event link resolution failed, logging without link: #{e.message}")
    end

    parsed_created_at = nil
    if link_details_params[:created_at].present?
      parsed_created_at = begin
        Time.parse(link_details_params[:created_at])
      rescue ArgumentError
        nil
      end
    end

    EventIngestionService.log_async(
        link_details_params[:event],
        @project,
        @device,
        nil,
        link_to_log,
        link_details_params[:engagement_time],
        created_at: parsed_created_at
    )

    render json: {message: "Event added"}, status: :ok
  end

  private

  def link_param
    params.permit(:link)[:link]
  end

  def optional_path_param
    params.permit(:path)[:path]
  end

  def link_details_params
    params.permit(:event, :created_at, :engagement_time)
  end
end
