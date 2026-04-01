class GoogleIapService
  module QuantitySupport
    module_function

    # Extract quantity from a Google purchase API response object.
    # Returns 1 as default if the field is not present.
    def extract_quantity(purchase_data)
      if purchase_data.respond_to?(:quantity) && purchase_data.quantity.present?
        [purchase_data.quantity.to_i, 1].max
      else
        1
      end
    end
  end
end
