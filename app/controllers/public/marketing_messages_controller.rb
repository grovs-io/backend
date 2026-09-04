class Public::MarketingMessagesController < Public::BaseController
  ALLOWED_TAGS = %w[h1 h2 h3 h4 h5 h6 p div span a img ul ol li br hr b i u em strong
                    table thead tbody tr th td blockquote pre code section header footer
                    figure figcaption video source audio].freeze

  ALLOWED_ATTRIBUTES = %w[href src alt title class id style width height target rel
                          colspan rowspan type media].freeze

  # Tags whose text content is code, not copy — dropped whole instead of hoisting children.
  PRUNE_CONTENT_TAGS = %w[script style noscript iframe object embed].freeze

  # Patterns that enable data exfiltration or code execution inside style attributes.
  DANGEROUS_CSS_PATTERN = /
    url\s*\(        |  # background-image: url(...) data exfiltration
    expression\s*\( |  # IE expression() code execution
    -moz-binding    |  # Firefox XBL binding
    behavior\s*:    |  # IE behavior property
    @import         |  # external stylesheet import
    javascript\s*:     # javascript: protocol in values
  /xi

  def open_marketing_message
    notification_id = extract_notification_id
    unless notification_id
      render_not_found
      return
    end

    notification = Notification.find_by_hashid(notification_id)
    unless notification
      render_not_found
      return
    end

    # Scope to the requesting host's project so a notification cannot be rendered
    # under another tenant's (custom or sqd.link) domain. Use the cached lookup so
    # the /mm hot path matches the same Redis-backed read pattern the link path uses.
    domain = LinksService.main_domain_for(request) ||
             LinksService.custom_hostname_for(request.host)
    unless domain && notification.project_id == domain.project_id
      render_not_found
      return
    end

    response.headers.delete "X-Frame-Options"
    safe_html = sanitize_html(notification.html)
    render html: safe_html
  end

  private

  def extract_notification_id
    path = request.path[1..]
    return nil unless path&.start_with?("mm/")

    path.sub(%r{^mm/}, '')
  end

  def sanitize_html(html)
    doc = Loofah.fragment(html)
    doc.scrub!(tag_scrubber)
    strip_dangerous_styles(doc)
    doc.to_s.html_safe # rubocop:disable Rails/OutputSafety — Loofah output is safe by construction
  end

  # Bottom-up so children hoisted out of a stripped tag are already scrubbed — top-down never revisits them.
  def tag_scrubber
    Loofah::Scrubber.new(direction: :bottom_up) do |node|
      next unless node.element?

      if ALLOWED_TAGS.include?(node.name)
        node.attributes.each_key do |attr_name|
          node.remove_attribute(attr_name) unless ALLOWED_ATTRIBUTES.include?(attr_name)
        end
        strip_dangerous_scheme(node, "href") if node["href"]
        strip_dangerous_scheme(node, "src") if node["src"]
      else
        node.before(node.children) unless PRUNE_CONTENT_TAGS.include?(node.name)
        node.remove
      end
    end
  end

  def strip_dangerous_scheme(node, attr)
    value = node[attr].to_s.gsub(/[[:space:][:cntrl:]]/, "")
    node.remove_attribute(attr) if value =~ /\A(javascript|data|vbscript):/i
  end

  def strip_dangerous_styles(doc)
    doc.css("[style]").each do |node|
      style_value = node["style"].to_s
      if DANGEROUS_CSS_PATTERN.match?(style_value)
        node.remove_attribute("style")
      end
    end
  end
end
