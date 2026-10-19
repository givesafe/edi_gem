# frozen_string_literal: true

require "bundler/gem_tasks"
require "rspec/core/rake_task"

RSpec::Core::RakeTask.new(:spec)

require "rubocop/rake_task"

RuboCop::RakeTask.new

desc "Run reek over lib"
task :reek do
  sh "bundle exec reek lib"
end

task default: %i[spec rubocop]
