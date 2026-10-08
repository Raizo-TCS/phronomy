# frozen_string_literal: true

# Select the existing default without constructing a parser during boot.
Phronomy::GeneratorVerifier::DefaultParser.install_factory(
  -> { Phronomy::OutputParser::JsonParser.new }
)
