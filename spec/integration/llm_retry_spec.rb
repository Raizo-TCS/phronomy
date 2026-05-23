# frozen_string_literal: true

require_relative "spec_helper"
require_relative "support/factors"

# Group 22: LLM-Path Retry (retry_policy on Agent::Base via LLM call stubs)
#
# Factors: llm_error_type x agent_retry_times x agent_retry_wait
# Generated cases: 10
# Infeasible:
#   TC-007 (service_unavailable + zero + fixed): wait strategy is unobservable
#           when times=0; TC-004 already covers service_unavailable + zero.
#           SKIP: duplicate of TC-004 for the zero-retry path.
#
# All tests stub RubyLLM::Chat#ask to raise an LLM error for the first N calls,
# then return a fake response. This verifies that Agent::Base#retry_policy fires
# on real LLM call failures and that the agent recovers when retries are available.
#
# The sleep callable is replaced with a recording lambda so that no real
# delays occur and sleep durations can be asserted on.

RSpec.describe "Group 22: LLM-Path Retry", :integration do
  let(:sleep_log) { [] }

  # Stubs RubyLLM::Chat#ask to raise +error_class+ for the first +fail_times+
  # invocations, then return a fake success response.
  def stub_llm_ask(error_class:, fail_times:, success_content: "recovered")
    call_count = 0
    fake_response = IntegrationFactors.fake_llm_response(content: success_content)

    allow_any_instance_of(RubyLLM::Chat).to receive(:ask) do |_chat, _msg|
      call_count += 1
      raise error_class, "simulated LLM error ##{call_count}" if call_count <= fail_times
      fake_response
    end
  end

  # Also stub chat.with_instructions and chat.messages so that build_chat
  # works without a live LLM service.
  def stub_chat_setup
    allow_any_instance_of(RubyLLM::Chat).to receive(:with_instructions).and_return(nil)
    allow_any_instance_of(RubyLLM::Chat).to receive(:messages).and_return([])
  end

  # ---------------------------------------------------------------------------
  # TC-001: rate_limit + zero + exponential
  #         No retry — RateLimitError propagates immediately.
  # ---------------------------------------------------------------------------
  describe "TC-001: RateLimitError; times=0 — immediate propagation" do
    it "raises Phronomy::RateLimitError without any sleep" do
      stub_chat_setup
      stub_llm_ask(error_class: RubyLLM::RateLimitError, fail_times: 1)

      agent = IntegrationFactors.retry_agent(
        times: 0, wait: :exponential, sleep_log: sleep_log
      ).new

      expect { agent.invoke("hello") }.to raise_error(Phronomy::RateLimitError)
      expect(sleep_log).to be_empty
    end
  end

  # ---------------------------------------------------------------------------
  # TC-002: rate_limit + one + linear
  #         RateLimitError retried once; agent recovers on second attempt.
  # ---------------------------------------------------------------------------
  describe "TC-002: RateLimitError; times=1; linear wait — retry once and recover" do
    it "retries once with linear sleep and returns the recovered output" do
      stub_chat_setup
      stub_llm_ask(error_class: RubyLLM::RateLimitError, fail_times: 1)

      agent = IntegrationFactors.retry_agent(
        times: 1, wait: :linear, base: 1.0, sleep_log: sleep_log
      ).new

      result = agent.invoke("hello")
      expect(result[:output]).to eq("recovered")
      # attempt=0 → (0+1)*1.0 = 1.0
      expect(sleep_log).to eq([1.0])
    end

    it "raises after exhausting the single retry" do
      stub_chat_setup
      stub_llm_ask(error_class: RubyLLM::RateLimitError, fail_times: 2)

      agent = IntegrationFactors.retry_agent(
        times: 1, wait: :linear, base: 1.0, sleep_log: sleep_log
      ).new

      expect { agent.invoke("hello") }.to raise_error(Phronomy::RateLimitError)
      expect(sleep_log).to eq([1.0])
    end
  end

  # ---------------------------------------------------------------------------
  # TC-003: rate_limit + two + fixed
  #         RateLimitError retried twice with a fixed wait.
  # ---------------------------------------------------------------------------
  describe "TC-003: RateLimitError; times=2; fixed wait=0.5 — recover on 3rd attempt" do
    it "sleeps twice with the fixed duration and recovers" do
      stub_chat_setup
      stub_llm_ask(error_class: RubyLLM::RateLimitError, fail_times: 2)

      agent = IntegrationFactors.retry_agent(
        times: 2, wait: 0.5, sleep_log: sleep_log
      ).new

      result = agent.invoke("hello")
      expect(result[:output]).to eq("recovered")
      expect(sleep_log).to eq([0.5, 0.5])
    end

    it "re-raises after exhausting two retries" do
      stub_chat_setup
      stub_llm_ask(error_class: RubyLLM::RateLimitError, fail_times: 3)

      agent = IntegrationFactors.retry_agent(
        times: 2, wait: 0.5, sleep_log: sleep_log
      ).new

      expect { agent.invoke("hello") }.to raise_error(Phronomy::RateLimitError)
      expect(sleep_log).to eq([0.5, 0.5])
    end
  end

  # ---------------------------------------------------------------------------
  # TC-004: service_unavailable + zero + linear
  #         No retry — ServiceUnavailableError propagates immediately.
  # ---------------------------------------------------------------------------
  describe "TC-004: ServiceUnavailableError; times=0 — immediate propagation" do
    it "raises Phronomy::TransportError without any sleep" do
      stub_chat_setup
      stub_llm_ask(error_class: RubyLLM::ServiceUnavailableError, fail_times: 1)

      agent = IntegrationFactors.retry_agent(
        times: 0, wait: :linear, sleep_log: sleep_log
      ).new

      expect { agent.invoke("hello") }.to raise_error(Phronomy::TransportError)
      expect(sleep_log).to be_empty
    end
  end

  # ---------------------------------------------------------------------------
  # TC-005: service_unavailable + one + exponential
  #         ServiceUnavailableError retried once; exponential sleep.
  # ---------------------------------------------------------------------------
  describe "TC-005: ServiceUnavailableError; times=1; exponential — retry once" do
    it "retries once with exponential sleep and recovers" do
      stub_chat_setup
      stub_llm_ask(error_class: RubyLLM::ServiceUnavailableError, fail_times: 1)

      agent = IntegrationFactors.retry_agent(
        times: 1, wait: :exponential, base: 1.0, sleep_log: sleep_log
      ).new

      result = agent.invoke("hello")
      expect(result[:output]).to eq("recovered")
      # attempt=0 → 2^0 * 1.0 = 1.0
      expect(sleep_log).to eq([1.0])
    end
  end

  # ---------------------------------------------------------------------------
  # TC-006: service_unavailable + two + exponential
  #         ServiceUnavailableError; two retries; verify exponential schedule.
  # ---------------------------------------------------------------------------
  describe "TC-006: ServiceUnavailableError; times=2; exponential — full retry count" do
    it "sleeps with exponential durations and raises after two retries" do
      stub_chat_setup
      stub_llm_ask(error_class: RubyLLM::ServiceUnavailableError, fail_times: 3)

      agent = IntegrationFactors.retry_agent(
        times: 2, wait: :exponential, base: 1.0, sleep_log: sleep_log
      ).new

      expect { agent.invoke("hello") }.to raise_error(Phronomy::TransportError)
      # attempt=0 → 1.0, attempt=1 → 2.0
      expect(sleep_log).to eq([1.0, 2.0])
    end
  end

  # ---------------------------------------------------------------------------
  # TC-007: service_unavailable + zero + fixed — INFEASIBLE
  #         Wait strategy is unobservable when times=0; covered by TC-004.
  # ---------------------------------------------------------------------------
  it "TC-007: SKIP — wait strategy unobservable with times=0 (covered by TC-004)" do
    pending "SKIP: zero-retry path independent of wait strategy; see TC-004"
    raise "should be skipped"
  end

  # ---------------------------------------------------------------------------
  # TC-008: server_error + zero + exponential
  #         No retry — ServerError propagates immediately.
  # ---------------------------------------------------------------------------
  describe "TC-008: ServerError; times=0 — immediate propagation" do
    it "raises Phronomy::TransportError without any sleep" do
      stub_chat_setup
      stub_llm_ask(error_class: RubyLLM::ServerError, fail_times: 1)

      agent = IntegrationFactors.retry_agent(
        times: 0, wait: :exponential, sleep_log: sleep_log
      ).new

      expect { agent.invoke("hello") }.to raise_error(Phronomy::TransportError)
      expect(sleep_log).to be_empty
    end
  end

  # ---------------------------------------------------------------------------
  # TC-009: server_error + one + fixed
  #         ServerError retried once with a fixed wait.
  # ---------------------------------------------------------------------------
  describe "TC-009: ServerError; times=1; fixed wait=0.5 — retry once" do
    it "retries once with fixed sleep and recovers" do
      stub_chat_setup
      stub_llm_ask(error_class: RubyLLM::ServerError, fail_times: 1)

      agent = IntegrationFactors.retry_agent(
        times: 1, wait: 0.5, sleep_log: sleep_log
      ).new

      result = agent.invoke("hello")
      expect(result[:output]).to eq("recovered")
      expect(sleep_log).to eq([0.5])
    end
  end

  # ---------------------------------------------------------------------------
  # TC-010: server_error + two + linear
  #         ServerError; two retries; verify linear sleep schedule.
  # ---------------------------------------------------------------------------
  describe "TC-010: ServerError; times=2; linear — full retry count" do
    it "sleeps with linear durations and raises after two retries" do
      stub_chat_setup
      stub_llm_ask(error_class: RubyLLM::ServerError, fail_times: 3)

      agent = IntegrationFactors.retry_agent(
        times: 2, wait: :linear, base: 1.0, sleep_log: sleep_log
      ).new

      expect { agent.invoke("hello") }.to raise_error(Phronomy::TransportError)
      # attempt=0 → 1.0, attempt=1 → 2.0
      expect(sleep_log).to eq([1.0, 2.0])
    end
  end
end
