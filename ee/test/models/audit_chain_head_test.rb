require "test_helper"

class AuditChainHeadTest < ActiveSupport::TestCase
  fixtures :instances

  setup { @instance = instances(:one) }

  test "advance! creates the head row lazily and increments sequence" do
    head = ActiveRecord::Base.transaction { AuditChainHead.advance!(@instance.id) }
    assert_equal 1, head.sequence
    assert_nil head.head_hash

    head = ActiveRecord::Base.transaction { AuditChainHead.advance!(@instance.id) }
    assert_equal 2, head.sequence
  end
end
