# Returns a MigrationOutcome or nil (caller's existing not-found path).
class MigrationResolver
  # expected_project guards cross-tenant: a click authenticated as project A must not
  # materialize under project B's source.
  def self.resolve(host, path, query_string: "", expected_project: nil)
    return nil unless Grovs.migrations_enabled?

    normalized = normalize_host(host)
    source = MigrationSource.redis_find_by(:old_host, normalized)
    return nil unless source
    return nil if expected_project && source.project_id != expected_project.id

    # Stop serving migration traffic the moment the host becomes non-resolvable
    # (lifecycle suspends before delete).
    return nil unless custom_hostname_still_active?(source, normalized)

    # enabled=false does NOT short-circuit cached rows — those point at Grovs Links that
    # don't need upstream credentials. enabled gates only first-hits, below.
    cached = MigratedLink.redis_find_by_multiple_conditions(
      { migration_source_id: source.id, old_path: path.to_s }
    )
    if cached && fresh?(cached)
      outcome = serve(cached, source, query_string: query_string)
      return outcome if outcome
    end

    unless source.enabled
      # Auto-disable promises defaults; admin-disable means "stop migration" (404).
      return MigrationOutcome.project_defaults(source.project, provider: source.provider) if source.auto_disabled?
      return nil
    end

    FirstHitMigration.call(source: source, old_path: path.to_s, query_string: query_string.to_s)
  end

  def self.fresh?(row)
    return true if row.status == MigratedLink::STATUS_RESOLVED
    return false if row.cached_until.nil?
    row.cached_until > Time.current
  end

  def self.serve(row, source, query_string: "")
    case row.status
    when MigratedLink::STATUS_RESOLVED
      # link_id FK is :nullify on Link destroy. Re-resolving would silently undo the admin's
      # deletion, so serve defaults on an orphaned row.
      if row.link.nil?
        return MigrationOutcome.project_defaults(source.project, provider: source.provider)
      end
      MigrationOutcome.redirect(row.link, query_string: query_string, provider: source.provider)
    when MigratedLink::STATUS_NOT_FOUND, MigratedLink::STATUS_TRANSIENT_ERROR
      MigrationOutcome.project_defaults(source.project, provider: source.provider)
    end
  end

  # Dispatches three shapes:
  #   1. http(s) URL — host-based lookup.
  #   2. Play Store Install Referrer (`k=v&...`) — Branch's `~referring_link` carries the slug.
  #   3. Custom-scheme or bare slug — disambiguated by the SDK's authenticated project.
  def self.resolve_from_sdk(url_or_referrer, expected_project:)
    return nil unless Grovs.migrations_enabled?
    raw = url_or_referrer.to_s.strip
    return nil if raw.blank?

    uri = URI.parse(raw) rescue nil

    if uri&.scheme&.start_with?("http") && uri.host
      return resolve(uri.host,
                     uri.path.to_s.delete_prefix("/"),
                     query_string: uri.query.to_s,
                     expected_project: expected_project)
    end

    # Install Referrer: no-scheme + "=" is the cheapest reliable heuristic; false positives
    # just fall through to nil from the Branch path.
    if !raw.match?(%r{\A\w+://}) && raw.include?("=")
      return resolve_branch_install_referrer(raw, expected_project: expected_project)
    end

    resolve_via_project_source(raw, expected_project: expected_project)
  end

  # Branch-specific (`~referring_link`). AppsFlyer referrers carry no per-link identifier
  # and fall through to fingerprint attribution at the caller.
  def self.resolve_branch_install_referrer(referrer, expected_project:)
    params = parse_query_string(referrer)
    return nil if params.empty?

    branch_link = params["~referring_link"]
    return nil if branch_link.blank?

    uri = URI.parse(branch_link) rescue nil
    return nil unless uri&.host

    resolve(uri.host,
            uri.path.to_s.delete_prefix("/"),
            query_string: uri.query.to_s,
            expected_project: expected_project)
  end

  # Each project has at most one MigrationSource (unique index), so the project alone
  # disambiguates the upstream provider + old_host.
  def self.resolve_via_project_source(slug_input, expected_project:)
    return nil unless expected_project
    source = expected_project.migration_source
    return nil unless source

    slug = extract_slug(slug_input)
    return nil if slug.blank?

    resolve(source.old_host, slug,
            query_string: "",
            expected_project: expected_project)
  end

  def self.extract_slug(input)
    s = input.to_s.sub(%r{\A\w+://}, "")
    s = s.split(/[?#]/).first.to_s
    s.delete_prefix("/")
  end

  def self.parse_query_string(referrer)
    URI.decode_www_form(referrer.to_s).to_h
  rescue ArgumentError
    {}
  end

  # Symmetric with MigrationSource#normalize_old_host so request hosts match stored values.
  def self.normalize_host(host)
    return "" if host.blank?
    host.to_s.strip.downcase.chomp(".").sub(/:\d+\z/, "")
  end

  # Defense-in-depth: the validator blocks creation against a non-migration row, but this
  # guards rows whose purpose flipped post-create or stale-cache reconciliation edges.
  def self.custom_hostname_still_active?(source, normalized_host)
    ch = CustomHostname.redis_find_by(:hostname, normalized_host)
    return false unless ch&.project_id == source.project_id
    ch.migration? && ch.resolvable?
  end
end
