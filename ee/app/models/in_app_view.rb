class InAppView < ApplicationRecord
  self.primary_key = %i[in_app_campaign_id person_key]
end
