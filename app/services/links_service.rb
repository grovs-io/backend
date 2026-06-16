require 'uri'
require 'public_suffix'

class LinksService

  class << self

    # Short-circuits on MAIN hosts so scanner traffic on *.sqd.link doesn't fire a second
    # uncached PG query per request (redis_find_by doesn't cache nils). MAIN match is 2-label
    # registrable-domain — revisit if MAIN ever includes a ccTLD.
    def custom_hostname_for(host)
      return nil unless Grovs.custom_domains_enabled?
      return nil if host.blank?

      lower_host = host.to_s.downcase
      registrable_domain = lower_host.split(".").last(2).join(".")
      return nil if Grovs::Domains::MAIN.include?(registrable_domain) ||
                    Grovs::Domains::MAIN.include?(lower_host)

      ch = CustomHostname.redis_find_by(:hostname, lower_host)
      return nil unless ch&.resolvable?

      Domain.redis_find_by(:id, ch.domain_id)
    end

    # Whitelists primary so any future non-primary purpose also fails closed; a Grovs link
    # whose path matches an upstream Branch slug must not short-circuit the migration flow.
    def primary_custom_hostname_for(host)
      return nil unless Grovs.custom_domains_enabled?
      return nil if host.blank?

      lower_host = host.to_s.downcase
      registrable_domain = lower_host.split(".").last(2).join(".")
      return nil if Grovs::Domains::MAIN.include?(registrable_domain) ||
                    Grovs::Domains::MAIN.include?(lower_host)

      ch = CustomHostname.redis_find_by(:hostname, lower_host)
      return nil unless ch&.primary? && ch.resolvable?

      Domain.redis_find_by(:id, ch.domain_id)
    end

    def project_scoped(link, project)
      return nil unless link && project

      link.domain&.project_id == project.id ? link : nil
    end

    def link_for_request(request)
      request_domain = request.domain
      # request_domain = "sqd.link"
      # request_domain = "test-sqd.link"

      request_subdomain = request.subdomain
      request_path = request.path[1..]

      domain = Domain.redis_find_by_multiple_conditions({ domain: request_domain, subdomain: request_subdomain }) ||
               primary_custom_hostname_for(request.host)
      unless domain
        Rails.logger.warn("domain not found")
        return nil
      end

      Link.redis_find_by_multiple_conditions({ path: request_path, domain_id: domain.id })

      
    end

    def link_for_redirect_url(redirect_url)
      unless redirect_url
        return nil
      end

      uri = URI(redirect_url)
      parts = uri.host.split('.')

      domain = parts.last(2).join('.')
      subdomain = parts.length > 2 ? parts[0...-2].join('.') : nil
      path = uri.path.sub(%r{^/}, '')

      domain = Domain.redis_find_by_multiple_conditions({ domain: domain, subdomain: subdomain }) ||
               primary_custom_hostname_for(uri.host)
      unless domain
        Rails.logger.warn("domain not found")
        return nil
      end

      Link.redis_find_by_multiple_conditions({ path: path, domain_id: domain.id })

      
    end

    def build_preview_url(link)
      base_url = ENV['PREVIEW_BASE_URL']
      return nil unless base_url && link

      uri = URI.parse(base_url)
      query_params = URI.decode_www_form(uri.query || "")
      query_params << ["url", link.access_path]
      uri.query = URI.encode_www_form(query_params)

      uri.to_s
    end

    def build_redirect_url_for_preview(url_param, link, device)
      return nil unless url_param && link

      # We need to check if there is redirect config available
      case device.platform
      when Grovs::Platforms::IOS
        custom_redirect = link.ios_custom_redirect
        ios_direct_link = build_direct_redirect_for_preview(link, custom_redirect)
        if ios_direct_link
          return ios_direct_link
        end

       when Grovs::Platforms::ANDROID
         custom_redirect = link.android_custom_redirect
         android_direct_link = build_direct_redirect_for_preview(link, custom_redirect)
         if android_direct_link
           return android_direct_link
         end
      end

      uri = URI.parse(url_param)
      query_params = URI.decode_www_form(uri.query || "")
      query_params << ["go_to_fallback", true]
      uri.query = URI.encode_www_form(query_params)

      uri.to_s
    end

    def build_direct_redirect_for_preview(link, redirect)
      if redirect && !redirect.open_app_if_installed
        url = redirect.url =~ %r{\Ahttps?://} ? redirect.url : "https://#{redirect.url}"
        uri = URI.parse(url)

        query_params = URI.decode_www_form(uri.query || "")
        query_params << ['utm_campaign', link.tracking_campaign] if link.tracking_campaign
        query_params << ['utm_source', link.tracking_source] if link.tracking_source
        query_params << ['utm_medium', link.tracking_medium] if link.tracking_medium
        if query_params.count > 0
          uri.query = URI.encode_www_form(query_params)
        end

        return uri.to_s
      end

      nil
    end

    def link_for_url(url, project)
      return nil if url.blank? || !url.match?(%r{\A\w+://}) || !url.ascii_only?

      clean_url = strip_query_params(url)
      url_host = URI.parse(clean_url).host rescue nil

      universal_url_components = parse_universal_link(clean_url)
      if universal_url_components
        domain = Domain.redis_find_by_multiple_conditions({ domain: universal_url_components[:domain], subdomain: universal_url_components[:subdomain] }) ||
                 primary_custom_hostname_for(url_host)
        if domain
          link = Link.redis_find_by_multiple_conditions({ domain: domain.id, path: universal_url_components[:path] })
          return project_scoped(link, project) if link
        end
      end

      uri_components = parse_uri(url)
      unless uri_components
        return nil
      end

      domain = Domain.redis_find_by_multiple_conditions({ domain: uri_components[:domain], subdomain: uri_components[:subdomain] })
      if domain
        link = Link.redis_find_by_multiple_conditions({ domain: domain.id, path: uri_components[:path] })
        return project_scoped(link, project) if link
      end

      uri_scheme = uri_components[:domain].start_with?('.') ? uri_components[:domain][1..] : uri_components[:domain]
      instance = Instance.redis_find_by(:uri_scheme, uri_scheme)
      return nil unless instance

      project_scoped(instance.link_for_path(uri_components[:path]), project)
    end

    def link_for_project_and_path(project, path)
      # Search link
      domain = project.domain
      if domain
        Link.redis_find_by_multiple_conditions({ domain: domain.id, path: path })
        
      end
    end

    def parse_universal_link(url)
      
      # Validate and escape invalid URLs
      uri = URI.parse(url)
      raise URI::InvalidURIError unless uri.scheme && uri.host

      ps = PublicSuffix.parse(uri.host)
      path = uri.path
      path = path.slice(1..-1) if path.present?

      {
      domain: ps.domain,
      subdomain: ps.trd,
      path: path
      }
    rescue URI::InvalidURIError, PublicSuffix::DomainNotAllowed, PublicSuffix::DomainInvalid => e
      # Custom-scheme deep links (e.g. "myapp://path") legitimately fail PublicSuffix —
      # they have no registrable host. This is expected input, not an error, so log at
      # debug to keep it out of the error stream. Caller handles the nil return.
      Rails.logger.debug("Invalid URL: #{url} - #{e.message}")
      nil

    end

    def strip_query_params(url)
      
      # Validate and parse the URL
      uri = URI.parse(url)
      raise URI::InvalidURIError unless uri.scheme && uri.host

      # Build the URL without query parameters
      # Use scheme, userinfo (if present), host, port (if not default), and path components
      result = ""
      result << "#{uri.scheme}://"
      result << "#{uri.userinfo}@" if uri.userinfo
      result << uri.host
      result << ":#{uri.port}" if uri.port && uri.port != URI.parse("#{uri.scheme}://#{uri.host}").port
      result << uri.path if uri.path.present?

      # Return the URL without query parameters
      result
    rescue URI::InvalidURIError => e
      # Same as parse_universal_link: unparseable/custom-scheme URLs are expected input.
      # Log at debug and fall back to the original URL.
      Rails.logger.debug("Invalid URL in strip_query_params: #{url} - #{e.message}")
      url # Return original URL if parsing fails
      
    end

    def parse_uri(uri)
      
      parsed_uri = URI.parse(uri)

      # Ensure there's at least a scheme
      raise URI::InvalidURIError, "Missing scheme" unless parsed_uri.scheme

      domain = nil
      subdomain = nil
      path = nil

      if parsed_uri.host
        domain = parsed_uri.scheme
        path = parsed_uri.host
      else
        # For custom schemes, use scheme as domain fallback
        domain = parsed_uri.scheme
        path = parsed_uri.path
        path = path.slice(1..-1) if path.present?
      end

      {
          domain: domain,
          subdomain: subdomain,
          path: path
      }
    rescue StandardError => e
      Rails.logger.error("Invalid URI: #{uri} - #{e.message}")
      nil
      
    end

    def generate_valid_path(domain)
      loop do
        # generate a random token string and return it,
        # unless there is already another token with the same string
        path = SecureRandom.hex(4)[0,6]
        if domain.project.test?
          path += "-test"
        end

        break path unless Link.exists?(domain: domain, path: path)
      end
    end

  end

end
