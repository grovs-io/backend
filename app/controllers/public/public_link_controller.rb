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

  def generate_random_path
    loop do
      # generate a random token string and return it,
      # unless there is already another token with the same string
      path = SecureRandom.hex(32)[0, 5]
      break path unless QuickLink.exists?(path: path) && path != "create"
    end
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