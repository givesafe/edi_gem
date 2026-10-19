# frozen_string_literal: true

require "yaml"

module EdiGem
  # YAML loading that refuses a duplicate key, which plain YAML resolves silently by letting the
  # last one win.
  module StrictYaml
    def self.load_file(path)
      document = YAML.parse_file(path)
      refuse_duplicate_keys(document, path)
      document.to_ruby
    end

    def self.refuse_duplicate_keys(node, path)
      repeated = repeated_keys(node)
      raise InvalidPolicy, "#{path} declares #{repeated.join(", ")} more than once" if repeated.any?

      node.children&.each { |child| refuse_duplicate_keys(child, path) }
    end

    def self.repeated_keys(node)
      return [] unless node.is_a?(Psych::Nodes::Mapping)

      node.children.each_slice(2)
          .filter_map { |key, _| key.value if key.respond_to?(:value) }
          .tally.select { |_, count| count > 1 }.keys
    end
    private_class_method :refuse_duplicate_keys, :repeated_keys
  end
end
