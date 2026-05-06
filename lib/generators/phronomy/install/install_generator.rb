# frozen_string_literal: true

require "rails/generators"
require "rails/generators/active_record"

module Phronomy
  module Generators
    # Rails generator that installs Phronomy into a Rails app.
    # Creates an initializer and two database migrations:
    #   - phronomy_checkpoints (graph state persistence)
    #   - phronomy_messages    (conversation history persistence)
    #
    # Usage:
    #   rails generate phronomy:install
    class InstallGenerator < ::Rails::Generators::Base
      include ::Rails::Generators::Migration

      source_root File.expand_path("templates", __dir__)

      desc "Creates a Phronomy initializer and database migrations."

      def self.next_migration_number(dirname)
        ::ActiveRecord::Generators::Base.next_migration_number(dirname)
      end

      def copy_initializer
        template "initializer.rb.tt", "config/initializers/phronomy.rb"
      end

      def create_checkpoint_migration
        migration_template(
          "create_phronomy_checkpoints.rb.tt",
          "db/migrate/create_phronomy_checkpoints.rb"
        )
      end

      def create_messages_migration
        migration_template(
          "create_phronomy_messages.rb.tt",
          "db/migrate/create_phronomy_messages.rb"
        )
      end

      def create_checkpoint_model
        template "checkpoint_model.rb.tt", "app/models/phronomy_checkpoint.rb"
      end

      def create_message_model
        template "message_model.rb.tt", "app/models/phronomy_message.rb"
      end
    end
  end
end
