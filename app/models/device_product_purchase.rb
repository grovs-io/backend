class DeviceProductPurchase < ApplicationRecord
  belongs_to :device
  belongs_to :project
end
