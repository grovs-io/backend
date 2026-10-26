# `rails test` only sweeps test/; ee/test needs these to stay visible.
# rubocop:disable Rails/RakeEnvironment -- each task shells out to a fresh process
namespace :test do
  desc "Run the Enterprise Edition suite (ee/test) with GROVS_EE=true"
  task :ee do
    abort "ee/ suite failed" unless system({ "GROVS_EE" => "true" }, "bin/rails", "test", "ee/test")
  end

  desc "Run the full suite: core (test/) plus Enterprise Edition (ee/test)"
  task :full do
    abort "full suite failed" unless system({ "GROVS_EE" => "true" }, "bin/rails", "test", "test", "ee/test")
  end

  desc "Run the concurrency suite serially with real commits; CONCURRENCY_SCALE multiplies the volume"
  task :concurrency do
    env = { "GROVS_EE" => "true", "CONCURRENCY" => "1", "PARALLEL_WORKERS" => "1" }
    abort "concurrency suite failed" unless system(env, "bin/rails", "test", "test/concurrency", "ee/test/concurrency")
  end
end
# rubocop:enable Rails/RakeEnvironment
