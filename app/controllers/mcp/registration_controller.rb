class Mcp::RegistrationController < ApplicationController
  # POST /register
  #
  # SECURITY NOTE: This endpoint is unauthenticated by design (RFC 7591 Dynamic
  # Client Registration). Any anonymous request can register an OAuth client.
  # This is safe because:
  #   1. Registered clients are public (no client_secret) — a client_id alone
  #      grants no access. Users must still authenticate and consent.
  #   2. PKCE (S256) is mandatory on every authorization flow.
  #   3. Redirect URIs are validated (localhost http or https only).
  #   4. Rate-limited to 5 requests/min per IP (Rack::Attack).
  #
  # Self-hosters: if your instance is internet-facing and you want to restrict
  # which MCP clients can register, add IP allowlisting or a reverse-proxy auth
  # layer in front of the /register endpoint.
  def create
    client_name = params[:client_name]
    redirect_uris = params[:redirect_uris]

    unless client_name.present? && redirect_uris.present?
      render json: { error: "client_name and redirect_uris are required" }, status: :bad_request
      return
    end

    redirect_uris = Array(redirect_uris)

    # Return existing client if same name + URIs
    existing = McpClient.find_by(client_name: client_name)
    if existing && existing.redirect_uris.sort == redirect_uris.sort
      render json: client_response(existing), status: :created
      return
    end

    client = McpClient.new(
      client_name: client_name,
      redirect_uris: redirect_uris,
      grant_types: (params[:grant_types] || ["authorization_code"]).join(","),
      response_types: (params[:response_types] || ["code"]).join(","),
      token_endpoint_auth_method: params[:token_endpoint_auth_method] || "none",
      application_type: params[:application_type] || "native",
      client_uri: params[:client_uri],
      logo_uri: params[:logo_uri]
    )

    if client.save
      render json: client_response(client), status: :created
    else
      render json: { error: client.errors.full_messages.join(", ") }, status: :bad_request
    end
  end

  private

  def client_response(client)
    {
      client_id: client.client_id,
      client_name: client.client_name,
      redirect_uris: client.redirect_uris,
      grant_types: client.grant_types.split(","),
      response_types: client.response_types.split(","),
      token_endpoint_auth_method: client.token_endpoint_auth_method,
      application_type: client.application_type
    }
  end
end
