class Campaign < ApplicationRecord
  belongs_to :project
  has_many :links, dependent: :nullify

  validates :name, presence: true

  # prepend: dependent: :nullify would otherwise empty the association before we read the ids.
  before_destroy :bump_links_for_dimension_sync, prepend: true
  after_commit :sync_link_dimensions, on: :destroy

  private

  # nullify uses update_all, skipping callbacks AND updated_at, so reconciliation needs the bump.
  def bump_links_for_dimension_sync
    @dimension_link_ids = links.pluck(:id)
    links.update_all(updated_at: Time.current)
  end

  def sync_link_dimensions
    return if @dimension_link_ids.blank?

    LinkDimensionSyncService.sync_many(Link.includes(:domain).where(id: @dimension_link_ids))
  end
end
