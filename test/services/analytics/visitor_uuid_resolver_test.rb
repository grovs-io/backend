# frozen_string_literal: true

require 'test_helper'

class Analytics::VisitorUuidResolverTest < ActiveSupport::TestCase
  fixtures :instances, :projects, :devices, :visitors

  setup do
    @project = projects(:one)
    @visitor = visitors(:ios_visitor)
  end

  test 'resolves PG-present visitors without touching the identity map' do
    called = false
    fake = lambda { |*|
      called = true
      {}
    }
    ClickhouseIdentityMapService.stub(:resolve_many, fake) do
      result = Analytics::VisitorUuidResolver.resolve_many(@project.id, [@visitor.id, @visitor.id, 0, nil])
      assert_equal({ @visitor.id => [@visitor.uuid, @visitor.id] }, result)
    end
    assert_not called, 'identity map must not be queried when all ids resolve in PG'
  end

  test 'merged-away visitor resolves to survivor uuid via one batched identity-map call' do
    merged_id = 999_777
    calls = []
    fake = lambda { |pid, ids|
      calls << [pid, ids.sort]
      { merged_id => @visitor.id }
    }
    ClickhouseIdentityMapService.stub(:resolve_many, fake) do
      result = Analytics::VisitorUuidResolver.resolve_many(@project.id, [merged_id, @visitor.id])
      assert_equal [@visitor.uuid, @visitor.id], result[merged_id]
      assert_equal [@visitor.uuid, @visitor.id], result[@visitor.id]
    end
    assert_equal [[@project.id, [merged_id]]], calls, 'only PG misses go to the identity map, in one call'
  end

  test 'unmapped missing visitor yields nils' do
    ClickhouseIdentityMapService.stub(:resolve_many, ->(_pid, ids) { ids.index_with { |i| i } }) do
      result = Analytics::VisitorUuidResolver.resolve_many(@project.id, [999_778])
      assert_equal [nil, nil], result[999_778]
    end
  end

  test 'survivor from another project does not leak' do
    device = Device.create!(user_agent: 'x', ip: '10.1.1.2', remote_ip: '10.1.1.2',
                            platform: 'ios', vendor: "res-#{SecureRandom.hex(4)}")
    foreign = Visitor.create!(project: projects(:two), device: device, uuid: SecureRandom.uuid)
    ClickhouseIdentityMapService.stub(:resolve_many, ->(_pid, _ids) { { 999_779 => foreign.id } }) do
      result = Analytics::VisitorUuidResolver.resolve_many(@project.id, [999_779])
      assert_equal [nil, nil], result[999_779]
    end
  end

  test 'empty and non-positive input returns empty hash' do
    assert_equal({}, Analytics::VisitorUuidResolver.resolve_many(@project.id, []))
    assert_equal({}, Analytics::VisitorUuidResolver.resolve_many(@project.id, [0, nil, -3]))
  end
end
