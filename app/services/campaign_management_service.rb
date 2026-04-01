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
    ActiveRecord::Base.transaction do
      campaign.archived = true
      campaign.save!

      campaign.links.each do |link|
        link.active = false
        link.save!
      end
    end

    campaign.reload
  end
end
