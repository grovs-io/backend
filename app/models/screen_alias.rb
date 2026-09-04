class ScreenAlias < ApplicationRecord
  belongs_to :project

  validates :screen_identifier, presence: true, length: { maximum: 255 }
  validates :alias_name, presence: true, length: { maximum: 255 }
  # Uniqueness enforced by DB index (index_screen_aliases_on_project_id_and_screen_identifier).
  # No AR validation — the only write path is upsert_all which bypasses validations.
end
