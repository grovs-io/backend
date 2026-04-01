class NotificationMessage < ApplicationRecord
  belongs_to :notification
  belongs_to :visitor

end
