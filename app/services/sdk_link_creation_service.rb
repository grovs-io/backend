class SdkLinkCreationService
  MAX_PATH_ATTEMPTS = 3

  def self.create(project:, platform:, visitor: nil, sdk_generated: true, title: nil, subtitle: nil, # rubocop:disable Metrics/ParameterLists
                  image_url: nil, image: nil, data: nil, tags: nil,
                  show_preview_ios: nil, show_preview_android: nil,
                  copy_to_clipboard_ios: nil, copy_to_clipboard_android: nil,
                  tracking_campaign: nil, tracking_source: nil, tracking_medium: nil)
    domain = project.domain_for_project
    link = Link.new(
      generated_from_platform: platform, title: title, subtitle: subtitle,
      path: LinksService.generate_valid_path(domain), domain: domain,
      redirect_config: project.redirect_config, sdk_generated: sdk_generated,
      image_url: image_url, visitor: visitor, data: data,
      tracking_campaign: tracking_campaign, tracking_source: tracking_source, tracking_medium: tracking_medium,
      show_preview_ios: show_preview_ios, show_preview_android: show_preview_android,
      copy_to_clipboard_ios: copy_to_clipboard_ios, copy_to_clipboard_android: copy_to_clipboard_android
    )
    link.tags = tags if tags
    link.image.attach(image) if image
    save_with_fresh_path!(link, domain)
    link
  end

  def self.save_with_fresh_path!(link, domain)
    attempts = 0
    begin
      link.save!
    rescue ActiveRecord::RecordInvalid => e
      # No unique index on links: a lost path race surfaces as path_must_be_unique, not RecordNotUnique.
      raise if e.record.errors[:path].empty?
      raise LinksService::PathGenerationError, "path race unresolved for domain #{domain.id}" if (attempts += 1) > MAX_PATH_ATTEMPTS

      link.path = LinksService.generate_valid_path(domain)
      retry
    end
  end
  private_class_method :save_with_fresh_path!
end
