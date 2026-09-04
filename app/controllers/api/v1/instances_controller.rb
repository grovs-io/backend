class Api::V1::InstancesController < Api::V1::ProjectsBaseController
  include DashboardAuthorization
  before_action :doorkeeper_authorize!
  before_action :load_instance, only: [
    :members_for_instance, :user_role_for_instance,
    :instance_details, :dismiss_get_started, :setup_progress, :complete_setup_step
  ]
  before_action :load_admin_instance, only: [
    :delete_instance, :edit_instance, :add_member_to_instance, :remove_member_from_instance,
    :set_revenue_collection_enabled
  ]

  def create_instance
    skip_authorization
    if !name_param.is_a?(String) || name_param.blank?
      render json: {error: "name is required and must be a string"}, status: :bad_request
      return
    end

    service = InstanceProvisioningService.new(current_user: current_user)
    instance = service.create(name: name_param, members: members_params)

    payload = {instance: InstanceSerializer.serialize(instance)}
    # Self-hosted only: copyable invite links for members invited during creation.
    if Grovs.self_hosted? && service.invitation_tokens.any?
      payload[:invite_urls] = service.invitation_tokens.transform_values { |token| invite_url_for(token) }
    end

    render json: payload, status: :ok
  end

  def delete_instance
    service = InstanceProvisioningService.new(current_user: current_user)
    # Audit first: destroy enqueues DeleteInstanceJob immediately (not on commit), so it cannot be rolled back.
    ActiveRecord::Base.transaction do
      audit!("instance.deletion_requested", instance_id: @instance.id, target: audit_target(@instance))
      service.destroy(@instance)
    end

    render json: {message: "Instance deleted"}, status: :ok
  end

  def set_revenue_collection_enabled
    @instance.revenue_collection_enabled = revenue_collection_enabled_param
    ActiveRecord::Base.transaction do
      @instance.save!
      audit!("instance.revenue_collection_changed", instance_id: @instance.id,
             target: audit_target(@instance), changes: audit_diff(@instance))
    end

    render json: {instance: InstanceSerializer.serialize(@instance)}, status: :ok
  end

  def current_user_instances
    skip_authorization
    instances = current_user.instances.with_both_projects
                            .includes(:stripe_subscriptions, :enterprise_subscription, production: :domain, test: :domain)
    render json: {instances: InstanceSerializer.serialize(instances)}, status: :ok
  end

  def edit_instance
    @instance.production.name = name_param
    @instance.test.name = name_param + "-test"

    ActiveRecord::Base.transaction do
      @instance.production.save!
      @instance.test.save!
      audit!("instance.renamed", instance_id: @instance.id, target: audit_target(@instance), changes: audit_diff(@instance.production))
    end

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
    role = ActiveRecord::Base.transaction do
      r = service.add_member(email_param, role_param, @instance)
      next nil unless r

      audit!("instance.member_added", instance_id: @instance.id,
             target: { "type" => "instance_role", "id" => r.id, "email" => email_param.downcase },
             changes: { "after" => { "role" => r.role } })
      r
    end
    unless role
      render json: {error: "Wrong data"}, status: :unprocessable_entity
      return
    end

    payload = {role_added: InstanceRoleSerializer.serialize(role)}
    # Self-hosted only: add a copyable invite link. SaaS response is unchanged.
    if Grovs.self_hosted? && service.last_invitation_token.present?
      payload[:invite_url] = invite_url_for(service.last_invitation_token)
    end

    render json: payload, status: :ok
  end

  def remove_member_from_instance
    user = User.find_for_email(email_param)
    if user && user.id == current_user.id
      render json: {error: "Forbidden"}, status: :forbidden
      return
    end

    user_role = InstanceRole.role_for_user_and_instance(user, @instance)
    unless user_role
      render json: {error: "The user is not part of this project"}, status: :forbidden
      return
    end

    target = { "type" => "instance_role", "id" => user_role.id, "email" => user.email }
    before = { "role" => user_role.role }
    ActiveRecord::Base.transaction do
      user_role.destroy!
      audit!("instance.member_removed", instance_id: @instance.id, target: target, changes: { "before" => before })
    end

    render json: {message: "User deleted"}, status: :ok
  end

  def user_role_for_instance
    role = InstanceRole.role_for_user_and_instance(current_user, @instance)

    render json: {role: InstanceRoleSerializer.serialize(role)}
  end

  def instance_details
    prod_fallback = @instance.production&.redirect_config&.default_fallback != nil
    links = @instance.production&.domain&.links&.exists? || @instance.test&.domain&.links&.exists? || false
    campaigns = @instance.production&.campaigns&.exists? || @instance.test&.campaigns&.exists? || false

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

  def invite_url_for(token)
    "#{ENV['REACT_HOST_PROTOCOL']}#{ENV['REACT_HOST']}/accept-invite?token=#{token}"
  end

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
