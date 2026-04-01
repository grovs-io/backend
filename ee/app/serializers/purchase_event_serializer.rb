class PurchaseEventSerializer < BaseSerializer
  attributes :id, :event_type, :purchase_type, :product_id,
             :identifier, :transaction_id, :original_transaction_id,
             :price_cents, :usd_price_cents, :currency,
             :date, :expires_date, :processed, :store,
             :store_source, :webhook_validated, :quantity, :order_id


  def build(**)
    h = super()
    h["platform"] = record.device&.platform || record.store_platform
    h["link_id"] = record.link_id
    h
  end
end
