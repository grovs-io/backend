class DeleteFileJob
  include Sidekiq::Job

  def perform(file_id)

    
    handle_file(file_id)
  rescue StandardError => e
    # Log and re-raise so Sidekiq retries (25 attempts, exponential backoff).
    # Previously errors were swallowed silently, losing failed deletes.
    Rails.logger.error("DeleteFileJob error for file #{file_id}: #{e.message}")
    raise
    
  end

  # Private methods
  private

  def handle_file(file_id)
    file = DownloadableFile.find_by(id: file_id)
    unless file
      return
    end

    file.destroy!
  end
end