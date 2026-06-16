class CampaignSerializer < BaseSerializer
  attributes :id, :name, :archived, :created_at

  # Resolve has_links for the whole collection in one grouped query instead of
  # an .exists? per campaign. Single-record calls fall back to the inline query.
  def self.serialize(record_or_collection, **options)
    if record_or_collection.respond_to?(:map) && !options.key?(:has_links_by_id)
      ids = record_or_collection.map(&:id)
      options = options.merge(has_links_by_id: has_links_lookup(ids))
    end
    super
  end

  # { campaign_id => bool_or(active) }. Key present = at least one link exists;
  # value = whether any of them is active.
  def self.has_links_lookup(campaign_ids)
    return {} if campaign_ids.empty?

    Link.where(campaign_id: campaign_ids)
        .group(:campaign_id)
        .pluck(Arel.sql("campaign_id, bool_or(active)"))
        .to_h
  end

  def build(**options)
    h = super()
    lookup = options[:has_links_by_id]
    h["has_links"] =
      if lookup
        record.archived? ? lookup.key?(record.id) : lookup[record.id] == true
      else
        record.archived? ? record.links.exists? : record.links.active.exists?
      end
    h
  end
end
