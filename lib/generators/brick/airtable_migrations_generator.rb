# frozen_string_literal: true

require 'brick'
require 'rails/generators'
require 'rails/generators/active_record'
require 'fancy_gets'
require 'generators/brick/migration_builder'
require 'generators/brick/airtable_api_caller'

module Brick
  # Auto-generates migration files
  class AirtableMigrationsGenerator < ::Rails::Generators::Base
    include ::Brick::MigrationBuilder

    desc 'Auto-generates migration files for an existing Airtable "base".'

    def airtable_migrations
      mig_path, is_insert_versions, is_delete_versions = ::Brick::MigrationBuilder.check_folder
      return unless mig_path &&
                    (chosen = ::Brick::AirtableApiCaller.pick_tables)

      # Build out a '::Brick.relations' hash that represents this Airtable schema
      fks = []
      associatives = {}
      relations = chosen.each_with_object({}) do |table, s|
                    tbl_name = table.name.downcase.tr(' ', '_') # salesforce_tables[tbl_name]
                    # Build out columns and foreign keys
                    cols = {}
                    table.fields.each do |col|
                      col_name = sane_name(col['name'])
                      # This is like a has_many or has_many through
                      if col['type'] == 'multipleRecordLinks'
                        binding.pry if col['options']['isReversed']
                        if (frn_tbl = chosen.find { |t| t.id == col['options']['linkedTableId'] }
                                            &.name&.downcase.tr(' ', '_'))
                          if col['options']['prefersSingleRecordLink'] # 1:M
                            fks << [frn_tbl, "#{col_name}_id", tbl_name]
                          else # N:M
                            # Queue up to build associative table with two foreign keys
                            camelized = (assoc_name = "#{tbl_name}_#{col_name}_#{frn_tbl}").camelize
                            if associatives.keys.any? { |a| a.camelize == camelized }
                              puts "Strangely have found two columns in \"#{table.name}\" with a name similar to \"#{col_name}\".  Skipping this to avoid a conflict."
                              next

                            end
                            associatives[assoc_name] = [col_name, frn_tbl, tbl_name]
                          end
                        end
                      else
                        # puts col['type']
                        dt = case col['type']
                        when 'singleLineText', 'url', 'singleSelect'
                          'string'
                        when 'multilineText'
                          'text'
                        when 'number'
                          'decimal'
                        when 'checkbox'
                          'boolean'
                        when 'date'
                          'date'
                        # multipleSelects
                        when 'formula', 'count', 'rollup', 'multipleAttachments'
                          next
                        end
                        cols[col_name] = [dt, nil, true, false] # true is the col[:nillable]
                      end
                    end
                    # Put it all into a relation entry, named the same as the table
                    pkey = table.fields.find { |f| f['id'] == table.primary_key }['name']
                    s[tbl_name] = {
                      pkey: { "#{tbl_name}_pkey" => [sane_name(pkey)] },
                      cols: cols,
                      fks: {}
                    }
                  end
      associatives.each do |k, v|
        pri_pk_col = relations[v[1]][:pkey]&.first&.last&.first
        frn_pk_col = relations[v[2]][:pkey]&.first&.last&.first
        pri_fk_name = "#{v[1]}_id"
        frn_fk_name = "#{v[2]}_id"
        if frn_fk_name == pri_fk_name # Self-referencing N:M?
          frn_fk_name = "#{v[2]}_2_id"
        end
        relations[k] = {
          pkey: { "#{k}_pkey" => ['id'] },
          cols: { 'id' => ['integer', nil, false, false],
                  pri_fk_name => [relations[v[1]][:cols][pri_pk_col][0], nil, nil, false],
                  frn_fk_name => [relations[v[2]][:cols][frn_pk_col][0], nil, nil, false] }
        }
        fks << [v[2], pri_fk_name, k]
        fks << [v[1], frn_fk_name, k]
      end
      fk_idx = 0
      fks.each do |pri_tbl, fk_col, frn_tbl|
        # Confirm that this is a 1:M
        # Make a FK column
        pri_pk_col = relations[pri_tbl][:pkey].first.last.first
        binding.pry unless relations.key?(frn_tbl) && relations[pri_tbl][:cols][pri_pk_col]
        relations[frn_tbl][:cols][fk_col] = [relations[pri_tbl][:cols][pri_pk_col][0], nil, true, false]
        # And the actual relation
        frn_fks = ((relations[frn_tbl] ||= {})[:fks] ||= {})
        frn_fks["fk_airtable_#{fk_idx += 1}"] = {
          is_bt: true,
          fk: fk_col,
          assoc_name: "#{pri_tbl}_#{fk_idx}",
          inverse_table: pri_tbl
        }
      end
      # binding.pry
      # Build but do not have foreign keys established yet, and do not put version entries info the schema_migrations table
      ::Brick::MigrationBuilder.generate_migrations(relations.keys, mig_path, is_insert_versions, is_delete_versions, relations,
                                                    do_fks_last: 'Separate', do_schema_migrations: false)

      # records = https_get("https://api.airtable.com/v0/#{base.id}/#{table.id}", pat).fetch('records', nil)
      # end
    end

  private

    def sane_name(col_name)
      col_name.gsub('&', 'and').tr('()?', '').downcase.tr(': -', '_')
    end
  end
end
