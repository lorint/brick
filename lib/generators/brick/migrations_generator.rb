# frozen_string_literal: true

require 'rails/generators'
require 'rails/generators/active_record'
require 'fancy_gets'
require 'generators/brick/migration_builder'

module Brick
  # Auto-generates migration files
  class MigrationsGenerator < ::Rails::Generators::Base
    include FancyGets
    include ::Brick::MigrationBuilder

    desc 'Auto-generates migration files for an existing database.'

    def brick_migrations
      # If Apartment is active, see if a default schema to analyse is indicated

      ::Brick.mode = :on
      ActiveRecord::Base.establish_connection

      if (tables = ::Brick.relations.reject { |k, v| v.key?(:isView) && v[:isView] == true }.map(&:first).sort).empty?
        puts "No tables found in database #{ActiveRecord::Base.connection.current_database}."
        return
      end

      mig_path, is_insert_versions, is_delete_versions = ::Brick::MigrationBuilder.check_folder

      # Generate a list of tables that can be chosen
      chosen = gets_list(list: tables, chosen: tables.dup)

      ::Brick::MigrationBuilder.generate_migrations(chosen, mig_path, is_insert_versions, is_delete_versions)
    end
  end
end
