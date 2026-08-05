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
    link = QuickLink.new(link_params)
    link.domain = domain
    link.path = generate_random_path()

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

  # Escalating lengths + bounded attempts: 16^5 is only ~1M paths, so an
  # exhausted namespace must degrade to longer paths, never spin forever.
  # "create" is reserved (routes collide with the create action).
  def generate_random_path
    [5, 8, 10, 12].each do |length|
      5.times do
        path = SecureRandom.hex((length + 1) / 2)[0, length]
        next if path == "create"

        return path unless QuickLink.exists?(path: path)
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