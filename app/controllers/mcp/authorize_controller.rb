class Mcp::AuthorizeController < ApplicationController
  # GET /authorize
  # Validates params, then redirects to the Next.js consent page.
  # The consent page handles user login + showing the approval UI.
  def show
    client_id = params[:client_id]
    redirect_uri = params[:redirect_uri]
    response_type = params[:response_type]
    code_challenge = params[:code_challenge]
    code_challenge_method = params[:code_challenge_method]
    state = params[:state]
    scope = params[:scope]

    unless response_type == "code"
      return render_authorize_error("unsupported_response_type", "Only response_type=code is supported")
    end

    unless client_id.present? && redirect_uri.present?
      return render_authorize_error("invalid_request", "client_id and redirect_uri are required")
    end

    unless code_challenge.present? && code_challenge_method == "S256"
      return render_authorize_error("invalid_request", "PKCE with S256 method is required")
    end

    client = McpClient.find_by(client_id: client_id)
    unless client
      return render_authorize_error("invalid_client", "Unknown client_id")
    end

    unless client.valid_redirect_uri?(redirect_uri)
      return render_authorize_error("invalid_request", "redirect_uri not registered for this client")
    end

    # Build the URL to the Next.js consent page
    consent_url = build_consent_url(
      client_id: client_id,
      client_name: client.client_name,
      redirect_uri: redirect_uri,
      code_challenge: code_challenge,
      code_challenge_method: code_challenge_method,
      state: state,
      scope: scope
    )

    redirect_to consent_url, allow_other_host: true
  end

  private

  def build_consent_url(params)
    base = ENV.fetch("MCP_CONSENT_URL", "http://localhost:3001/mcp/authorize")
    uri = URI.parse(base)
    query = URI.encode_www_form(params.compact)
    uri.query = query
    uri.to_s
  end

  ERROR_TEMPLATE = ERB.new(File.read(Rails.root.join("app/views/mcp/authorize/error.html.erb"))).freeze

  def render_authorize_error(code, description)
    rendered = ERROR_TEMPLATE.result_with_hash(
      error_code: ERB::Util.html_escape(code),
      error_description: ERB::Util.html_escape(description)
    )
    render html: rendered.html_safe, status: :bad_request # rubocop:disable Rails/OutputSafety
  end
end
