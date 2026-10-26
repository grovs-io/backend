class DownloadableFile < ApplicationRecord
  has_one_attached :file

  # Static methods
  
  def self.create_csv_file_with_expiration(content:, filename:, expiration: 24.hours)
    create_file_with_expiration(content: content, filename: "#{filename}.csv", content_type: "text/csv", expiration: expiration, name: filename)
  end

  def self.create_file_with_expiration(content:, filename:, content_type:, expiration: 24.hours, name: filename)
    download = DownloadableFile.new
    # content may be a String or an already-open IO (a large export is spooled to disk, never held in memory).
    download.file.attach(io: content.is_a?(String) ? StringIO.new(content) : content, filename: filename, content_type: content_type)
    download.name = name
    download.save!
    DeleteFileJob.perform_in(expiration, download.id)
    download
  end

  # Methods

  def file_resource 
    AssetService.permanent_url(file)
  end
end
