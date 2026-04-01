class Api::V1::NotificationsController < Api::V1::ProjectsBaseController
  include DashboardAuthorization
  before_action :doorkeeper_authorize!
  before_action :authorize_and_load_project, except: [:test]

  def test
    skip_authorization
    render json: { notifications: "asdasda" }, status: :ok
  end

  def create
    notification = notification_service.create(
      notification_attrs: notitication_params,
      target_attrs: target_params
    )

    render json: { notification: NotificationSerializer.serialize(notification) }, status: :ok
  end

  def notifications
    result = notification_service.list(
      archived: archived_param,
      for_new_users: for_new_users_param,
      search_term: term_param,
      page: page_param,
      per_page: per_page_param
    )

    render json: PaginatedResponse.new(result, data: NotificationSerializer.serialize(result))
  end

  def archive_notification
    notification = find_authorized_resource(Notification, id_param)
    return unless notification

    archived = notification_service.archive(notification: notification)
    render json: { notifications: NotificationSerializer.serialize(archived) }
  rescue ArgumentError => e
    render json: { error: e.message }, status: :unprocessable_entity
  end

  private

  def notification_service
    @notification_service ||= NotificationService.new(project: @project)
  end

  # Notifications routes use :project_id instead of :id for the project.
  # Delegate to parent's current_project logic via id_param override.
  def current_project
    project = Project.redis_find_by(:id, project_id_param)
    if project.nil?
      render json: { error: "Project does not exist" }, status: :not_found
      return
    end

    unless InstanceRole.exists?(instance_id: project.instance_id, user_id: current_user.id)
      render json: { error: "Forbidden" }, status: :forbidden
      return
    end

    @_authorization_performed = true
    project
  end

  # Params

  def for_new_users_param
    value = params.permit(:for_new_users)[:for_new_users]
    value.nil? ? nil : ActiveModel::Type::Boolean.new.cast(value)
  end

  def archived_param
    params.require(:archived)
  end

  def page_param
    params.require(:page)
  end

  def project_id_param
    params.require(:project_id)
  end

  def notitication_params
    params.permit(:title, :html, :subtitle, :auto_display, :send_push)
  end

  def target_params
    params.permit(:new_users, :existing_users, platforms: [])
  end

end
