# frozen_string_literal: true

require "spec_helper"
require "rantly/rspec_extensions"

RSpec.describe "Workflow graph build-time property-based tests" do
  # A minimal context class used for all workflow definitions in this file.
  let(:ctx) do
    Class.new do
      include Phronomy::WorkflowContext

      field :n, type: :replace, default: 0
    end
  end

  # P1: Any transition to: an undeclared state always raises ArgumentError at define time.
  it "transition to: an undeclared state always raises ArgumentError" do
    property_of {
      # Large numeric suffix prevents collision with any declared state name.
      :"missing_#{range(10_000, 99_999)}"
    }.check(50) do |undeclared|
      expect {
        Phronomy::Workflow.define(ctx) do
          initial :step
          state :step, action: ->(s) { s }
          transition from: :step, to: undeclared
        end
      }.to raise_error(ArgumentError, /undefined state.*#{undeclared}/i)
    end
  end

  # P2: Any transition from: an undeclared state always raises ArgumentError at define time.
  it "transition from: an undeclared state always raises ArgumentError" do
    property_of {
      :"ghost_#{range(10_000, 99_999)}"
    }.check(50) do |undeclared|
      expect {
        Phronomy::Workflow.define(ctx) do
          initial :step
          state :step, action: ->(s) { s }
          transition from: undeclared, to: :__finish__
        end
      }.to raise_error(ArgumentError, /undefined state.*#{undeclared}/i)
    end
  end

  # P3: Any unreachable state always triggers a warning containing its name.
  it "an unreachable state always produces a warning to stderr" do
    property_of {
      :"orphan_#{range(1, 9999)}"
    }.check(50) do |orphan|
      expect {
        Phronomy::Workflow.define(ctx) do
          initial :step
          state :step, action: ->(s) { s }
          transition from: :step, to: :__finish__
          state orphan, action: ->(s) { s }
        end
      }.to output(/unreachable state.*#{orphan}/i).to_stderr
    end
  end

  # P4: A fully connected linear chain of N states produces no warnings.
  it "a reachable linear chain of states produces no warnings" do
    property_of { range(1, 6) }.check(30) do |n|
      states = (1..n).map { |i| :"chain_#{i}" }

      expect {
        the_ctx = ctx
        Phronomy::Workflow.define(the_ctx) do
          initial states.first
          states.each { |name| state name, action: ->(s) { s } }
          states.each_cons(2) { |from, to_st| transition from: from, to: to_st }
          transition from: states.last, to: :__finish__
        end
      }.not_to output.to_stderr
    end
  end
end
