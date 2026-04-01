class NotificationTarget < ApplicationRecord
  belongs_to :notification

  validates :platforms, inclusion: { in: Grovs::Platforms::ALL }
  validate :user_targeting_must_have_one_segment

  def user_targeting_must_have_one_segment
    if new_users == false && existing_users == false
      errors.add(:fallback, "New and existing can't be both false")
    end

    if new_users == true && existing_users == true
      errors.add(:fallback, "New and existing can't be both true")
    end
  end
end
