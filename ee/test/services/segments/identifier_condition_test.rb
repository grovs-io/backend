require "test_helper"

class SegmentsIdentifierConditionTest < ActiveSupport::TestCase
  Env = Struct.new(:project_id, :cutoff_date, :now, :segment_id, :list_generation)
  ENV_ = Env.new(7, Date.new(2026, 1, 1), Time.utc(2026, 9, 17, 12), 5, "a" * 32)

  def build(raw)
    errors = []
    [Segments::IdentifierCondition.build({ "type" => "identifier" }.merge(raw), path: "c", errors: errors, cutoff_date: nil), errors]
  end

  test "is_set reads identified rows of the person map" do
    c, errors = build("op" => "is_set")
    assert_empty errors
    assert_equal "SELECT raw_id AS visitor_id, toUInt8(2) AS ci, toUInt64(1) AS n, '' AS s FROM vmap WHERE startsWith(person_key, 'i:')",
                 c.rows_sql(ENV_, 2)
    assert_equal "countIf(r.ci = 2) > 0", c.predicate(2)
    assert_not c.negative?
  end

  test "is_not_set is negative and described by its positive form" do
    c, = build("op" => "is_not_set")
    assert c.negative?
    assert_includes c.rows_sql(ENV_, 1), "startsWith(person_key, 'i:')"
  end

  test "is compares exactly, contains ignores case" do
    is, = build("op" => "is", "value" => ["Ana@x.io", "o'brien"])
    assert_includes is.rows_sql(ENV_, 1), "substring(person_key, 3) IN ('Ana@x.io', 'o\\'brien')"
    contains, = build("op" => "contains", "value" => "@X.io")
    assert_includes contains.rows_sql(ENV_, 1), "lower(substring(person_key, 3)) LIKE '%@x.io%'"
  end

  test "in_list joins the published generation of this segment" do
    c, errors = build("op" => "in_list")
    assert_empty errors
    sql = c.rows_sql(ENV_, 3)
    assert_includes sql, "substring(person_key, 3) IN (SELECT identifier FROM segment_identifier_entries " \
                          "WHERE project_id = 7 AND segment_id = 5 AND generation = '#{'a' * 32}')"
  end

  test "in_list without a saved segment and list is refused at compile time" do
    c, = build("op" => "in_list")
    assert_raises(Segments::InvalidDefinition) { c.rows_sql(Env.new(7, nil, Time.now.utc, nil, nil), 1) }
  end

  test "rejects an unknown op and a missing value, and round-trips" do
    _, e1 = build("op" => "regex", "value" => "x")
    _, e2 = build("op" => "is")
    assert_equal 1, e1.size
    assert_equal 1, e2.size
    c, = build("op" => "is", "value" => %w[b a])
    again, errors = build(c.to_h.except("type"))
    assert_empty errors
    assert_equal c.to_h, again.to_h
  end

  test "not_in_list is the negated form of in_list" do
    c, errors = build("op" => "not_in_list")
    assert_empty errors
    assert c.negative?
    assert_equal({ "type" => "identifier", "op" => "not_in_list" }, c.to_h)
    positive, = build("op" => "in_list")
    assert_not positive.negative?
    env = Struct.new(:project_id, :segment_id, :list_generation).new(7, 9, "a" * 32)
    assert_equal positive.rows_sql(env, 1), c.rows_sql(env, 1)
  end
end
