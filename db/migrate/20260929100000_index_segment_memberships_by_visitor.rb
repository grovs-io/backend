class IndexSegmentMembershipsByVisitor < ActiveRecord::Migration[8.1]
  disable_ddl_transaction!

  # Refresh reads a segment's rows in visitor order; the shorter index made that a sort of the whole segment.
  def change
    add_index :segment_memberships, %i[project_id segment_key visitor_id], algorithm: :concurrently,
                                                                           name: "index_segment_memberships_on_project_key_visitor"
    remove_index :segment_memberships, column: %i[project_id segment_key], algorithm: :concurrently
  end
end
