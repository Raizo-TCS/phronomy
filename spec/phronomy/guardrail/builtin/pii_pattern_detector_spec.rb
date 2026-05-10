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

  describe "#check — My Number" do
    it "raises for a 12-digit My Number (no separators)" do
      expect { detector.run!("My number is 123456789012") }
        .to raise_error(Phronomy::GuardrailError, /My Number/)
    end

    it "raises for a My Number with hyphen groups (4-4-4)" do
      expect { detector.run!("ID: 1234-5678-9012") }
        .to raise_error(Phronomy::GuardrailError, /My Number/)
    end

    it "raises for a My Number with space groups (4 4 4)" do
      expect { detector.run!("ID: 1234 5678 9012") }
        .to raise_error(Phronomy::GuardrailError, /My Number/)
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
    it "raises for a Japanese landline (no separator)" do
      expect { detector.run!("call 0312345678") }
        .to raise_error(Phronomy::GuardrailError, /phone number/)
    end

    it "raises for a mobile number with hyphens" do
      expect { detector.run!("090-1234-5678") }
        .to raise_error(Phronomy::GuardrailError, /phone number/)
    end

    it "raises for a freephone number with spaces" do
      expect { detector.run!("0120 123 4567") }
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
