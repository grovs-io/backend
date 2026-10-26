class Segment < ApplicationRecord
  include Hashid::Rails

  belongs_to :project
  belongs_to :created_by, class_name: "User", optional: true
  has_many :size_snapshots, class_name: "SegmentSizeSnapshot", dependent: :delete_all

  validates :name, presence: true, length: { maximum: 255 }
  validate :definition_must_parse, if: -> { new_record? || will_save_change_to_definition? }

  scope :active, -> { where(archived: false) }

  # No retention gate: a stored fixed window that ages past the cutoff stays valid, just incomplete.
  def parsed_definition
    Segments::Definition.parse(definition, cutoff_date: nil)
  end

  private

  def retention_cutoff
    Analytics::RetentionPolicy.for(project.instance).queryable_cutoff_date
  end

  def definition_must_parse
    return if project.nil?

    parsed = Segments::Definition.parse(definition, cutoff_date: retention_cutoff)
    if parsed.valid?
      if parsed.uses?("purchase") && !project.instance.revenue_collection_enabled
        errors.add(:definition, "purchase conditions need revenue collection to be enabled")
      end
      self.definition = parsed.canonical
      self.definition_hash = parsed.digest
    else
      parsed.errors.each { |e| errors.add(:definition, "#{e[:path]}: #{e[:message]}") }
    end
  end
end
