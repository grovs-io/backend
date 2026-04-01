require "test_helper"

class DownloadableFileSerializerTest < ActiveSupport::TestCase
  fixtures :downloadable_files

  # ---------------------------------------------------------------------------
  # 1. VALUE VERIFICATION
  # ---------------------------------------------------------------------------

  test "serializes all declared attributes with correct values" do
    df = downloadable_files(:csv_export)
    result = DownloadableFileSerializer.serialize(df)

    assert_equal df.id, result["id"]
    assert_equal "test-export", result["name"]
    assert_includes result.keys, "updated_at"
  end

  test "serializes computed file field from file_resource method" do
    df = downloadable_files(:csv_export)
    result = DownloadableFileSerializer.serialize(df)

    assert_nil result["file"]
  end

  # ---------------------------------------------------------------------------
  # 2. EXCLUSION
  # ---------------------------------------------------------------------------

  test "excludes created_at" do
    result = DownloadableFileSerializer.serialize(downloadable_files(:csv_export))

    assert_not_includes result.keys, "created_at"
  end

  # ---------------------------------------------------------------------------
  # 3. NIL HANDLING
  # ---------------------------------------------------------------------------

  test "returns nil for nil input" do
    assert_nil DownloadableFileSerializer.serialize(nil)
  end

  # ---------------------------------------------------------------------------
  # 4. COLLECTION HANDLING
  # ---------------------------------------------------------------------------

  test "serializes a collection with correct size and values" do
    files = [downloadable_files(:csv_export)]
    results = DownloadableFileSerializer.serialize(files)

    assert_equal 1, results.size
    assert_equal downloadable_files(:csv_export).id, results.first["id"]
    assert_equal "test-export", results.first["name"]
    assert_includes results.first.keys, "updated_at"
    assert_nil results.first["file"]
  end

  # ---------------------------------------------------------------------------
  # 5. EDGE CASES -- computed field variations
  # ---------------------------------------------------------------------------

  test "file is nil when no file is attached" do
    df = downloadable_files(:csv_export)
    result = DownloadableFileSerializer.serialize(df)

    # csv_export fixture has no file attachment; file_resource returns nil
    assert_nil result["file"]
  end

  test "includes file key in output even when value is nil" do
    df = downloadable_files(:csv_export)
    result = DownloadableFileSerializer.serialize(df)

    assert_includes result.keys, "file"
  end
end
