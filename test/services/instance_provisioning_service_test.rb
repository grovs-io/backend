require "test_helper"

class InstanceProvisioningServiceTest < ActiveSupport::TestCase
  fixtures :instances, :projects

  setup do
    @user = User.create!(email: "admin@test.com", password: "password123")
  end

  def build_service(user = @user)
    InstanceProvisioningService.new(current_user: user)
  end

  # Bypass Redis cache for Application lookups during instance creation.
  # Parallel test processes share Redis but use separate databases,
  # causing stale cache entries from other processes to interfere.
  def create_without_cache(service, name:, members: [])
    Application.stub(:redis_find_by_multiple_conditions, lambda { |*args, **_kwargs|
      conditions = args.first
      conditions = conditions.is_a?(Hash) ? conditions : { conditions[0] => conditions[1] }
      Application.find_by(conditions)
    }) do
      service.create(name: name, members: members)
    end
  end

  # === create ===

  test "create provisions instance with all nested records" do
    service = build_service

    assert_difference "Instance.count", 1 do
      assert_difference "Project.count", 2 do
        assert_difference "Domain.count", 2 do
          assert_difference "RedirectConfig.count", 2 do
            assert_difference "InstanceRole.count", 1 do
              instance = create_without_cache(service, name: "TestApp")

              assert instance.persisted?
              assert instance.api_key.present?
              assert instance.uri_scheme.present?

              assert_equal "TestApp", instance.production.name
              assert_equal "TestApp-test", instance.test.name

              assert instance.production.identifier.start_with?("testap_")
              assert instance.test.identifier.start_with?("test_testap_")

              assert instance.production.domain.present?
              assert instance.test.domain.present?

              admin_role = InstanceRole.find_by(instance_id: instance.id, user_id: @user.id)
              assert admin_role
              assert_equal Grovs::Roles::ADMIN, admin_role.role
            end
          end
        end
      end
    end
  end

  test "create generates unique api_key and uri_scheme" do
    service = build_service

    instance1 = create_without_cache(service, name: "App1")
    instance2 = create_without_cache(service, name: "App2")

    assert_not_equal instance1.api_key, instance2.api_key
    assert_not_equal instance1.uri_scheme, instance2.uri_scheme
    assert_not_equal instance1.production.domain.subdomain, instance2.production.domain.subdomain
  end

  test "create with members invites them during creation" do
    other_user = User.create!(email: "member@test.com", password: "password123")
    members = [{ email: other_user.email, role: Grovs::Roles::MEMBER }]

    NewMemberMailer.stub(:new_member, OpenStruct.new(deliver_later: true)) do
      instance = create_without_cache(build_service, name: "WithMembers", members: members)

      member_role = InstanceRole.find_by(instance_id: instance.id, user_id: other_user.id)
      assert member_role, "Member should have been invited during creation"
      assert_equal Grovs::Roles::MEMBER, member_role.role
    end
  end

  test "create with nil members skips invitation loop" do
    assert_nothing_raised do
      instance = create_without_cache(build_service, name: "NilMembers", members: nil)
      assert instance.persisted?
    end
  end

  test "create sets up desktop configuration" do
    instance = create_without_cache(build_service, name: "DesktopCheck")

    desktop_app = Application.find_by(instance_id: instance.id, platform: Grovs::Platforms::DESKTOP)
    assert desktop_app, "Desktop application should exist"
  end

  # === destroy ===

  test "destroy cancels stripe and enqueues DeleteInstanceJob" do
    instance = instances(:one)
    InstanceRole.create!(role: Grovs::Roles::ADMIN, instance_id: instance.id, user_id: @user.id)

    deleted_instance_id = nil
    StripeService.stub(:cancel_subscription, true) do
      DeleteInstanceJob.stub(:perform_async, ->(id) { deleted_instance_id = id }) do
        build_service.destroy(instance)
      end
    end

    assert_equal instance.id, deleted_instance_id
    assert_equal 0, InstanceRole.where(instance_id: instance.id).count
  end

  test "destroy cancels stripe subscription if present" do
    instance = instances(:one)
    mock_subscription = OpenStruct.new(subscription_id: "sub_123")
    cancel_called = false

    instance.stub(:subscription, mock_subscription) do
      StripeService.stub(:cancel_subscription, ->(*_args) { cancel_called = true }) do
        DeleteInstanceJob.stub(:perform_async, true) do
          build_service.destroy(instance)
        end
      end
    end

    assert cancel_called, "cancel_subscription should have been called"
  end

  test "destroy without subscription skips cancellation" do
    instance = instances(:one)
    InstanceRole.create!(role: Grovs::Roles::ADMIN, instance_id: instance.id, user_id: @user.id)
    cancel_called = false

    StripeService.stub(:cancel_subscription, ->(*_args) { cancel_called = true }) do
      DeleteInstanceJob.stub(:perform_async, true) do
        instance.stub(:subscription, nil) do
          build_service.destroy(instance)
        end
      end
    end

    assert_not cancel_called, "cancel_subscription should NOT have been called"
  end

  # === add_member ===

  test "add_member returns nil when adding self" do
    instance = instances(:one)

    result = build_service.add_member(@user.email, Grovs::Roles::MEMBER, instance)
    assert_nil result
  end

  test "add_member creates role for existing user" do
    instance = instances(:one)
    other_user = User.create!(email: "other@test.com", password: "password123")

    NewMemberMailer.stub(:new_member, OpenStruct.new(deliver_later: true)) do
      assert_difference "InstanceRole.count", 1 do
        role = build_service.add_member(other_user.email, Grovs::Roles::MEMBER, instance)
        assert role
        assert_equal Grovs::Roles::MEMBER, role.role
        assert_equal other_user.id, role.user_id
      end
    end
  end

  test "add_member returns nil for already invited user and sends email" do
    instance = instances(:one)
    other_user = User.create!(email: "existing@test.com", password: "password123")
    InstanceRole.create!(role: Grovs::Roles::MEMBER, instance_id: instance.id, user_id: other_user.id)

    mock_mail = OpenStruct.new(deliver_later: true)
    NewMemberMailer.stub(:new_member, mock_mail) do
      assert_no_difference "InstanceRole.count" do
        result = build_service.add_member(other_user.email, Grovs::Roles::MEMBER, instance)
        assert_nil result, "Should return nil for already-invited user so controller renders error"
      end
    end
  end

  test "add_member invites non-existent user via Devise and creates role" do
    instance = instances(:one)
    new_email = "newuser_#{SecureRandom.hex(4)}@test.com"

    NewMemberMailer.stub(:new_member, OpenStruct.new(deliver_later: true)) do
      assert_difference "User.count", 1 do
        assert_difference "InstanceRole.count", 1 do
          role = build_service.add_member(new_email, Grovs::Roles::MEMBER, instance)
          assert role
          assert_equal Grovs::Roles::MEMBER, role.role

          invited_user = User.find_by(email: new_email)
          assert invited_user, "User should have been created via invite"
          assert_equal role.user_id, invited_user.id
        end
      end
    end
  end

  def count_new_member_mails(&block)
    sent = 0
    NewMemberMailer.stub(:new_member, lambda { |*| 
      sent += 1
      OpenStruct.new(deliver_later: true)
    }, &block)
    sent
  end

  test "add_member self-hosted without smtp skips all invite emails but keeps the token" do
    instance = instances(:one)
    new_email = "sh_nosmtp_#{SecureRandom.hex(4)}@test.com"
    service = build_service

    Grovs.stub(:self_hosted?, true) do
      Grovs.stub(:smtp_enabled?, false) do
        sent = count_new_member_mails do
          assert_no_difference "ActionMailer::Base.deliveries.size" do
            assert service.add_member(new_email, Grovs::Roles::MEMBER, instance)
          end
        end
        assert_equal 0, sent
        assert service.last_invitation_token.present?
      end
    end
  end

  test "add_member self-hosted with smtp sends the devise invite only, no member email" do
    instance = instances(:one)
    new_email = "sh_smtp_#{SecureRandom.hex(4)}@test.com"
    service = build_service

    Grovs.stub(:self_hosted?, true) do
      Grovs.stub(:smtp_enabled?, true) do
        sent = count_new_member_mails do
          assert_difference "ActionMailer::Base.deliveries.size", 1 do
            assert service.add_member(new_email, Grovs::Roles::MEMBER, instance)
          end
        end
        assert_equal 0, sent, "an invitee gets invitation instructions, not the added-to-project mail"
        assert service.last_invitation_token.present?
      end
    end
  end

  test "add_member self-hosted re-notifies an already-invited user only when smtp is on" do
    instance = instances(:one)
    other_user = User.create!(email: "sh_renotify_#{SecureRandom.hex(4)}@test.com", password: "password123")
    InstanceRole.create!(role: Grovs::Roles::MEMBER, instance_id: instance.id, user_id: other_user.id)

    Grovs.stub(:self_hosted?, true) do
      Grovs.stub(:smtp_enabled?, false) do
        sent = count_new_member_mails do
          assert_nil build_service.add_member(other_user.email, Grovs::Roles::MEMBER, instance)
        end
        assert_equal 0, sent
      end

      Grovs.stub(:smtp_enabled?, true) do
        sent = count_new_member_mails do
          assert_nil build_service.add_member(other_user.email, Grovs::Roles::MEMBER, instance)
        end
        assert_equal 1, sent
      end
    end
  end

  test "add_member survives a rejected invite email and still returns the role and token" do
    instance = instances(:one)
    new_email = "sh_smtpfail_#{SecureRandom.hex(4)}@test.com"
    service = build_service

    Grovs.stub(:self_hosted?, true) do
      Grovs.stub(:smtp_enabled?, true) do
        boom = ->(*) { raise Net::SMTPFatalError, "554 Message rejected: Email address is not verified" }
        sent = count_new_member_mails do
          Devise::Mailer.stub(:invitation_instructions, boom) do
            assert service.add_member(new_email, Grovs::Roles::MEMBER, instance)
          end
        end
        assert_equal 0, sent
        assert service.last_invitation_token.present?
      end
    end
  end

  test "add_member on SaaS ignores the smtp flag and sends emails as before" do
    instance = instances(:one)
    new_email = "saas_smtp_#{SecureRandom.hex(4)}@test.com"

    Grovs.stub(:self_hosted?, false) do
      Grovs.stub(:smtp_enabled?, true) do
        sent = count_new_member_mails do
          assert_difference "ActionMailer::Base.deliveries.size", 1 do
            assert build_service.add_member(new_email, Grovs::Roles::MEMBER, instance)
          end
        end
        assert_equal 0, sent
      end
    end
  end

  test "add_member re-invites a pending invitee added to a second instance" do
    pending = User.invite!({ email: "sh_pending_#{SecureRandom.hex(4)}@test.com", skip_invitation: true }, @user)
    first_token = pending.raw_invitation_token
    InstanceRole.create!(role: Grovs::Roles::MEMBER, instance_id: instances(:one).id, user_id: pending.id)

    Grovs.stub(:self_hosted?, true) do
      Grovs.stub(:smtp_enabled?, true) do
        service = build_service
        sent = count_new_member_mails do
          assert_difference "ActionMailer::Base.deliveries.size", 1 do
            assert service.add_member(pending.email, Grovs::Roles::MEMBER, instances(:two))
          end
        end
        assert_equal 0, sent, "a pending invitee gets only the re-invite, not the added-to-project mail"
        token = service.invitation_tokens[pending.email]
        assert token.present?
        assert_not_equal first_token, token, "re-invite must issue a fresh token"
        assert_equal pending.id, User.find_by_invitation_token(token, true)&.id
      end
    end
  end

  test "add_member re-adding a pending invitee to the same instance resends the invitation" do
    pending = User.invite!({ email: "sh_resend_#{SecureRandom.hex(4)}@test.com", skip_invitation: true }, @user)
    first_token = pending.raw_invitation_token
    InstanceRole.create!(role: Grovs::Roles::MEMBER, instance_id: instances(:one).id, user_id: pending.id)

    Grovs.stub(:self_hosted?, true) do
      Grovs.stub(:smtp_enabled?, true) do
        service = build_service
        sent = count_new_member_mails do
          assert_difference "ActionMailer::Base.deliveries.size", 1 do
            assert_nil service.add_member(pending.email, Grovs::Roles::MEMBER, instances(:one))
          end
        end
        assert_equal 0, sent, "a passwordless invitee must get the invitation again, not the project mail"
        token = service.invitation_tokens[pending.email]
        assert token.present?
        assert_not_equal first_token, token
      end
    end
  end

  test "add_member self-hosted without smtp re-invites a pending invitee with token only" do
    pending = User.invite!({ email: "sh_pending_ns_#{SecureRandom.hex(4)}@test.com", skip_invitation: true }, @user)

    Grovs.stub(:self_hosted?, true) do
      Grovs.stub(:smtp_enabled?, false) do
        service = build_service
        sent = count_new_member_mails do
          assert_no_difference "ActionMailer::Base.deliveries.size" do
            assert service.add_member(pending.email, Grovs::Roles::MEMBER, instances(:one))
          end
        end
        assert_equal 0, sent
        assert service.invitation_tokens[pending.email].present?
      end
    end
  end

  test "add_member does not re-invite a user who accepted or signed up normally" do
    normal = User.create!(email: "sh_normal_#{SecureRandom.hex(4)}@test.com", password: "password123")

    Grovs.stub(:self_hosted?, true) do
      Grovs.stub(:smtp_enabled?, true) do
        service = build_service
        assert_no_difference "ActionMailer::Base.deliveries.size" do
          count_new_member_mails do
            assert service.add_member(normal.email, Grovs::Roles::MEMBER, instances(:one))
          end
        end
        assert_empty service.invitation_tokens
      end
    end
  end

  test "add_member self-hosted with smtp emails an existing user granted a role" do
    instance = instances(:one)
    other_user = User.create!(email: "sh_existing_#{SecureRandom.hex(4)}@test.com", password: "password123")

    Grovs.stub(:self_hosted?, true) do
      Grovs.stub(:smtp_enabled?, true) do
        sent = count_new_member_mails do
          assert build_service.add_member(other_user.email, Grovs::Roles::MEMBER, instance)
        end
        assert_equal 1, sent
      end
    end
  end

  # === generate_* helpers (implicitly tested) ===

  test "generate helpers produce correctly formatted values" do
    instance = create_without_cache(build_service, name: "Format Test!")

    # api_key: cleaned name (6 chars) + "_" + hex
    assert_match(/\A[a-z0-9]{1,6}_[0-9a-f]{64}\z/, instance.api_key)

    # uri_scheme: cleaned name (6 chars) + hex
    assert_match(/\A[a-z0-9]{1,6}[0-9a-f]{12}\z/, instance.uri_scheme)

    # subdomain: first 4 chars of cleaned name + hex
    subdomain = instance.production.domain.subdomain
    assert_match(/\A[a-z0-9]{1,4}[0-9a-f]{4}\z/, subdomain)
  end
end
