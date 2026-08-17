# frozen_string_literal: true

require "spec_helper"

RSpec.describe "Phronomy::Tool public authoring façade" do
  it "is the exact same Class as the existing Capability::Base" do
    expect(Phronomy::Tool::Base)
      .to equal(Phronomy::Agent::Context::Capability::Base)
  end

  it "supports the existing Tool DSL when subclassed through the façade" do
    tool_class = Class.new(Phronomy::Tool::Base) do
      desc "Echo a query"
      param :query, type: :string, desc: "Query"

      def execute(query:)
        query
      end
    end

    expect(tool_class.description).to eq("Echo a query")
    expect(tool_class.new.params_schema["properties"]).to have_key("query")
  end

  it "keeps built-in Tools in the same hierarchy" do
    expect(Phronomy::Tools::Agent < Phronomy::Tool::Base).to eq(true)
    expect(Phronomy::Tools::Mcp < Phronomy::Tool::Base).to eq(true)
    expect(Phronomy::Tools::VectorSearch < Phronomy::Tool::Base).to eq(true)
  end

  it "keeps the implementation Class name intentionally canonical" do
    expect(Phronomy::Tool::Base.name)
      .to eq("Phronomy::Agent::Context::Capability::Base")
  end
end
