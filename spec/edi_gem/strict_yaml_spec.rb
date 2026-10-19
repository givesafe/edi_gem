# frozen_string_literal: true

require "tmpdir"

RSpec.describe EdiGem::StrictYaml do
  def load(text)
    Dir.mktmpdir do |dir|
      path = File.join(dir, "sources.yml")
      File.write(path, text)
      described_class.load_file(path)
    end
  end

  it "reads a file that says each thing once" do
    expect(load("sources:\n  stedi:\n    timeout: 30\n")).to eq("sources" => { "stedi" => { "timeout" => 30 } })
  end

  # The shape that discarded the 409 rule: two `errors:` under one source, the second winning.
  it "refuses a key declared twice in the same mapping" do
    expect { load("stedi:\n  errors:\n    a: 1\n  errors:\n    b: 2\n") }
      .to raise_error(EdiGem::InvalidPolicy, /errors more than once/)
  end

  it "refuses a duplicate however deeply it is nested" do
    expect { load("a:\n  b:\n    c:\n      timeout: 1\n      timeout: 2\n") }
      .to raise_error(EdiGem::InvalidPolicy, /timeout/)
  end

  it "names the file, because the message is read far from the file" do
    expect { load("errors: 1\nerrors: 2\n") }.to raise_error(EdiGem::InvalidPolicy, /sources\.yml/)
  end

  it "allows the same key under different parents" do
    expect { load("a:\n  timeout: 1\nb:\n  timeout: 2\n") }.to_not raise_error
  end

  # The duplicate scan walks every node in the document, and most nodes are not mappings --
  # a sequence, a scalar, an alias. Reaching one is the ordinary case, not an edge.
  it "walks past nodes that cannot carry a duplicate key" do
    expect(load("sources:\n  - one\n  - two\n")).to eq("sources" => %w[one two])
  end

  # YAML allows a whole collection as a key. It carries no #value, and the duplicate scan has to
  # step over it rather than raise -- a config file is refused for saying something twice, never
  # for saying something unusual.
  it "steps over a key that is not a scalar" do
    expect(load("? [a, b]\n: mapped\n")).to eq(%w[a b] => "mapped")
  end
end
