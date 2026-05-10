# frozen_string_literal: true

require_relative "builtin/prompt_injection_detector"
require_relative "builtin/pii_pattern_detector"

module Phronomy
  module Guardrail
    # Namespace for built-in guardrail implementations shipped with phronomy.
    #
    # Available classes:
    # - {Phronomy::Guardrail::Builtin::PromptInjectionDetector}
    # - {Phronomy::Guardrail::Builtin::PIIPatternDetector}
    module Builtin
    end
  end
end
