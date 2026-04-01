class LinkManagementService
  def initialize(project:)
    @project = project
  end

  # Returns Link. Handles tags, data, image, campaign, custom redirects.
  def create(link_attrs:, tags: nil, data: nil, image: nil, image_url: nil,
             campaign_id: nil, custom_redirects: {})
    domain = @project.domain_for_project
    raise ActiveRecord::RecordNotFound, "Domain not found" unless domain

    unless @project.redirect_config
      raise ArgumentError, "You can't create links before you create a redirect configuration!"
    end

    link = Link.new(link_attrs)
    link.generated_from_platform = "dashboard"
    link.domain = domain
    link.active = true
    link.redirect_config = @project.redirect_config
    link.image_url = image_url

    apply_tags(link, tags)
    apply_data(link, data)
    apply_image(link, image)
    apply_campaign(link, campaign_id, @project)

    link.save!

    apply_custom_redirects(link, custom_redirects)
    link
  end

  # Returns Link. Handles image swap, path change validation, preview flags.
  def update(link:, link_attrs:, tags: nil, data: nil, image: nil,
             campaign_id: nil, custom_redirects: {})
    if link_attrs[:path] && link.path != link_attrs[:path]
      new_link = Link.new(domain: link.domain, path: link_attrs[:path])
      raise ActiveRecord::RecordInvalid.new(new_link), "The path is not valid" unless new_link.valid_path?
    end

    link.update!(link_attrs)

    if image
      link.image.attach(image)
    else
      link.image.purge
    end

    if data
      link.data = JSON.parse(data)
    else
      link.data = nil
    end

    apply_tags(link, tags)

    if campaign_id
      campaign = Campaign.find_by(id: campaign_id)
      link.campaign_id = campaign_id if campaign && campaign.project_id == link.domain.project_id
    end

    link.save!

    apply_custom_redirects(link, custom_redirects)
    link
  end

  # Soft-deletes link (active=false). Returns Link.
  def archive(link:)
    link.active = false
    link.save!
    link
  end

  # Returns Boolean
  def path_available?(path:, domain:)
    return false if contains_special_characters?(path)

    link = Link.new(domain: domain, path: path)
    link.valid_path?
  end

  # Returns { valid_path: String }
  def generate_path(domain:)
    path = LinksService.generate_valid_path(domain)
    { valid_path: path }
  end

  private

  def apply_tags(link, tags)
    return unless tags

    parsed_tags = JSON.parse(tags)
    raise ArgumentError, "Tags must be a JSON array" unless parsed_tags.is_a?(Array)

    link.tags = parsed_tags
  end

  def apply_data(link, data)
    link.data = data ? JSON.parse(data) : nil
  end

  def apply_image(link, image)
    link.image.attach(image) if image
  end

  def apply_campaign(link, campaign_id, project)
    return unless campaign_id

    campaign = Campaign.find_by(id: campaign_id)
    if campaign && campaign.project_id == project.id
      link.campaign_id = campaign_id
      link.tracking_campaign = campaign.name unless link.tracking_campaign.present?
    end
  end

  def apply_custom_redirects(link, custom_redirects)
    return if custom_redirects.empty?

    ActiveRecord::Base.transaction do
      apply_platform_redirect(link, :ios, custom_redirects[:ios], require_open_app: true)
      apply_platform_redirect(link, :android, custom_redirects[:android], require_open_app: true)
      apply_platform_redirect(link, :desktop, custom_redirects[:desktop], require_open_app: false)
    end
  end

  def apply_platform_redirect(link, platform, data, require_open_app:)
    platform_const = platform.to_s.downcase
    raise ArgumentError, "Unknown platform: #{platform}" unless Grovs::Platforms::ALL.include?(platform_const)
    existing = link.send(:"#{platform}_custom_redirect")

    if data && data["url"]
      existing&.destroy
      link.custom_redirects.create!(
        platform: platform_const,
        url: data["url"],
        open_app_if_installed: require_open_app ? data["open_app_if_installed"] : false
      )
    else
      existing&.destroy
    end
  end

  def contains_special_characters?(str)
    !!(str =~ /[^a-zA-Z0-9-]/)
  end
end
