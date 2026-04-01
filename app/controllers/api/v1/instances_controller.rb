class Api::V1::InstancesController < Api::V1::ProjectsBaseController
  include DashboardAuthorization
  before_action :doorkeeper_authorize!
  before_action :load_instance, only: [
    :set_revenue_collection_enabled, :members_for_instance, :user_role_for_instance,
    :instance_details, :dismiss_get_started, :setup_progress, :complete_setup_step
  ]
  before_action :load_admin_instance, only: [
    :delete_instance, :edit_instance, :add_member_to_instance, :remove_member_from_instance
  ]

  def create_instance
    skip_authorization
    if !name_param.is_a?(String) || name_param.blank?
      render json: {error: "name is required and must be a string"}, status: :bad_request
      return
    end

    service = InstanceProvisioningService.new(current_user: current_user)
    instance = service.create(name: name_param, members: members_params)

    render json: {instance: InstanceSerializer.serialize(instance)}, status: :ok
  end

  def delete_instance
    service = InstanceProvisioningService.new(current_user: current_user)
    service.destroy(@instance)

    render json: {message: "Instance deleted"}, status: :ok
  end

  def set_revenue_collection_enabled
    @instance.revenue_collection_enabled = revenue_collection_enabled_param
    @instance.save!

    render json: {instance: InstanceSerializer.serialize(@instance)}, status: :ok
  end

  def current_user_instances
    skip_authorization
    render json: {instances: InstanceSerializer.serialize(current_user.instances.includes(production: :domain, test: :domain))}, status: :ok
  end

  def edit_instance
    @instance.production.name = name_param
    @instance.test.name = name_param + "-test"

    @instance.production.save!
    @instance.test.save!

    render json: {project: InstanceSerializer.serialize(@instance)}, status: :ok
  end

  def members_for_instance
    render json: {members: InstanceRoleSerializer.serialize(@instance.instance_roles.includes(:user))}, status: :ok
  end


  def add_member_to_instance
    unless email_param.present? && email_param.match?(URI::MailTo::EMAIL_REGEXP)
      render json: {error: "Invalid email format"}, status: :unprocessable_entity
      return
    end

    service = InstanceProvisioningService.new(current_user: current_user)
    role = service.add_member(email_param, role_param, @instance)
    unless role
      render json: {error: "Wrong data"}, status: :unprocessable_entity
      return
    end

    render json: {role_added: InstanceRoleSerializer.serialize(role)}, status: :ok
  end

  def remove_member_from_instance
    user = User.find_by(email: email_param)
    if user && user.id == current_user.id
      render json: {error: "Forbidden"}, status: :forbidden
      return
    end

    user_role = InstanceRole.role_for_user_and_instance(user, @instance)
    unless user_role
      render json: {error: "The user is not part of this project"}, status: :forbidden
      return
    end

    user_role.destroy!

    render json: {message: "User deleted"}, status: :ok
  end

  def user_role_for_instance
    role = InstanceRole.role_for_user_and_instance(current_user, @instance)

    render json: {role: InstanceRoleSerializer.serialize(role)}
  end

  def instance_details
    prod_fallback = @instance.production&.redirect_config&.default_fallback != nil
    links = @instance.production&.domain&.links&.exists? || @instance.test&.domain&.links&.exists?
    campaigns = @instance.production&.campaigns&.exists? || @instance.test&.campaigns&.exists?

    get_started_setup = {}
    get_started_setup[:ios_sdk] = @instance.ios_application&.configuration != nil
    get_started_setup[:android_sdk] = @instance.android_application&.configuration != nil
    get_started_setup[:web_sdk] = @instance.web_application&.configuration != nil
    get_started_setup[:redirect_fallback] = prod_fallback
    get_started_setup[:has_created_links] = links
    get_started_setup[:has_created_campaigns] = campaigns

    render json: {instance: InstanceSerializer.serialize(@instance), get_started_setup: get_started_setup}, status: :ok
  end

  def dismiss_get_started
    @instance.get_started_dismissed = true
    @instance.save

    render json: {instance: InstanceSerializer.serialize(@instance)}, status: :ok
  end

  def setup_progress
    steps = @instance.setup_progress_steps
    if setup_category_param.present?
      steps = steps.where(category: setup_category_param)
    end

    render json: {steps: SetupProgressStepSerializer.serialize(steps)}, status: :ok
  end

  def complete_setup_step
    step = @instance.setup_progress_steps.find_or_initialize_by(
        category: setup_category_param_required,
        step_identifier: setup_step_identifier_param
    )
    step.completed_at ||= Time.current

    if step.save
      render json: {step: SetupProgressStepSerializer.serialize(step)}, status: :ok
    else
      render json: {errors: step.errors.full_messages}, status: :unprocessable_entity
    end
  end

  private

  # Params

  def name_param
    params.permit(:name)[:name]
  end

  def update_project_params
    params.permit(:name)
  end

  def email_param
    params.require(:email)
  end

  def role_param
    params.require(:role)
  end

  def members_params
    params.permit(members: [:email, :role])[:members]
  end

  def revenue_collection_enabled_param
    params.require(:revenue_collection_enabled)
  end

  def setup_category_param
    params.permit(:category)[:category]
  end

  def setup_category_param_required
    params.require(:category)
  end

  def setup_step_identifier_param
    params.require(:step_identifier)
  end
end
