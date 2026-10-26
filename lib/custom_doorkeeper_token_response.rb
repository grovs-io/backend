module CustomDoorkeeperTokenResponse
  def body
    current_user = User.find_by(id: @token.resource_owner_id)
    # Serialized, never the raw row: that carries otp_secret and the SCIM columns.
    additional_data = {
      user: current_user && UserSerializer.serialize(current_user)
    }

    # call original `#body` method and merge its result with the additional data hash
    super.merge(additional_data)
  end
end
