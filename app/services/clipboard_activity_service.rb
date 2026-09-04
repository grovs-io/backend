class ClipboardActivityService
  class << self
    def stamp(project)
      REDIS.with { |conn| conn.set(key(project.id), Time.current.to_i, ex: Grovs::Links::CLIPBOARD_VALIDITY.to_i) }
    rescue StandardError
      nil
    end

    def active?(project)
      REDIS.with { |conn| conn.exists?(key(project.id)) }
    rescue StandardError
      false
    end

    def clear(project)
      REDIS.with { |conn| conn.del(key(project.id)) }
    rescue StandardError
      nil
    end

    private

    def key(project_id)
      "clipboard:last_click:#{project_id}"
    end
  end
end
