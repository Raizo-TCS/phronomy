# frozen_string_literal: true

require "spec_helper"

RSpec.describe "Tool and Tracing settings ownership" do
  after do
    Phronomy::Tool::Settings.install_provider { Phronomy.configuration.__tool_settings }
    Phronomy::Tracing::Settings.install_provider { Phronomy.configuration.__tracing_settings }
  end

  it "lets Tool consume its supplied values without the application facade or neutral settings" do
    settings = Phronomy::Tool::Settings.new
    settings.max_result_size = 10
    Phronomy::Tool::Settings.install_provider { settings }
    tool = Class.new(Phronomy::Tool::Base) do
      def execute = "result"
    end.new
    RSpec::Mocks.with_temporary_scope do
      expect(Phronomy).not_to receive(:configuration)
      expect(Phronomy::RuntimeSettings).not_to receive(:current)
      expect(tool.call({})).to eq("result")
    end
  end

  it "does not resolve the Tool default when a class limit is specified" do
    tool = Class.new(Phronomy::Tool::Base) do
      max_result_size 10
      def execute = "result"
    end.new
    expect(Phronomy::Tool::Settings).not_to receive(:current)
    expect(tool.call({})).to eq("result")
  end

  it "lets Tracing and Context obtain a tracer without the application facade or neutral settings" do
    tracer = Phronomy::Tracing::NullTracer.new
    settings = Phronomy::Tracing::Settings.new(tracer: tracer)
    Phronomy::Tracing::Settings.install_provider { settings }
    RSpec::Mocks.with_temporary_scope do
      expect(Phronomy).not_to receive(:configuration)
      expect(Phronomy::RuntimeSettings).not_to receive(:current)
      expect(Phronomy::Tracing::Automatic.trace("automatic", input: "secret") { "result" }).to eq("result")
      expect(Phronomy::Tracing::Observation.trace("observed", input: "secret") { ["result", nil] }).to eq("result")
      expect(Phronomy::Context::Assembly.new).to be_a(Phronomy::Context::Assembly)
    end
  end

  it "does not resolve Tracing settings for explicit Context injection" do
    expect(Phronomy::Tracing::Settings).not_to receive(:current)
    expect(Phronomy::Context::Assembly.new(tracer: nil)).to be_a(Phronomy::Context::Assembly)
  end
end
