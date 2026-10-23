# frozen_string_literal: true

source "https://rubygems.org"

gemspec

gem "irb"
gem "rake", "~> 13.0"

gem "rspec", "~> 3.0"

gem "rubocop", "~> 1.21"
gem "rubocop-rspec", "~> 3.10", require: false

# The suite fails under 100% line and branch coverage of lib/.
gem "simplecov", "~> 0.22", require: false

# Advisory design-smell checks: `rake reek`.
gem "reek", "~> 6.3", require: false
