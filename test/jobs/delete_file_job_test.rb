require "test_helper"

class DeleteFileJobTest < ActiveSupport::TestCase
  fixtures :downloadable_files

  setup do
    @job = DeleteFileJob.new
  end

  test "destroys existing downloadable file from database" do
    file = downloadable_files(:csv_export)

    assert_difference "DownloadableFile.count", -1 do
      @job.perform(file.id)
    end

    assert_nil DownloadableFile.find_by(id: file.id)
  end

  test "returns early for nonexistent file — no records affected" do
    assert_no_difference "DownloadableFile.count" do
      @job.perform(999999)
    end
  end
end
