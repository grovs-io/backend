class McpSubdomain
  def self.matches?(request)
    request.subdomain == Grovs::Subdomains::MCP
  end
end
