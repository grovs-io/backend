class ValidateSmartBannersDefaultLinkForeignKey < ActiveRecord::Migration[8.1]
  # Separate from the add so the validation scan never blocks it; writes proceed
  def up
    validate_foreign_key :smart_banners, :links
  end

  def down; end
end
