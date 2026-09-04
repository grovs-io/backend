# frozen_string_literal: true

require 'test_helper'

class ScreenAliasTest < ActiveSupport::TestCase
  fixtures :projects, :instances

  setup { @project = projects(:one) }

  test 'valid with project, identifier, and name' do
    assert ScreenAlias.new(project: @project, screen_identifier: 'home', alias_name: 'Home').valid?
  end

  test 'requires screen_identifier' do
    record = ScreenAlias.new(project: @project, alias_name: 'Home')
    assert_not record.valid?
    assert_includes record.errors[:screen_identifier], "can't be blank"
  end

  test 'requires alias_name' do
    record = ScreenAlias.new(project: @project, screen_identifier: 'home')
    assert_not record.valid?
    assert_includes record.errors[:alias_name], "can't be blank"
  end

  test 'requires a project' do
    record = ScreenAlias.new(screen_identifier: 'home', alias_name: 'Home')
    assert_not record.valid?
    assert_includes record.errors[:project], 'must exist'
  end

  test 'screen_identifier and alias_name are capped at 255 chars' do
    assert_not ScreenAlias.new(project: @project, screen_identifier: 'a' * 256, alias_name: 'x').valid?
    assert_not ScreenAlias.new(project: @project, screen_identifier: 'home', alias_name: 'a' * 256).valid?
  end
end
