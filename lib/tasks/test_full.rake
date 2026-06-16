# `rails test` only sweeps test/; ee/test needs these to stay visible.
namespace :test do
  desc "Run the Enterprise Edition suite (ee/test) with GROVS_EE=true"
  task :ee do
    abort "ee/ suite failed" unless system({ "GROVS_EE" => "true" }, "bin/rails", "test", "ee/test")
  end

  desc "Run the full suite: core (test/) plus Enterprise Edition (ee/test)"
  task :full do
    abort "full suite failed" unless system({ "GROVS_EE" => "true" }, "bin/rails", "test", "test", "ee/test")
  end
end
