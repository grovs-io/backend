class InAppProductDailyStatistic < ApplicationRecord
  belongs_to :in_app_product
  belongs_to :project
end
