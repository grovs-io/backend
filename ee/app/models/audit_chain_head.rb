class AuditChainHead < ApplicationRecord
  class NotInTransaction < StandardError; end

  # Row lock is what serialises concurrent audit writes on one instance (ADR 0001).
  def self.advance!(instance_id)
    raise NotInTransaction, "AuditChainHead.advance! needs an open transaction" unless connection.transaction_open?

    insert_all([{ instance_id: instance_id }], unique_by: :instance_id)
    head = lock.find_by!(instance_id: instance_id)
    head.update!(sequence: head.sequence + 1)
    head
  end
end
