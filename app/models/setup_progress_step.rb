class SetupProgressStep < ApplicationRecord
  VALID_CATEGORIES = %w[ios_setup android_setup web_setup].freeze
  VALID_STEP_IDENTIFIERS = %w[
    register_app url_scheme add_sdk push_notifications
    appstore_notifications initialize_sdk intent_filters
    google_play_notifications register_domains integrate_sdk
  ].freeze

  belongs_to :instance

  validates :category, presence: true, inclusion: { in: VALID_CATEGORIES }
  validates :step_identifier, presence: true, inclusion: { in: VALID_STEP_IDENTIFIERS }
  validates :step_identifier, uniqueness: { scope: [:instance_id, :category] }

end
