# frozen_string_literal: true

require "spec_helper"
require "open3"
require "rbconfig"

RSpec.describe Phronomy::Testing::Eval::Scorer::LlmJudge, "client composition" do
  def score(judge)
    judge.score(actual: "actual", expected: "expected", input: "question")
  end

  def adapter(value, calls: [])
    instance = Object.new
    instance.define_singleton_method(:complete) do |request, **_options|
      calls << [request, Thread.current]
      Phronomy::LLMAdapter::Response.new(content: value)
    end
    instance
  end

  def isolated_ruby(source)
    root = File.expand_path("../..", __dir__)
    stdout, stderr, status = Open3.capture3(RbConfig.ruby, "-I", File.join(root, "lib"), "-e", source)
    expect(status.success?).to be(true), "#{stdout}\n#{stderr}"
  end

  after { Phronomy.reset_configuration! }

  it "keeps construction lazy and preserves the initializer signature" do
    RSpec::Mocks.with_temporary_scope do
      expect(Phronomy).not_to receive(:configuration)
      expect(Phronomy::LLMAdapter::AsyncClient).not_to receive(:new)
      described_class.new(model: "test")
    end
    expect(described_class.instance_method(:initialize).parameters).to eq([
      [:keyreq, :model], [:key, :provider], [:key, :assume_model_exists],
      [:key, :prompt_template], [:key, :raise_on_error]
    ])
  end

  it "reads the current adapter for every score, including scoped restoration and reset" do
    first = adapter("0.2")
    second = adapter("0.8")
    third = adapter("0.6")
    Phronomy.configure { |c| c.llm_adapter = first }
    judge = described_class.new(model: "test")
    expect(score(judge)).to eq(0.2)
    Phronomy.with_configuration do |c|
      c.llm_adapter = second
      expect(score(judge)).to eq(0.8)
    end
    expect(score(judge)).to eq(0.2)
    Phronomy.reset_configuration!
    Phronomy.configure { |c| c.llm_adapter = third }
    expect(score(judge)).to eq(0.6)
  end

  it "keeps request preparation and backend execution on their existing sides of submission" do
    calls = []
    instance = adapter("score: 0.75", calls: calls)
    Phronomy.configure { |c| c.llm_adapter = instance }
    caller_thread = Thread.current
    observed = []
    allow(Phronomy::LLMAdapter::Request).to receive(:new).and_wrap_original do |original, **args|
      observed << :request
      original.call(**args)
    end
    allow(Phronomy::LLMAdapter::AsyncClient).to receive(:new).and_wrap_original do |original, **args|
      observed << :client
      expect(Thread.current).to equal(caller_thread)
      original.call(**args)
    end
    judge = described_class.new(model: "test", provider: :custom, assume_model_exists: true,
      prompt_template: "%<input>s / %<expected>s / %<actual>s")
    expect(score(judge)).to eq(0.75)
    request, worker = calls.fetch(0)
    expect(request.message).to eq("question / expected / actual")
    expect(request.model_config).to eq("model" => "test", "provider" => "custom", "assume_model_exists" => true)
    expect(worker).not_to equal(caller_thread)
    expect(observed).to eq([:request, :client])
  end

  [false, true].each do |raise_on_error|
    it "preserves client construction failures when raise_on_error is #{raise_on_error}" do
      error = RuntimeError.new("client unavailable")
      allow(Phronomy::LLMAdapter::AsyncClient).to receive(:new).and_raise(error)
      judge = described_class.new(model: "test", raise_on_error: raise_on_error)
      if raise_on_error
        expect { score(judge) }.to raise_error { |raised| expect(raised).to equal(error) }
      else
        expect(judge).to receive(:warn).with("[LlmJudge] Scoring failed: client unavailable")
        expect(score(judge)).to eq(0.0)
      end
    end
  end

  it "does not acquire a client after prompt preparation fails" do
    expect(Phronomy::LLMAdapter::AsyncClient).not_to receive(:new)
    judge = described_class.new(model: "test", prompt_template: "%<missing>s", raise_on_error: true)
    expect { score(judge) }.to raise_error(KeyError)
  end

  it "preserves parsing and clamping without retaining a client between scores" do
    responses = ["1.5", "-0.25", "no number"]
    client_ids = []
    instance = Object.new
    instance.define_singleton_method(:complete) { |*_args, **_kwargs| Phronomy::LLMAdapter::Response.new(content: responses.shift) }
    Phronomy.configure { |c| c.llm_adapter = instance }
    allow(Phronomy::LLMAdapter::AsyncClient).to receive(:new).and_wrap_original do |original, **args|
      original.call(**args).tap { |client| client_ids << client }
    end
    judge = described_class.new(model: "test")
    expect(3.times.map { score(judge) }).to eq([1.0, 0.0, 0.0])
    expect(client_ids.map(&:object_id).uniq.size).to eq(3)
  end

  it "supports inherited scoring through the same boot binding" do
    Phronomy.configure { |c| c.llm_adapter = adapter("0.4") }
    expect(score(Class.new(described_class).new(model: "test"))).to eq(0.4)
  end

  it "can score through a supplied client without loading application composition or Execution" do
    isolated_ruby(<<~RUBY)
      require "phronomy/common/values/immutable"
      require "phronomy/llm_adapter/request"
      require "phronomy/testing/eval/scorer/base"
      require "phronomy/testing/eval/scorer/llm_judge"
      klass = Phronomy::Testing::Eval::Scorer::LlmJudge
      calls = 0
      client = Object.new
      client.define_singleton_method(:complete_async) do |request|
        raise "invalid input" unless request.message.include?("actual")
        Struct.new(:wait_result).new(Struct.new(:content).new("0.3"))
      end
      klass.install_client_factory(-> { calls += 1; client })
      judge = klass.new(model: "test")
      abort "eager client acquisition" unless calls.zero?
      2.times { abort "wrong score" unless judge.score(actual: "actual", expected: "expected") == 0.3 }
      abort "factory cached" unless calls == 2
      begin
        klass.install_client_factory(-> { raise "replacement" })
        abort "boot binding replaced"
      rescue FrozenError
      end
      forbidden = $LOADED_FEATURES.grep(%r{/phronomy/(engine|execution|runtime_composition|llm_adapter/async)/})
      abort "loaded concrete dependencies" unless forbidden.empty?
    RUBY
  end

  it "binds defaults during normal and eager loading without creating configuration or Runtime" do
    isolated_ruby(<<~RUBY)
      require "phronomy"
      2.times { Zeitwerk::Loader.eager_load_all }
      Phronomy::Testing::Eval::Scorer::LlmJudge.new(model: "test")
      abort "configuration created" if Phronomy.instance_variable_get(:@configuration)
      abort "Runtime started" if Phronomy::Runtime.default_if_initialized_for_test
      abort "RSpec loaded" if defined?(RSpec)
    RUBY
  end
end
