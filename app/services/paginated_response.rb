class PaginatedResponse
  def initialize(collection, data: nil)
    @collection = collection
    @data = data || collection
  end

  def as_json(*)
    {
      data: @data,
      page: @collection.current_page,
      per_page: @collection.limit_value,
      total_pages: @collection.total_pages,
      total_entries: @collection.total_count
    }
  end
end
