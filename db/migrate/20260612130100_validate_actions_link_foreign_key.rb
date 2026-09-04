class ValidateActionsLinkForeignKey < ActiveRecord::Migration[8.1]
  # Separate from the add so the validation scan never blocks it; writes proceed
  def up
    validate_foreign_key :actions, :links
  end

  def down; end
end
