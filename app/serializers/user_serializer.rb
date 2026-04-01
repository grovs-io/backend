class UserSerializer < BaseSerializer
  attributes :id, :email, :name,
             :otp_required_for_login, :provider, :uid,
             :invitation_accepted_at, :invitation_sent_at


  def build(show_roles: false, **)
    h = super()
    h["roles"] = record.instance_roles_as_array if show_roles
    h
  end
end
