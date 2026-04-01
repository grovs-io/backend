class Api::V1::ProjectsBaseController < ApplicationController

  def authorize_and_load_project
    @project = current_project
  end

  def current_project
    project = Project.redis_find_by(:id, id_param)
    if project.nil?
      raise ActiveRecord::RecordNotFound, "Project does not exist"
    end

    unless InstanceRole.exists?(instance_id: project.instance_id, user_id: current_user.id)
      render json: {error: "Forbidden"}, status: :forbidden
      return
    end

    @_authorization_performed = true
    project
  end

  def current_instance(require_admin: false)
    instance = Instance.redis_find_by(:id, id_param)
    if instance.nil?
      raise ActiveRecord::RecordNotFound, "Instance does not exist"
    end

    role = InstanceRole.find_by(instance_id: instance.id, user_id: current_user.id)
    unless role
      render json: {error: "Forbidden"}, status: :forbidden
      return
    end

    if require_admin && role.role != Grovs::Roles::ADMIN
      render json: {error: "Forbidden"}, status: :forbidden
      return
    end

    @_authorization_performed = true
    instance
  end

  def find_authorized_resource(klass, id, &owner_check)
    record = klass.find_by(id: id)
    unless record
      render json: { error: "#{klass.model_name.human} not found" }, status: :not_found
      return
    end

    check = block_given? ? owner_check : ->(r) { r.project_id == @project.id }
    unless check.call(record)
      render json: { error: "Forbidden" }, status: :forbidden
      return
    end

    record
  end

  def domain_for_current_project
    @project&.domain_for_project
  end

  def links_for_search_params
    domain = domain_for_current_project
    return unless domain

    LinkQueryService.new(domain: domain).search(
      active: active_param, sdk: sdk_param,
      page: page_param, per_page: per_page_param,
      sort_by: sort_by_param, asc: asc_param,
      start_date: start_date_param, end_date: end_date_param,
      term: term_param, ads_platform: ads_platform_param,
      campaign_id: campaign_id_param
    )
  end

  def links_for_search_params_no_pagination_and_order
    domain = domain_for_current_project
    return unless domain

    LinkQueryService.new(domain: domain).filter(
      active: active_param, sdk: sdk_param,
      start_date: start_date_param, end_date: end_date_param,
      term: term_param, ads_platform: ads_platform_param,
      campaign_id: campaign_id_param
    )
  end

  def load_instance
    @instance = current_instance
    return if performed?
    head :forbidden unless @instance
  end

  def load_admin_instance
    @instance = current_instance(require_admin: true)
    return if performed?
    head :forbidden unless @instance
  end

  private

  def id_param
    params.require(:id)
  end

  def start_date_param
    params.permit(:start_date)[:start_date]
  end

  def end_date_param
    params.permit(:end_date)[:end_date]
  end

  def active_param
    params.require(:active)
  end

  def sdk_param
    params.require(:sdk)
  end

  def asc_param
    params.permit(:ascendent)[:ascendent]
  end

  def page_param
    params.permit(:page)[:page]
  end

  def term_param
    params.permit(:term)[:term]
  end

  def sort_by_param
    params.permit(:sort_by)[:sort_by]
  end

  def ads_platform_param
    params.permit(:ads_platform)[:ads_platform]
  end

  def campaign_id_param
    params.permit(:campaign_id)[:campaign_id]
  end

  def per_page_param
    params.permit(:per_page)[:per_page]
  end

  def platform_param
    params.permit(:platform)[:platform]
  end

  # Accepts both `platforms` (array) and `platform` (string) for backwards compatibility.
  # Returns an array, a single string, or nil.
  def platforms_param
    arr = params.permit(platforms: [])[:platforms]
    return arr if arr.present?
    platform_param
  end
end