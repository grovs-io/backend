namespace :instances do
  desc "Replace encrypted api_key blobs with production project identifier"
  task fix_encrypted_api_keys: :environment do
    fixed = 0
    skipped = 0
    errors = []

    Instance.find_each do |instance|
      # Skip already plain-text api_keys (match the format from InstanceProvisioningService)
      unless instance.api_key&.start_with?("{")
        skipped += 1
        next
      end

      prod_project = instance.production
      unless prod_project&.identifier.present?
        errors << "Instance #{instance.id}: no production project or identifier"
        next
      end

      instance.update_columns(api_key: prod_project.identifier)
      fixed += 1
      puts "Fixed Instance #{instance.id}: api_key = #{prod_project.identifier}"
    end

    puts "\nDone. Fixed: #{fixed}, Skipped (already plain): #{skipped}, Errors: #{errors.size}"
    errors.each { |e| puts "  ERROR: #{e}" }
  end
end
