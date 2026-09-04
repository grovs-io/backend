# frozen_string_literal: true

module Analytics
  # PG miss = visitor merged away; returns {visitor_id => [uuid, resolved_visitor_id]}, [nil, nil] if unresolvable.
  module VisitorUuidResolver
    def self.resolve_many(project_id, visitor_ids)
      ids = visitor_ids.map(&:to_i).select(&:positive?).uniq
      return {} if ids.empty?

      uuids = Visitor.where(project_id: project_id, id: ids).pluck(:id, :uuid).to_h
      hits, misses = ids.partition { |id| uuids.key?(id) }
      result = hits.index_with { |id| [uuids[id], id] }
      return result if misses.empty?

      survivors = ClickhouseIdentityMapService.resolve_many(project_id, misses)
      survivor_ids = misses.filter_map { |id| survivors[id] unless survivors[id] == id }.uniq
      survivor_uuids =
        survivor_ids.any? ? Visitor.where(project_id: project_id, id: survivor_ids).pluck(:id, :uuid).to_h : {}
      misses.each do |id|
        uuid = survivor_uuids[survivors[id]]
        result[id] = uuid ? [uuid, survivors[id]] : [nil, nil]
      end
      result
    end
  end
end
