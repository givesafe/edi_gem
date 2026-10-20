# frozen_string_literal: true

# The contract every Source::Base subclass keeps. Include it with `it_behaves_like "a source"`
# in a group that defines `source` and `inquiry` (an Inquiry::Eligibility).
RSpec.shared_examples "a source" do
  it "names itself" do
    expect(source.class::NAME).to be_a(Symbol)
  end

  it "states its search options as lists of subscriber fields" do
    expect(source.search_options).to all(be_an(Array).and(all(be_a(Symbol))))
  end

  it "reports a true or false capability for every feature" do
    expect(source.capabilities.keys).to match_array(EdiGem::Source::Base::FEATURES)
    expect(source.capabilities.values).to all(be(true).or(be(false)))
  end

  it "answers supports? from its capabilities" do
    EdiGem::Source::Base::FEATURES.each do |feature|
      expect(source.supports?(feature)).to eq(source.capabilities.fetch(feature))
    end
  end

  it "refuses to answer supports? for an unknown feature" do
    expect { source.supports?(:claims) }.to raise_error(ArgumentError, /unknown feature/)
  end

  it "takes the contract's keywords on every feature method" do
    expected = { eligibility: %i[idempotency_key archive], discovery: %i[idempotency_key archive],
                 resolve: %i[archive], submit_batch: %i[name idempotency_key],
                 batch_checks: %i[page_token page_size archive] }
    expected.each do |name, keys|
      taken = source.method(name).parameters.filter_map { |kind, key| key if kind == :key }
      expect(taken).to include(*keys), "#{name} takes #{taken.inspect}"
    end
  end

  it "raises FeatureNotSupported for every feature it does not support" do
    calls = { eligibility: [-> { source.eligibility(inquiry) }],
              discovery: [-> { source.discovery(inquiry) }, -> { source.resolve("handle") }],
              batch: [-> { source.submit_batch([inquiry]) }, -> { source.batch_status("b") },
                      -> { source.batch_checks("b") }] }
    calls.reject { |feature, _| source.supports?(feature) }.each_value do |unsupported|
      unsupported.each { |call| expect(&call).to raise_error(EdiGem::FeatureNotSupported) }
    end
  end
end
