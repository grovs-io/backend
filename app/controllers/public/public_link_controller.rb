class Public::PublicLinkController < ActionController::Base
  skip_before_action :verify_authenticity_token

  def get_link
    @link = QuickLink.find_by(path: path_param)
    unless @link
      render_not_found
      return
    end

    set_generic_data_for_link(@link)

    render template: "public/display/quick_links/quick_link", formats: [:html]
  end

  def create
    go_domain = domain
    # Self-hosted installs do not seed the go domain; fail cleanly rather than 500.
    unless go_domain
      render json: { error: "Quick links are not enabled on this deployment" }, status: :not_found
      return
    end

    link = QuickLink.new(link_params)
    link.domain = go_domain
    begin
      link.path = generate_random_path(go_domain)
    rescue LinksService::PathGenerationError => e
      Rails.logger.error("links.path_generation_failed #{e.message}")
      render json: { error: "Could not allocate a link path" }, status: :service_unavailable
      return
    end

    if image_param
      link.image.attach(image_param)
    end

    link.save!

    render json: {link: QuickLinkSerializer.serialize(link)}, status: :ok
  end

  private

  def set_generic_data_for_link(link)
    @page_title = "grovs"

    if link.title.present?
      @page_title = link.title
    end

    @page_subtitle = "Dynamic links, attributions, and referrals across mobile and web platforms."
    if link.subtitle.present?
      @page_subtitle = link.subtitle
    end

    @page_image = link.image_resource
    @page_image ||= Grovs::Links::SOCIAL_PREVIEW

    @page_full_path = link.access_path
  end

  def domain
    Domain.find_by(domain: Grovs::Domains::LIVE, subdomain: Grovs::Subdomains::GO)
  end

  # QuickLink#valid_path? validates against Link on this domain, so both tables must be checked.
  def generate_random_path(domain)
    [5, 8, 10, 12].each do |length|
      5.times do
        path = SecureRandom.hex((length + 1) / 2)[0, length]
        next if QuickLink.exists?(path: path)

        return path unless Link.exists?(domain: domain, path: path)
      end
    end

    raise LinksService::PathGenerationError, "could not generate a unique quick-link path"
  end

  def render_not_found
    render template: "public/display/not_found", formats: [:html]
  end

  # Params

  def path_param
    params.require(:path)
  end

  def image_param
    params.permit(:image)[:image]
  end

  def link_params
    params.permit(:ios_phone, :ios_tablet, :android_phone, :android_tablet, :desktop, :desktop_linux, :desktop_mac, :desktop_windows, :title, :subtitle, 
:image_url)
  end

end