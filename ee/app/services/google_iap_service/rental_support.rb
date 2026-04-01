class GoogleIapService
  module RentalSupport
    module_function

    # Determine purchase_type based on API response.
    # Returns TYPE_RENTAL if rental indicators are present, otherwise TYPE_ONE_TIME.
    def determine_purchase_type(purchase_data)
      if rental?(purchase_data)
        Grovs::Purchases::TYPE_RENTAL
      else
        Grovs::Purchases::TYPE_ONE_TIME
      end
    end

    # Check if a purchase response indicates a rental.
    #
    # Detection paths (from google-apis-androidpublisher_v3 gem):
    #   - ProductLineItem → product_offer_details → rent_offer_details
    #   - ProductPurchaseV2 → product_line_item → [any].product_offer_details → rent_offer_details
    def rental?(purchase_data)
      return false unless purchase_data

      # Path 1: ProductLineItem (direct line item) — product_offer_details.rent_offer_details
      offer_details = purchase_data.respond_to?(:product_offer_details) && purchase_data.product_offer_details
      if offer_details && offer_details.respond_to?(:rent_offer_details) &&
         offer_details.rent_offer_details
        return true
      end

      # Path 2: ProductPurchaseV2 (full response) — check any line item
      if purchase_data.respond_to?(:product_line_item) && purchase_data.product_line_item
        return purchase_data.product_line_item.any? do |li|
          li.respond_to?(:product_offer_details) && li.product_offer_details &&
            li.product_offer_details.respond_to?(:rent_offer_details) &&
            li.product_offer_details.rent_offer_details
        end
      end

      false
    end
  end
end
