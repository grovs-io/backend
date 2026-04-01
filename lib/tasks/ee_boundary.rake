namespace :ee do
  desc "Verify core code does not reference ee/ classes without defined? guards"
  task boundary: :environment do
    ee_classes = Dir.glob(Rails.root.join("ee/app/**/*.rb")).map do |f|
      File.basename(f, ".rb").camelize
    end.uniq

    violations = []
    Dir.glob(Rails.root.join("app/**/*.rb")).each do |file|
      core_class = File.basename(file, ".rb").camelize
      lines = File.readlines(file)
      content = lines.join

      ee_classes.each do |klass|
        # Skip if the core file itself defines a class with the same short name
        next if core_class == klass

        # Only check non-comment lines for actual code references
        code_lines = lines.reject { |l| l.strip.start_with?("#") }
        code_content = code_lines.join
        next if code_content.scan(/\b#{klass}\b/).empty?

        next if content.include?("defined?(#{klass})")
        violations << "#{file} references #{klass} without defined? guard"
      end
    end

    if violations.any?
      violations.each { |v| puts "  VIOLATION: #{v}" }
      abort "Found #{violations.size} boundary violation(s)"
    else
      puts "No ee/ boundary violations found"
    end
  end
end
