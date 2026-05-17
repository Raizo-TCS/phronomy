# frozen_string_literal: true

require "spec_helper"

RSpec.describe Phronomy::Guardrail::Builtin::PIIPatternDetector do
  subject(:detector) { described_class.new }

  describe ".new" do
    it "accepts a subset of categories" do
      expect { described_class.new(detect: [:email]) }.not_to raise_error
    end

    it "raises ArgumentError for unknown categories" do
      expect { described_class.new(detect: [:unknown_category]) }
        .to raise_error(ArgumentError, /Unknown PII categories/)
    end
  end

  describe "#check — clean inputs" do
    it "passes a normal sentence" do
      expect { detector.run!("Please summarise the quarterly results.") }.not_to raise_error
    end

    it "passes an empty string" do
      expect { detector.run!("") }.not_to raise_error
    end
  end

  describe "#check — SSN" do
    it "raises for a hyphenated SSN" do
      expect { detector.run!("SSN: 123-45-6789") }
        .to raise_error(Phronomy::GuardrailError, /SSN/)
    end

    it "raises for an SSN embedded in a sentence" do
      expect { detector.run!("My social security number is 987-65-4321.") }
        .to raise_error(Phronomy::GuardrailError, /SSN/)
    end

    it "does not raise for a non-hyphenated 9-digit string" do
      expect { detector.run!("ID 123456789") }.not_to raise_error
    end
  end

  describe "#check — credit card" do
    it "raises for a 16-digit credit card (no separators)" do
      expect { detector.run!("card 4111111111111111") }
        .to raise_error(Phronomy::GuardrailError, /credit card number/)
    end

    it "raises for a credit card with spaces" do
      expect { detector.run!("4111 1111 1111 1111") }
        .to raise_error(Phronomy::GuardrailError, /credit card number/)
    end

    it "raises for a credit card with hyphens" do
      expect { detector.run!("4111-1111-1111-1111") }
        .to raise_error(Phronomy::GuardrailError, /credit card number/)
    end
  end

  describe "#check — email" do
    it "raises for a plain email address" do
      expect { detector.run!("reach me at user@example.com") }
        .to raise_error(Phronomy::GuardrailError, /email address/)
    end

    it "raises for an email with subdomain" do
      expect { detector.run!("user@mail.example.co.jp") }
        .to raise_error(Phronomy::GuardrailError, /email address/)
    end
  end

  describe "#check — phone" do
    it "raises for a 10-digit number with hyphens" do
      expect { detector.run!("call 555-123-4567") }
        .to raise_error(Phronomy::GuardrailError, /phone number/)
    end

    it "raises for a number with parenthesised area code" do
      expect { detector.run!("reach me at (555) 123-4567") }
        .to raise_error(Phronomy::GuardrailError, /phone number/)
    end

    it "raises for an international number with E.164 country code" do
      expect { detector.run!("+1 555 123 4567") }
        .to raise_error(Phronomy::GuardrailError, /phone number/)
    end
  end

  describe "category filtering" do
    subject(:email_only) { described_class.new(detect: [:email]) }

    it "does not raise for a credit card when only :email is active" do
      expect { email_only.run!("card 4111 1111 1111 1111") }.not_to raise_error
    end

    it "raises for an email when :email is active" do
      expect { email_only.run!("user@example.com") }
        .to raise_error(Phronomy::GuardrailError, /email address/)
    end
  end

  describe "non-String value" do
    it "coerces to string via to_s and passes for non-matching objects" do
      expect { detector.run!(12345) }.not_to raise_error
    end
  end
end
