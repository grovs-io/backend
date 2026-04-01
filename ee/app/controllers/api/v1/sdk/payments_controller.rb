class Api::V1::Sdk::PaymentsController < Api::V1::Sdk::BaseController
  def add_payment_event
    service = SdkPaymentService.new(
      project: @project, device: @device, visitor: @visitor,
      platform: @platform, identifier: @identifier
    )
    result = service.create_or_update(event_params: payment_event_params)
    if result[:error]
      render json: { error: result[:error] }, status: result[:status] || :ok
    else
      render json: { message: result[:message] }, status: :ok
    end
  end

  private

  def payment_event_params
    params.permit(:event_type, :bundle_id, :price_cents, :currency, :date, :transaction_id, :original_transaction_id, :product_id, :purchase_type, :store)
  end
end
