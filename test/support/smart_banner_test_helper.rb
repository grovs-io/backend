module SmartBannerTestHelper
  PNG_1X1 = Base64.decode64(
    "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNkYPhfDwAChwGA60e6kgAAAABJRU5ErkJggg=="
  ).freeze

  def create_test_banner(project, **attrs)
    ensure_redirect_config(project)
    status = attrs.delete(:status) || "live"
    create_attrs = { project: project, name: "Main", title: "Get the app" }.merge(attrs)
    create_attrs[:status] = SmartBanner::CREATE_STATUSES.include?(status) ? status : "draft"
    banner = SmartBanner.create!(create_attrs)
    banner.update!(status: status) unless banner.status == status
    SmartBannerLinkService.create_default_link!(banner)
    banner
  end

  def ensure_redirect_config(project)
    return if RedirectConfig.exists?(project_id: project.id)

    RedirectConfig.create!(project: project, default_fallback: "https://example.com/fallback",
                           show_preview_ios: false, show_preview_android: false)
    project.reload
  end

  def png_attachable
    { io: StringIO.new(PNG_1X1), filename: "icon.png", content_type: "image/png" }
  end

  def png_upload
    file = Tempfile.new(["icon", ".png"])
    file.binmode
    file.write(PNG_1X1)
    file.rewind
    Rack::Test::UploadedFile.new(file.path, "image/png")
  end
end
