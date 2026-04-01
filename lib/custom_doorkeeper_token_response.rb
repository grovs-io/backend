module CustomDoorkeeperTokenResponse
  def body
    current_user = User.find_by(id: @token.resource_owner_id)
    additional_data = {
      user: current_user
    }

    # call original `#body` method and merge its result with the additional data hash
    super.merge(additional_data)
  end
end