class McpSubdomain
  def self.matches?(request)
    request.subdomain == Grovs::Subdomains::MCP && Grovs::Domains::MAIN.include?(request.domain)
  end
end
