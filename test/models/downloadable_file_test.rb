require "test_helper"

class DownloadableFileTest < ActiveSupport::TestCase
  fixtures :downloadable_files

  # === file_resource ===

  test "file_resource returns nil when no file attached" do
    df = downloadable_files(:csv_export)
    AssetService.stub(:permanent_url, nil) do
      assert_nil df.file_resource
    end
  end

  test "file_resource delegates to AssetService.permanent_url" do
    df = downloadable_files(:csv_export)
    expected_url = "https://cdn.example.com/files/test.csv"
    AssetService.stub(:permanent_url, expected_url) do
      assert_equal expected_url, df.file_resource
    end
  end

  # === serialization ===

  test "serializer includes file key from file_resource" do
    df = downloadable_files(:csv_export)
    expected_url = "https://cdn.example.com/files/test.csv"
    AssetService.stub(:permanent_url, expected_url) do
      json = DownloadableFileSerializer.serialize(df)
      assert_equal expected_url, json["file"]
    end
  end

  test "serializer excludes created_at" do
    df = downloadable_files(:csv_export)
    AssetService.stub(:permanent_url, nil) do
      json = DownloadableFileSerializer.serialize(df)
      assert_nil json["created_at"]
    end
  end

  test "serializer includes name and id" do
    df = downloadable_files(:csv_export)
    AssetService.stub(:permanent_url, nil) do
      json = DownloadableFileSerializer.serialize(df)
      assert_equal "test-export", json["name"]
      assert json.key?("id")
    end
  end

  # === create_csv_file_with_expiration ===

  test "create_csv_file_with_expiration creates a downloadable file with attachment" do
    DeleteFileJob.stub(:perform_in, true) do
      df = DownloadableFile.create_csv_file_with_expiration(
        content: "col1,col2\nval1,val2",
        filename: "test-export-csv"
      )
      assert df.persisted?
      assert_equal "test-export-csv", df.name
      assert df.file.attached?
      assert_equal "test-export-csv.csv", df.file.filename.to_s
    end
  end
end
