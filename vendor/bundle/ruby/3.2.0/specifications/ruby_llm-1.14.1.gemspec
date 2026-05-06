# -*- encoding: utf-8 -*-
# stub: ruby_llm 1.14.1 ruby lib

Gem::Specification.new do |s|
  s.name = "ruby_llm".freeze
  s.version = "1.14.1"

  s.required_rubygems_version = Gem::Requirement.new(">= 0".freeze) if s.respond_to? :required_rubygems_version=
  s.metadata = { "bug_tracker_uri" => "https://github.com/crmne/ruby_llm/issues", "changelog_uri" => "https://github.com/crmne/ruby_llm/commits/main", "documentation_uri" => "https://rubyllm.com", "funding_uri" => "https://github.com/sponsors/crmne", "homepage_uri" => "https://rubyllm.com", "rubygems_mfa_required" => "true", "source_code_uri" => "https://github.com/crmne/ruby_llm" } if s.respond_to? :metadata=
  s.require_paths = ["lib".freeze]
  s.authors = ["Carmine Paolino".freeze]
  s.date = "1980-01-02"
  s.description = "One beautiful Ruby API for GPT, Claude, Gemini, and more. Easily build chatbots, AI agents, RAG applications, and content generators. Features chat (text, images, audio, PDFs), image generation, embeddings, tools (function calling), structured output, Rails integration, and streaming. Works with OpenAI, Anthropic, Google Gemini, AWS Bedrock, DeepSeek, Mistral, Ollama (local models), OpenRouter, Perplexity, GPUStack, and any OpenAI-compatible API. Minimal dependencies - just Faraday, Zeitwerk, and Marcel.".freeze
  s.email = ["carmine@paolino.me".freeze]
  s.homepage = "https://rubyllm.com".freeze
  s.licenses = ["MIT".freeze]
  s.post_install_message = "Upgrading from RubyLLM < 1.14.x? Check the upgrade guide for new features and migration instructions\n--> https://rubyllm.com/upgrading/\n".freeze
  s.required_ruby_version = Gem::Requirement.new(">= 3.1.3".freeze)
  s.rubygems_version = "3.4.20".freeze
  s.summary = "One beautiful Ruby API for GPT, Claude, Gemini, and more.".freeze

  s.installed_by_version = "3.4.20" if s.respond_to? :installed_by_version

  s.specification_version = 4

  s.add_runtime_dependency(%q<base64>.freeze, [">= 0"])
  s.add_runtime_dependency(%q<event_stream_parser>.freeze, ["~> 1"])
  s.add_runtime_dependency(%q<faraday>.freeze, [">= 1.10.0"])
  s.add_runtime_dependency(%q<faraday-multipart>.freeze, [">= 1"])
  s.add_runtime_dependency(%q<faraday-net_http>.freeze, [">= 1"])
  s.add_runtime_dependency(%q<faraday-retry>.freeze, [">= 1"])
  s.add_runtime_dependency(%q<marcel>.freeze, ["~> 1"])
  s.add_runtime_dependency(%q<ruby_llm-schema>.freeze, ["~> 0"])
  s.add_runtime_dependency(%q<zeitwerk>.freeze, ["~> 2"])
end
