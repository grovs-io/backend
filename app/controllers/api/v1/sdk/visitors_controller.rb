class Api::V1::Sdk::VisitorsController < Api::V1::Sdk::BaseController
  def visitor_attributes
    render json: {visitor: VisitorSerializer.serialize(@visitor)}, status: :ok
  end

  def set_visitor_attributes
    @visitor.sdk_attributes = sdk_attributes_param || nil

    @visitor.sdk_identifier = sdk_identifier_param || nil

    if push_token_param
      @device.push_token = push_token_param
    end

    @visitor.save!
    @device.save!

    render json: {visitor: VisitorSerializer.serialize(@visitor)}, status: :ok
  end

  private

  def sdk_attributes_param
    params.permit(:sdk_attributes => {})[:sdk_attributes]
  end

  def sdk_identifier_param
    params.permit(:sdk_identifier)[:sdk_identifier]
  end

  def push_token_param
    params.permit(:push_token)[:push_token]
  end
end
