require "test_helper"

class CampaignIdParamConcernTest < ActiveSupport::TestCase
  class FakeController
    include Api::V1::Concerns::CampaignIdParam

    attr_reader :params, :rendered

    def initialize(raw)
      @params = ActionController::Parameters.new(raw == :absent ? {} : { campaign_id: raw })
    end

    def render(options)
      @rendered = options
    end
  end

  def normalize(raw)
    FakeController.new(raw).send(:campaign_id_param)
  end

  def rejected?(raw)
    controller = FakeController.new(raw)
    controller.send(:validate_campaign_id!)
    controller.rendered.present?
  end

  test "accepts integers and decimal strings" do
    assert_equal 12, normalize(12)
    assert_equal 12, normalize("12")
    assert_equal 12, normalize("012")
    assert_equal 12, normalize(" 12 ")
  end

  test "treats nil and blank strings as absent" do
    [:absent, nil, "", "   "].each do |raw|
      assert_nil normalize(raw), "#{raw.inspect} must normalize to nil"
      assert_not rejected?(raw), "#{raw.inspect} must not be rejected"
    end
  end

  test "rejects non-scalar and boolean values instead of dropping the filter" do
    [false, true, [], {}, [1], { id: 1 }].each do |raw|
      assert_nil normalize(raw), "#{raw.inspect} must not yield a campaign id"
      assert rejected?(raw), "#{raw.inspect} must be rejected with 400"
    end
  end

  test "rejects malformed decimals" do
    ["1_0", "+1", "0d10", "-5", "12.5", "0x1f", "not_an_integer"].each do |raw|
      assert_nil normalize(raw), "#{raw.inspect} must not yield a campaign id"
      assert rejected?(raw), "#{raw.inspect} must be rejected with 400"
    end
  end
end
