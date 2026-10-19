# frozen_string_literal: true

require_relative "lib/edi_gem/version"

Gem::Specification.new do |spec|
  spec.name = "edi_gem"
  spec.version = EdiGem::VERSION
  spec.authors = ["Danny Sperry"]
  spec.email = ["danny.sperry@gmail.com"]

  spec.summary = "One Ruby API for healthcare eligibility checks across clearinghouses."
  spec.description = "Sends eligibility checks, insurance discovery and batch checks to " \
                     "healthcare clearinghouses and reads the answers into one set of Ruby " \
                     "objects. Ships a Stedi source and X12 270/271 sources for others."
  spec.homepage = "https://github.com/givesafe/edi-gem"
  spec.required_ruby_version = ">= 3.1.0"

  # Private gem with no gem server: the reserved .invalid host makes an accidental push fail.
  spec.metadata["allowed_push_host"] = "https://gems.invalid"
  spec.metadata["homepage_uri"] = spec.homepage
  spec.metadata["source_code_uri"] = spec.homepage
  spec.metadata["rubygems_mfa_required"] = "true"

  gemspec = File.basename(__FILE__)
  spec.files = IO.popen(%w[git ls-files -z], chdir: __dir__, err: IO::NULL) do |ls|
    ls.readlines("\x0", chomp: true).reject do |f|
      (f == gemspec) ||
        f.start_with?(*%w[bin/ test/ spec/ features/ .git appveyor Gemfile])
    end
  end
  spec.bindir = "exe"
  spec.executables = spec.files.grep(%r{\Aexe/}) { |f| File.basename(f) }
  spec.require_paths = ["lib"]
end
