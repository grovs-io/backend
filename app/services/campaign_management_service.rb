class CampaignManagementService
  def initialize(project:)
    @project = project
  end

  # Returns Campaign (creates with project association).
  def create(name:)
    unless @project.redirect_config
      raise ArgumentError, "You can't create links before you create a redirect configuration!"
    end

    campaign = Campaign.new(name: name)
    campaign.project = @project
    campaign.save!
    campaign
  end

  # Returns Campaign.
  def update(campaign:, attrs:)
    campaign.update!(attrs)
    campaign
  end

  # Transactional: archives campaign + deactivates all its links. Returns Campaign.
  def archive(campaign:)
    ids = []
    ActiveRecord::Base.transaction do
      campaign.archived = true
      campaign.save!

      archived = campaign.links.where(active: true)
      ids = archived.pluck(:id)
      # touch updated_at too: update_all skips callbacks, so reconciliation needs the bump.
      archived.update_all(active: false, updated_at: Time.current)
    end

    if ids.present?
      links = Link.includes(:domain).where(id: ids).to_a
      # update_all skipped after_commit too, so the cached lookups still say active.
      links.each { |link| link.send(:clear_cache) }
      LinkDimensionSyncService.sync_many(links)
    end

    campaign.reload
  end
end
