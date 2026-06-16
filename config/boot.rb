ENV['BUNDLE_GEMFILE'] ||= File.expand_path('../Gemfile', __dir__)

require "bundler/setup" # Set up gems listed in the Gemfile.
# Bootsnap's iseq cache bypasses coverage instrumentation, corrupting reports.
require "bootsnap/setup" unless ENV["COVERAGE"]
