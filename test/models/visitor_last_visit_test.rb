require "test_helper"

class VisitorLastVisitTest < ActiveSupport::TestCase
  fixtures :visitors, :projects, :links, :devices, :instances, :domains, :redirect_configs

  setup do
    @visit = VisitorLastVisit.create!(
      project: projects(:one),
      visitor: visitors(:ios_visitor),
      link: links(:basic_link)
    )
  end

  teardown do
    VisitorLastVisit.delete_all
  end

  # === associations ===

  test "belongs to project and visitor" do
    assert_equal projects(:one), @visit.project
    assert_equal visitors(:ios_visitor), @visit.visitor
  end

  test "link is optional" do
    visit = VisitorLastVisit.create!(
      project: projects(:two),
      visitor: visitors(:android_visitor),
      link: nil
    )
    assert_nil visit.reload.link
  end

  # === uniqueness constraint (visitor_id scoped to project_id) ===

  test "rejects duplicate visitor within the same project at validation level" do
    duplicate = VisitorLastVisit.new(
      project: @visit.project,
      visitor: @visit.visitor,
      link: nil
    )
    assert_not duplicate.valid?
    assert_includes duplicate.errors[:visitor_id], "has already been taken"
  end

  test "enforces uniqueness at database level" do
    duplicate = VisitorLastVisit.new(
      project: @visit.project,
      visitor: @visit.visitor,
      link: nil
    )
    assert_raises(ActiveRecord::RecordNotUnique) do
      duplicate.save(validate: false)
    end
  end

  test "allows same visitor in a different project" do
    visit = VisitorLastVisit.new(
      project: projects(:two),
      visitor: visitors(:ios_visitor),
      link: nil
    )
    assert visit.valid?
    assert visit.save
  end

  # === update behavior ===

  test "link can be updated on existing record" do
    new_link = links(:second_link)
    @visit.update!(link: new_link)
    assert_equal new_link, @visit.reload.link
  end

  test "link can be cleared to nil" do
    assert_not_nil @visit.link
    @visit.update!(link: nil)
    assert_nil @visit.reload.link
  end
end
