class InstanceProvisioningService
  def initialize(current_user:)
    @current_user = current_user
  end

  # Creates Instance + 2 Projects + 2 Domains + 2 RedirectConfigs + InstanceRole + DesktopConfig
  # Returns the created Instance
  def create(name:, members: [])
    raise ArgumentError, "name must be a non-blank string" if name.blank?

    api_key = generate_api_key(name)
    uri_scheme = generate_uri_scheme(name)
    subdomain = generate_subdomain(name)

    instance = Instance.new

    test_proj_name = name + "-test"

    prod_proj = Project.new(name: name, test: false)
    prod_proj.identifier = api_key

    test_proj = Project.new(name: test_proj_name, test: true)
    test_proj.identifier = "test_" + api_key

    ActiveRecord::Base.transaction do
      instance.uri_scheme = uri_scheme
      instance.api_key = api_key
      instance.save!

      prod_proj.instance = instance
      test_proj.instance = instance

      prod_proj.save!
      test_proj.save!

      prod_domain_without_port = Grovs::Domains::LIVE.split(':').first
      test_domain_without_port = Grovs::Domains::TEST.split(':').first
      Domain.create!(project_id: prod_proj.id, domain: prod_domain_without_port, subdomain: subdomain)
      Domain.create!(project_id: test_proj.id, domain: test_domain_without_port, subdomain: subdomain)

      RedirectConfig.create!(project: prod_proj)
      RedirectConfig.create!(project: test_proj)

      InstanceRole.create!(role: Grovs::Roles::ADMIN, instance_id: instance.id, user_id: @current_user.id)

      if members
        members.each do |member_dict|
          add_member(member_dict[:email], member_dict[:role], instance)
        end
      end

      instance.create_desktop_configuration
    end

    instance
  end

  # Stripe cancel + InstanceRole cleanup + async DeleteInstanceJob
  def destroy(instance)
    ActiveRecord::Base.transaction do
      subscription = instance.subscription
      if subscription
        StripeService.cancel_subscription(subscription)
      end

      InstanceRole.where(instance_id: instance.id).delete_all
    end

    DeleteInstanceJob.perform_async(instance.id)
  end

  # 5-branch member invitation: self-check, already invited, new user invite, create role
  # Returns InstanceRole or nil
  def add_member(email, role, instance)
    user = User.find_by(email: email)
    if user && user.id == @current_user.id
      return
    end

    existing_role = InstanceRole.role_for_user_and_instance(user, instance)
    if existing_role
      NewMemberMailer.new_member(instance, user).deliver_later
      return nil
    end

    user ||= User.invite!({ email: email }, @current_user)

    if user && !existing_role
      NewMemberMailer.new_member(instance, user).deliver_later
    end

    InstanceRole.create!(role: role, instance_id: instance.id, user_id: user.id)
  end

  private

  def generate_api_key(name)
    cleaned_name = name.gsub(/[^0-9a-z]/i, '').downcase.slice(0, 6)

    loop do
      token = "#{cleaned_name}_#{SecureRandom.hex(32)}"
      break token unless Instance.exists?(api_key: token)
    end
  end

  def generate_uri_scheme(name)
    cleaned_name = name.gsub(/[^0-9a-z]/i, '').downcase.slice(0, 6)

    loop do
      token = "#{cleaned_name}#{SecureRandom.hex(6)}"
      break token unless Instance.exists?(uri_scheme: token)
    end
  end

  def generate_subdomain(name)
    cleaned_name = name.gsub(/[^0-9a-z]/i, '').downcase.slice(0, 6)

    loop do
      token = cleaned_name.first(4) + SecureRandom.hex(2)
      break token unless Domain.exists?(subdomain: token)
    end
  end
end
