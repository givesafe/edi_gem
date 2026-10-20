# frozen_string_literal: true

require "yaml"

module EdiGem
  # One source's transport policy from data/sources.yml: timeouts, retries, throttling, and
  # which vendor failure means which Fault kind. Adding a source adds a block to that file.
  class Policy
    DATA_PATH = File.expand_path("data/sources.yml", __dir__)
    SECTIONS = %w[retry throttle errors].freeze
    STATUS_CLASS = /\A(\d)xx\z/

    class << self
      # `retry:` is the caller's own retry settings, merged over the source's (see #with). The
      # policy held for the source is never changed.
      def for(source, path: DATA_PATH, **overrides)
        found = all(path: path).fetch(source.to_sym) do
          raise UnknownSchema, "no policy for source #{source.inspect} in #{path}"
        end
        overrides.empty? ? found : found.with(**overrides)
      end

      def all(path: DATA_PATH)
        @all ||= {}
        @all[path] ||= load_file(path)
      end

      def reload
        @all = nil
      end

      def load_file(path)
        file = StrictYaml.load_file(path)
        defaults = file.fetch("defaults", {})
        file.fetch("sources", {}).to_h do |name, attrs|
          [name.to_sym, new(name, merge(defaults, attrs || {}))]
        end
      end

      # One level deep per section: a source overriding `throttle.per_second` keeps the default
      # burst, and overriding one status code keeps every other mapping.
      def merge(defaults, attrs)
        merged = defaults.merge(attrs)
        SECTIONS.each do |section|
          next unless defaults[section].is_a?(Hash) && attrs[section].is_a?(Hash)

          merged[section] = deep_merge(defaults[section], attrs[section])
        end
        merged
      end

      def deep_merge(base, over)
        base.merge(over) do |_key, old, new|
          old.is_a?(Hash) && new.is_a?(Hash) ? old.merge(new) : new
        end
      end

      # `merge` stays public for #for_operation.
      private :load_file, :deep_merge
    end

    attr_reader :name

    def initialize(name, attrs)
      @name = name.to_sym
      @attrs = attrs
    end

    def base_url = @attrs["base_url"]

    # This policy with an endpoint assigned at enrolment, which sources.yml cannot carry.
    def at(base_url)
      base_url.nil? ? self : self.class.new(@name, @attrs.merge("base_url" => base_url))
    end

    # This policy with the caller's settings over its own, key by key: `retry: { attempts: 5 }`
    # keeps the source's backoff. Takes the keys of the `retry` block in sources.yml, and
    # nothing else.
    def with(**overrides)
      self.class.new(@name, self.class.merge(@attrs, Override.sections(overrides)))
    end

    def path_for(key) = @attrs.dig("operations", key.to_s, "path")

    def operations = (@attrs["operations"] || {}).keys.map(&:to_sym)

    # The policy for one operation, with its overrides merged over the source's.
    def for_operation(key)
      overrides = @attrs.dig("operations", key.to_s)
      raise UnknownSchema, "#{@name} has no #{key} operation" if overrides.nil?

      self.class.new(@name, self.class.merge(@attrs, overrides.except("path")))
    end

    def timeout = @attrs.fetch("timeout", 30)

    def attempts = retry_config.fetch("attempts", 1)

    def retry_after_header = @attrs.dig("errors", "retry_after_header")

    def throttle_per_second = @attrs.dig("throttle", "per_second")

    # A source may narrow which retryable kinds it retries, never make a terminal kind retryable.
    def retry?(kind)
      return false unless Fault::KINDS.fetch(kind.to_sym, {})[:retryable]

      Array(retry_config["retry_on"]).map(&:to_sym).include?(kind.to_sym)
    end

    # Seconds to wait before attempt n (1-based), with jitter.
    def delay_before(attempt, random: Kernel)
      capped = [backoff_for(attempt), retry_config.fetch("max_delay", 20)].min
      capped * jitter_factor(random)
    end

    # The Fault kind for an HTTP status: exact code first, then its class ("4xx").
    def kind_for_status(status)
      table = @attrs.dig("errors", "status") || {}
      found = table[status.to_s] || table["#{status.to_s[0]}xx"]
      found&.to_sym
    end

    # The Fault kind for a raised exception, matched up its ancestry.
    def kind_for_exception(error)
      table = @attrs.dig("errors", "exceptions") || {}
      found = error.class.ancestors.filter_map { |klass| table[klass.name] }.first
      (found || :unexpected).to_sym
    end

    # Every error mapping this source carries, with whether each kind is retried.
    def error_table
      statuses = (@attrs.dig("errors", "status") || {})
                 .map { |status, kind| { trigger: "HTTP #{status}", kind: kind.to_sym } }
      exceptions = (@attrs.dig("errors", "exceptions") || {})
                   .map { |klass, kind| { trigger: klass, kind: kind.to_sym } }
      (statuses + exceptions).map do |row|
        row.merge(retried: retry?(row[:kind]),
                  description: Fault::KINDS.fetch(row[:kind])[:description])
      end
    end

    private

    def backoff_for(attempt)
      retry_config.fetch("backoff", 0.5) * (retry_config.fetch("multiplier", 2)**(attempt - 2))
    end

    def jitter_factor(random)
      spread = retry_config.fetch("jitter", 0).to_f
      1 + (((random.rand * 2) - 1) * spread)
    end

    def retry_config = @attrs["retry"] || {}
  end
end
