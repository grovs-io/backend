class CampaignSerializer < BaseSerializer
  attributes :id, :name, :archived, :created_at

  # One short-circuiting EXISTS pair per campaign (bool_or/exists? per record
  # would scan every link row of large campaigns / N+1 respectively).
  def self.serialize(record_or_collection, **options)
    unless options.key?(:has_links_by_id)
      ids = Array.wrap(record_or_collection).map(&:id)
      options = options.merge(has_links_by_id: has_links_lookup(ids))
    end
    super
  end

  # { campaign_id => [has_any_link, has_active_link] }
  def self.has_links_lookup(campaign_ids)
    return {} if campaign_ids.empty?

    sql = ActiveRecord::Base.send(:sanitize_sql_array, [<<~SQL, campaign_ids])
      SELECT c.id,
             EXISTS (SELECT 1 FROM links l WHERE l.campaign_id = c.id) AS has_any,
             EXISTS (SELECT 1 FROM links l WHERE l.campaign_id = c.id AND l.active) AS has_active
      FROM unnest(ARRAY[?]::bigint[]) AS c(id)
    SQL
    # .rows returns uncast DB values: id as a String ("5"), EXISTS as "t"/"f".
    # Cast the key to Integer so it matches record.id, and the flags to real
    # booleans, otherwise the lookup in #build always misses (has_links => nil).
    bool = ActiveModel::Type::Boolean.new
    ActiveRecord::Base.connection.select_all(sql).rows.to_h do |id, any, active|
      [id.to_i, [bool.cast(any), bool.cast(active)]]
    end
  end

  def build(**options)
    h = super()
    has_any, has_active = options.fetch(:has_links_by_id) { self.class.has_links_lookup([record.id]) }[record.id]
    h["has_links"] = record.archived? ? has_any : has_active
    h
  end
end
