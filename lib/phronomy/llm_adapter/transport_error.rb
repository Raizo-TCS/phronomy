# frozen_string_literal: true

require_relative "../common/error"

module Phronomy
  module LLMAdapter
    # A provider communication/generation failure. Optional reason code
    # "llm.provider_output_parse_failed" means the provider rejected its own
    # generated output format. It is not application JSON/schema validation,
    # does not imply a particular HTTP status, and does not authorize replay.
    class TransportError < Phronomy::Error; end
  end
end
