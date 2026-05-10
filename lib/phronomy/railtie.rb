# frozen_string_literal: true

module Phronomy
  # Railtie providing Rails integration for Phronomy.
  # Loaded only when Rails is present.
  class Railtie < ::Rails::Railtie
    # Registers generator paths (rails generate phronomy:install).
    generators do
      require "generators/phronomy/install/install_generator"
    end

    # Fills in defaults not already set by a phronomy.rb initializer.
    initializer "phronomy.configure_defaults" do
      # Passes LLM API keys from Rails credentials to RubyLLM (only when present).
      # Use ::Rails to avoid resolving to Phronomy::Rails by accident.
      if ::Rails.application.credentials.respond_to?(:openai_api_key) &&
          ::Rails.application.credentials.openai_api_key
        RubyLLM.configure do |c|
          c.openai_api_key = ::Rails.application.credentials.openai_api_key
        end
      end

      if ::Rails.application.credentials.respond_to?(:anthropic_api_key) &&
          ::Rails.application.credentials.anthropic_api_key
        RubyLLM.configure do |c|
          c.anthropic_api_key = ::Rails.application.credentials.anthropic_api_key
        end
      end
    end

    # Loads Phronomy::Rails::AgentJob when both ActionCable and ActiveJob are present.
    initializer "phronomy.agent_job" do
      if defined?(::ActionCable) && defined?(::ActiveJob)
        require "phronomy/rails/agent_job"
      end
    end

    # Loads Phronomy ActiveRecord extensions when ActiveRecord is available.
    initializer "phronomy.active_record", after: "active_record.initialize_database" do
      ActiveSupport.on_load(:active_record) do
        require "phronomy/active_record/extensions" if defined?(::ActiveRecord)
      end
    end
  end
end
