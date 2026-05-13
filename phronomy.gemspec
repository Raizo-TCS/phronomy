# frozen_string_literal: true

require_relative "lib/phronomy/version"

Gem::Specification.new do |spec|
  spec.name = "phronomy"
  spec.version = Phronomy::VERSION
  spec.authors = ["Raizo T.C.S"]
  spec.email = ["raizo.tcs@gmail.com"]

  spec.summary = "Ruby AI Agent Framework for composable, stateful AI agent workflows"
  spec.description = "Phronomy provides Agent, Workflow, Memory, Tool, Guardrail, " \
                     "RAG, and Multi-agent capabilities for building AI agents " \
                     "in Ruby and Rails. Powered by RubyLLM for LLM abstraction."
  spec.homepage = "https://github.com/Raizo-TCS/phronomy"
  spec.license = "MIT"
  spec.required_ruby_version = ">= 3.2.0"
  spec.metadata["allowed_push_host"] = "https://rubygems.org"
  spec.metadata["homepage_uri"] = spec.homepage
  spec.metadata["source_code_uri"] = "https://github.com/Raizo-TCS/phronomy"
  spec.metadata["changelog_uri"] = "https://github.com/Raizo-TCS/phronomy/blob/main/CHANGELOG.md"
  spec.metadata["rubygems_mfa_required"] = "true"

  # Specify which files should be added to the gem when it is released.
  # The `git ls-files -z` loads the files in the RubyGem that have been added into git.
  gemspec = File.basename(__FILE__)
  spec.files = IO.popen(%w[git ls-files -z], chdir: __dir__, err: IO::NULL) do |ls|
    ls.readlines("\x0", chomp: true).reject do |f|
      (f == gemspec) ||
        f.start_with?(*%w[bin/ Gemfile .gitignore .rspec spec/ .github/ .standard.yml])
    end
  end
  spec.bindir = "exe"
  spec.executables = spec.files.grep(%r{\Aexe/}) { |f| File.basename(f) }
  spec.require_paths = ["lib"]

  # Required dependencies
  spec.add_dependency "ruby_llm", ">= 1.3"
  spec.add_dependency "zeitwerk", ">= 2.6"
  spec.add_dependency "state_machines", "~> 0.6"

  # For more information and examples about making a new gem, check out our
  # guide at: https://guides.rubygems.org/make-your-own-gem/
end
