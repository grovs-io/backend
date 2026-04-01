class DownloadableFile < ApplicationRecord
  has_one_attached :file

  # Static methods
  
  def self.create_csv_file_with_expiration(content:, filename:, expiration: 24.hours)
    download = DownloadableFile.new
    download.file.attach(
      io: StringIO.new(content),
      filename: "#{filename}.csv",
      content_type: "text/csv"
    )
    download.name = filename
    download.save!

    # Delete the file in 24 hours
    DeleteFileJob.perform_in(expiration, download.id)

    download
  end

  # Methods

  def file_resource 
    AssetService.permanent_url(file)
  end
end
