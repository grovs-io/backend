class InstanceProvisioningService
  # Raw token of the most recent invitation issued (nil when none was);
  # used to build the self-hosted invite link.
  attr_reader :last_invitation_token

  # email => raw token for every user freshly invited by this service instance.
  attr_reader :invitation_tokens

  def initialize(current_user:)
    @current_user = current_user
    @invitation_tokens = {}
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

    # Deferred: a caller's wrapping transaction may still roll back, and the enqueue must not survive it.
    ActiveRecord.after_all_transactions_commit do
      DeleteInstanceJob.perform_async(instance.id)
    end
  end

  # 5-branch member invitation: self-check, already invited, new user invite, create role
  # Returns InstanceRole or nil
  def add_member(email, role, instance)
    user = User.find_for_email(email)
    if user && user.id == @current_user.id
      return
    end

    skip_invite_emails = Grovs.self_hosted? && !Grovs.smtp_enabled?

    existing_role = InstanceRole.role_for_user_and_instance(user, instance)
    if existing_role
      # Re-adding a pending invitee is the "resend invite" gesture — the project mail would strand them.
      if pending_invitee?(user)
        reinvite(user, skip_invite_emails)
      elsif !skip_invite_emails
        NewMemberMailer.new_member(instance, user).deliver_later
      end
      return nil
    end

    freshly_invited = false
    if user.nil?
      # Always skip Devise's synchronous send; deliver separately so an SMTP failure can't 500.
      user = User.invite!({ email: email, skip_invitation: true }, @current_user)
      issue_invitation(user, skip_invite_emails)
      freshly_invited = true
    elsif pending_invitee?(user)
      reinvite(user, skip_invite_emails)
      freshly_invited = true
    end

    # Invitees get only the invitation instructions; the project mail is for established accounts.
    if user && !existing_role && !skip_invite_emails && !freshly_invited
      NewMemberMailer.new_member(instance, user).deliver_later
    end

    InstanceRole.create!(role: role, instance_id: instance.id, user_id: user.id)
  end

  private

  def pending_invitee?(user)
    user.created_by_invite? && !user.invitation_accepted?
  end

  # Fresh token (the old link dies) + non-fatal delivery for a still-passwordless user.
  def reinvite(user, skip_delivery)
    user.skip_invitation = true
    user.invite!
    issue_invitation(user, skip_delivery)
  end

  def issue_invitation(user, skip_delivery)
    @last_invitation_token = user.raw_invitation_token # present once, in-memory
    @invitation_tokens[user.email] = user.raw_invitation_token
    deliver_invitation_safely(user) unless skip_delivery
  end

  def deliver_invitation_safely(user)
    user.deliver_invitation
  rescue StandardError => e
    Rails.logger.error("[InstanceProvisioningService] invite email to user #{user.id} failed: #{e.class}: #{e.message}")
  end

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
