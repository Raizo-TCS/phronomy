# frozen_string_literal: true

require "spec_helper"

RSpec.describe Phronomy::Agent::SavedContextReader do
  it "reads both historical RubyLLM 1 counters and RubyLLM 2 counters after persistence" do
    persistence = Phronomy::Persistence.in_memory
    agent = double(persistence: persistence)
    [
      {input_tokens: 10, output_tokens: 20, cached_tokens: 3, cache_creation_tokens: 4},
      RubyLLM::Tokens.new(input: 10, output: 20, cache_read: 3, cache_write: 4).to_h
    ].each do |payload|
      usage_ref = persistence.contents.put_json(payload.transform_keys(&:to_s))
      execution = double(working_records: [], llm_calls: [double(usage_ref: usage_ref)])
      _, usage = described_class.provider_output_and_usage(agent, execution)
      expect(usage).to have_attributes(input: 10, output: 20, cached: 3, cache_creation: 4)
    end
  end
end
