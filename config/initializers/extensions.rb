extensions_path = ENV["GROVS_EXTENSIONS_PATH"]
if extensions_path.present?
  init_dir = File.join(extensions_path, "initializers")
  if Dir.exist?(init_dir)
    Dir[File.join(init_dir, "*.rb")].sort.each do |f|
      Rails.logger.info "[extensions] Loading #{f}"
      load f
    end
  end
end
