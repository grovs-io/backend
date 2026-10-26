module SmartBannerManagementService
  class InvalidOrder < StandardError; end

  module_function

  def create(project:, attrs:, icon: nil)
    ActiveRecord::Base.transaction do
      banner = project.smart_banners.new(attrs)
      banner.priority = (project.smart_banners.maximum(:priority) || -1) + 1
      banner.icon = icon if icon
      banner.save!
      SmartBannerLinkService.create_default_link!(banner)
      banner
    end
  end

  def update(banner:, attrs:, icon: nil, remove_icon: false)
    banner.assign_attributes(restore_attrs(banner, attrs))
    if icon
      banner.icon = icon
    elsif remove_icon
      banner.icon = nil
    end
    banner.save!
    banner
  end

  def reorder(project:, ids:)
    banners = project.smart_banners.where.not(status: "archived").to_a
    ids = ids.map { |id| Integer(id.to_s, exception: false) }
    unless ids.all? && ids.size == banners.size && ids.sort == banners.map(&:id).sort
      raise InvalidOrder, "ids must list every banner of the project exactly once"
    end

    by_id = banners.index_by(&:id)
    ActiveRecord::Base.transaction do
      ids.each_with_index { |id, index| by_id[id].update!(priority: index) }
    end
    project.smart_banners.ordered.to_a
  end

  def duplicate(banner:)
    ActiveRecord::Base.transaction do
      copy = banner.dup
      copy.name = "#{banner.name} (copy)"
      copy.status = "draft"
      copy.priority = (SmartBanner.where(project_id: banner.project_id).maximum(:priority) || -1) + 1
      copy.default_link = nil
      copy.links_count = 0
      copy.save!
      copy.icon.attach(banner.icon.blob) if banner.icon.attached?
      SmartBannerLinkService.create_default_link!(copy)
      copy
    end
  end

  # Restoring an archived banner always lands in paused, last in order, regardless of the requested status.
  def restore_attrs(banner, attrs)
    return attrs unless banner.status == "archived" && attrs[:status].present? && attrs[:status] != "archived"

    attrs.merge(status: "paused", priority: (SmartBanner.where(project_id: banner.project_id).maximum(:priority) || -1) + 1)
  end
end
