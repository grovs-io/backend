class SmartBannerLink < ApplicationRecord
  belongs_to :smart_banner, counter_cache: :links_count
  belongs_to :link
end
