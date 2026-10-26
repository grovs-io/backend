module EventStream
  # Envelope v1 is a public contract: adding keys is fine, renaming or removing is a new schema_version.
  class EnvelopeBuilder
    SCHEMA_VERSION = 1
    LinkRef = Struct.new(:path, :campaign_id)

    def initialize(project:, include_ip:)
      @project = project
      @include_ip = include_ip
    end

    def self.purchase_id(transaction_id, event_type, version_ts)
      Digest::MD5.hexdigest("purchase:#{transaction_id}:#{event_type}:#{version_ts}")
    end

    def build_events(rows)
      links = links_for(rows.map { |row| row["link_id"].to_i })
      rows.map { |row| event_envelope(row, links[row["link_id"].to_i]) }
    end

    def build_purchases(rows)
      links = links_for(rows.map { |row| row["link_id"].to_i })
      users = visitors_for(rows.map { |row| row["visitor_id"].to_i })
      rows.map { |row| purchase_envelope(row, links[row["link_id"].to_i], users[row["visitor_id"].to_i]) }
    end

    # [[:event | :purchase, row], ...] in, envelopes out in the same order; lookups stay batched per kind.
    def build_merged(tagged)
      events = build_events(tagged.select { |kind, _| kind == :event }.map(&:last)).each
      purchases = build_purchases(tagged.select { |kind, _| kind == :purchase }.map(&:last)).each
      tagged.map { |kind, _| kind == :event ? events.next : purchases.next }
    end

    private

    def event_envelope(row, link)
      type = row["event_type"].to_s
      props = hash_or_empty(row["properties"])
      {
        schema_version: SCHEMA_VERSION,
        id: row["event_id"].to_s,
        type: type,
        name: type == Grovs::Events::CUSTOM ? row["event_name"].presence : nil,
        occurred_at: iso(row["created_at"]),
        project: project_group,
        link: link_group(row, link),
        attribution: { link_visitor_id: visitor_hashid(row["link_visitor_id"]), inviter_id: visitor_hashid(row["inviter_id"]),
                       sdk_generated: row["sdk_generated"].to_i == 1 },
        device: device_group(row),
        user: { id: row["sdk_identifier"].presence, attributes: hash_or_empty(row["sdk_attributes"]) },
        geo: geo_group(row),
        session_id: row["session_id"].presence,
        screen: row["screen_name"].presence,
        engagement_time: row["engagement_time"].to_i,
        properties: props,
        caused_by: type == Grovs::Events::USER_REFERRED ? props["install_event_id"] : nil,
        purchase: nil
      }
    end

    def purchase_envelope(row, link, sdk_identifier)
      version = iso(row["created_at"])
      occurred = row["recorded_at"].to_s.start_with?("1970") ? row["purchase_date"] : row["recorded_at"]
      {
        schema_version: SCHEMA_VERSION,
        id: self.class.purchase_id(row["transaction_id"], row["event_type"], version),
        type: "purchase",
        name: row["event_type"].to_s,
        occurred_at: iso(occurred),
        project: project_group,
        link: link_group(row, link),
        attribution: { link_visitor_id: nil, inviter_id: nil, sdk_generated: false },
        device: { id: device_hashid(row["device_id"]), platform: row["platform"].presence },
        user: { id: sdk_identifier.presence, attributes: {} },
        geo: {},
        session_id: row["session_id"].presence,
        screen: nil,
        engagement_time: 0,
        properties: {},
        caused_by: nil,
        purchase: { transaction_id: row["transaction_id"], original_transaction_id: row["original_transaction_id"].presence,
                    product_id: row["product_id"], purchase_type: row["purchase_type"].presence, store: row["store_source"].presence,
                    quantity: row["quantity"].to_i, currency: row["currency"].presence, usd_price_cents: row["usd_price_cents"].to_i,
                    purchase_date: iso(row["purchase_date"]), version: version }
      }
    end

    def project_group = { id: @project.hashid, test: @project.test }

    def link_group(row, link)
      return nil if row["link_id"].to_i.zero?

      { id: row["link_id"].to_i, path: link&.path, campaign_id: row["campaign_id"].to_i.zero? ? link&.campaign_id : row["campaign_id"].to_i,
        source: row["tracking_source"].presence, medium: row["tracking_medium"].presence, campaign: row["tracking_campaign"].presence,
        ads_platform: row["ads_platform"].presence, tags: Array(row["link_tags"]) }
    end

    def device_group(row)
      { id: device_hashid(row["device_id"]), platform: row["platform"].presence, os: row["os"].presence, os_version: row["os_version"].presence,
        app_version: row["app_version"].presence, build: row["build"].presence, model: row["device_model"].presence,
        timezone: row["timezone"].presence, language: row["language"].presence }
    end

    def geo_group(row)
      g = { country: row["country"].presence }
      return g unless @include_ip

      g.merge(city: row["city"].presence, ip: row["ip"].presence)
    end

    def links_for(ids)
      ids = ids.reject(&:zero?).uniq
      return {} if ids.empty?

      # Project-scoped as defence in depth: these values go straight into a customer's feed.
      Link.joins(:domain).where(id: ids, domains: { project_id: @project.id })
          .pluck(:id, :path, :campaign_id).to_h { |id, path, cid| [id, LinkRef.new(path, cid)] }
    end

    def visitors_for(ids)
      ids = ids.reject(&:zero?).uniq
      return {} if ids.empty?

      Visitor.where(id: ids, project_id: @project.id).pluck(:id, :sdk_identifier).to_h
    end

    def device_hashid(id) = id.to_i.zero? ? nil : Device.encode_id(id.to_i)
    def visitor_hashid(id) = id.to_i.zero? ? nil : Visitor.encode_id(id.to_i)

    def iso(value)
      return nil if value.blank?

      Outbox.parse_ts(value).iso8601(3)
    end

    def hash_or_empty(value)
      return value if value.is_a?(Hash)
      return {} if value.blank?

      JSON.parse(value)
    rescue JSON::ParserError
      {}
    end
  end
end
