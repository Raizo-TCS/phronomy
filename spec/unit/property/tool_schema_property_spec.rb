# frozen_string_literal: true

require "spec_helper"
require "rantly/rspec_extensions"

RSpec.describe "Phronomy::Agent::Context::Capability::Base schema property-based tests" do
  # P1: Omitting any required parameter always returns an error that names the param.
  it "calling with a missing required param returns an error naming the param" do
    property_of {
      sized(4) { string(:alpha) }
    }.check do |param_name|
      tool = Class.new(Phronomy::Agent::Context::Capability::Base) do
        description "test"
        define_method(:execute) { |**_kwargs| "ok" }
      end
      tool.param(param_name.to_sym, type: :string, desc: "x", required: true)

      result = tool.new.call({})
      expect(result).to include(param_name)
    end
  end

  # P2: With on_schema_error :raise, any undeclared parameter key always raises ToolError.
  it "on_schema_error :raise raises ToolError for any undeclared param key" do
    property_of {
      # Prefix ensures the generated key never collides with :declared_param.
      "extra_" + sized(4) { string(:alpha) }
    }.check do |bad_key|
      tool = Class.new(Phronomy::Agent::Context::Capability::Base) do
        description "test"
        on_schema_error :raise
        param :declared_param, type: :string, desc: "x"
        define_method(:execute) { |declared_param:| declared_param }
      end

      expect { tool.new.call({"declared_param" => "ok", bad_key => "v"}) }
        .to raise_error(Phronomy::ToolError, /unknown parameter/)
    end
  end

  # P3: Calling with all declared parameters always passes validation successfully.
  it "calling with all declared params never returns a schema error" do
    property_of {
      n = range(1, 4)
      names = array(n) { "p" + sized(3) { string(:lower) } }.uniq
      names
    }.check do |param_names|
      next if param_names.empty?

      tool = Class.new(Phronomy::Agent::Context::Capability::Base) do
        description "test"
        define_method(:execute) { |**_kwargs| "ok" }
      end
      param_names.each { |n| tool.param(n.to_sym, type: :string, desc: n) }

      args = param_names.to_h { |n| [n, "value"] }
      result = tool.new.call(args)
      expect(result).to eq("ok")
    end
  end

  # P4: Calling with a value drawn from the declared enum always passes validation.
  it "a valid enum value always passes enum validation" do
    property_of {
      vals = array(range(2, 4)) { sized(4) { string(:lower) } }.uniq
      choice = vals.sample
      [vals, choice]
    }.check do |(vals, choice)|
      next if vals.nil? || choice.nil?

      tool = Class.new(Phronomy::Agent::Context::Capability::Base) do
        description "enum test"
        define_method(:execute) { |lang:| lang }
      end
      tool.param(:lang, type: :string, desc: "lang", enum: vals)

      result = tool.new.call({"lang" => choice})
      expect(result).to eq(choice)
    end
  end

  # P5: Calling with a value outside the declared enum always returns an error message.
  it "an invalid enum value always returns a schema error message" do
    property_of {
      vals = ["en", "ja", "fr"]
      # Guaranteed not to be in vals.
      bad = "xx_" + sized(3) { string(:lower) }
      [vals, bad]
    }.check do |(vals, bad)|
      tool = Class.new(Phronomy::Agent::Context::Capability::Base) do
        description "enum test"
        on_schema_error :return_error
        define_method(:execute) { |lang:| lang }
      end
      tool.param(:lang, type: :string, desc: "lang", enum: vals)

      result = tool.new.call({"lang" => bad})
      expect(result).to include("must be one of")
    end
  end
end
