# frozen_string_literal: true

# Coverage is a gate: 100% of lib/ on both lines and branches.
require "simplecov"
SimpleCov.start do
  enable_coverage :branch
  primary_coverage :branch
  add_filter "/spec/"
  minimum_coverage line: 100, branch: 100
end

require "edi_gem"
require_relative "support/canned_source"
require_relative "support/x12_fixtures"
require_relative "support/x12_answers"
require_relative "support/recording_archive"
require_relative "support/source_contract"

RSpec.configure do |config|
  config.include CannedSource
  config.include X12Fixtures
  config.include X12Answers

  # Enable flags like --only-failures and --next-failure
  config.example_status_persistence_file_path = ".rspec_status"

  # Disable RSpec exposing methods globally on `Module` and `main`
  config.disable_monkey_patching!

  config.expect_with :rspec do |c|
    c.syntax = :expect
  end
end
