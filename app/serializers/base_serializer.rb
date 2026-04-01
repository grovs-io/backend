class BaseSerializer
  attr_reader :record

  def initialize(record)
    @record = record
  end

  def self.attributes(*attrs)
    @attributes = attrs.map(&:to_s)
  end

  def self.attribute_names
    @attributes || []
  end

  def self.serialize(record_or_collection, **options)
    return nil if record_or_collection.nil?
    if record_or_collection.respond_to?(:map)
      record_or_collection.map { |r| new(r).build(**options) }
    else
      new(record_or_collection).build(**options)
    end
  end

  def build(**_options)
    h = self.class.attribute_names.index_with do |attr|
      record.public_send(attr)
    end
    # Pass through extra SQL-selected attributes (e.g. aggregation columns like
    # total_views, invited_views) that exist on the AR record but are not part
    # of the model's physical columns or the serializer's declared attributes.
    if record.respond_to?(:attributes)
      declared = Set.new(self.class.attribute_names)
      model_columns = record.class.respond_to?(:column_names) ? Set.new(record.class.column_names) : Set.new
      record.attributes.each do |key, value|
        h[key] = value unless declared.include?(key) || model_columns.include?(key)
      end
    end
    h
  end
end
