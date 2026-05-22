# frozen_string_literal: true

require "spec_helper"

RSpec.describe Phronomy::Agent::Base do
  describe ".max_parallel_tools DSL validation (issue #152)" do
    it "accepts a positive integer" do
      klass = Class.new(Phronomy::Agent::Base) { max_parallel_tools 4 }
      expect(klass.max_parallel_tools).to eq(4)
    end

    it "accepts 1 (minimum valid value)" do
      klass = Class.new(Phronomy::Agent::Base) { max_parallel_tools 1 }
      expect(klass.max_parallel_tools).to eq(1)
    end

    it "raises ArgumentError for 0" do
      expect { Class.new(Phronomy::Agent::Base) { max_parallel_tools 0 } }
        .to raise_error(ArgumentError, /max_parallel_tools/)
    end

    it "raises ArgumentError for a negative integer" do
      expect { Class.new(Phronomy::Agent::Base) { max_parallel_tools(-1) } }
        .to raise_error(ArgumentError, /max_parallel_tools/)
    end

    it "raises ArgumentError for a float" do
      expect { Class.new(Phronomy::Agent::Base) { max_parallel_tools 2.5 } }
        .to raise_error(ArgumentError, /max_parallel_tools/)
    end

    it "raises ArgumentError for a string" do
      expect { Class.new(Phronomy::Agent::Base) { max_parallel_tools "4" } }
        .to raise_error(ArgumentError, /max_parallel_tools/)
    end

    it "returns the default (10) when not set" do
      klass = Class.new(Phronomy::Agent::Base)
      expect(klass.max_parallel_tools).to eq(10)
    end
  end

  describe ".invoke_timeout DSL validation (issue #152)" do
    it "accepts a positive integer" do
      klass = Class.new(Phronomy::Agent::Base) { invoke_timeout 30 }
      expect(klass.invoke_timeout).to eq(30)
    end

    it "accepts a positive float" do
      klass = Class.new(Phronomy::Agent::Base) { invoke_timeout 0.5 }
      expect(klass.invoke_timeout).to eq(0.5)
    end

    it "raises ArgumentError for 0" do
      expect { Class.new(Phronomy::Agent::Base) { invoke_timeout 0 } }
        .to raise_error(ArgumentError, /invoke_timeout/)
    end

    it "raises ArgumentError for a negative number" do
      expect { Class.new(Phronomy::Agent::Base) { invoke_timeout(-5) } }
        .to raise_error(ArgumentError, /invoke_timeout/)
    end

    it "raises ArgumentError for a string" do
      expect { Class.new(Phronomy::Agent::Base) { invoke_timeout "30" } }
        .to raise_error(ArgumentError, /invoke_timeout/)
    end

    it "returns nil (no timeout) when not set" do
      klass = Class.new(Phronomy::Agent::Base)
      expect(klass.invoke_timeout).to be_nil
    end
  end
end
