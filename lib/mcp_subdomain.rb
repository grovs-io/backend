class McpSubdomain
  def self.matches?(request)
    label, = Grovs::Domains.split(request.host)
    label == Grovs::Subdomains::MCP
  end
end
