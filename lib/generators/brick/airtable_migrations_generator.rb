# frozen_string_literal: true

require 'brick'
require 'rails/generators'
require 'rails/generators/active_record'
require 'fancy_gets'
require 'generators/brick/migrations_builder'
require 'generators/brick/airtable_api_caller'

module Brick
  # Auto-generates Airtable migration files
  class AirtableMigrationsGenerator < ::Rails::Generators::Base
    desc 'Auto-generates migration files for an existing Airtable "base".'

    def airtable_migrations
      mig_path, is_insert_versions, is_delete_versions = ::Brick::MigrationsBuilder.check_folder
      return unless mig_path &&
                    (relations = ::Brick::AirtableApiCaller.pick_tables)

      ::Brick::MigrationsBuilder.generate_migrations(relations.keys, mig_path, is_insert_versions, is_delete_versions, relations,
                                                     do_fks_last: 'Separate', do_schema_migrations: false)
    end
  end
end
