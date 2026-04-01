require "test_helper"

class PaginatedResponseTest < ActiveSupport::TestCase
  FakePage = Struct.new(:items, :current_page, :limit_value, :total_pages, :total_count) do
    include Enumerable
    def each(&block) = items.each(&block)
  end

  test "as_json returns all pagination fields from the collection" do
    page = FakePage.new(%w[a b c], 2, 10, 5, 47)
    json = PaginatedResponse.new(page).as_json

    assert_equal page, json[:data]
    assert_equal 2,    json[:page]
    assert_equal 10,   json[:per_page]
    assert_equal 5,    json[:total_pages]
    assert_equal 47,   json[:total_entries]
  end

  test "custom data replaces collection in output but pagination still comes from collection" do
    page = FakePage.new(%w[raw1 raw2], 3, 20, 10, 200)
    custom = [{ id: 1, name: "transformed" }]
    json = PaginatedResponse.new(page, data: custom).as_json

    assert_equal custom, json[:data]
    assert_equal 3,      json[:page]
    assert_equal 200,    json[:total_entries]
  end
end
