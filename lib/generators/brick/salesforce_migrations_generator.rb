# frozen_string_literal: true

require 'brick'
require 'rails/generators'
require 'fancy_gets'
require 'generators/brick/migrations_builder'
require 'generators/brick/salesforce_schema'

module Brick
  # Auto-generates migration files
  class SalesforceMigrationsGenerator < ::Rails::Generators::Base
    include FancyGets
    desc 'Auto-generates migration files for a set of Salesforce tables and columns.'

    argument :wsdl_file, type: :string, default: ''

    def brick_salesforce_migrations
      ::Brick.apply_double_underscore_patch
      # ::Brick.mode = :on
      # ActiveRecord::Base.establish_connection

      # Runs at the end of parsing Salesforce WSDL, and uses the discovered tables and columns to create migrations
      relations = nil
      end_document_proc = lambda do |salesforce_tables|
        # p [:end_document]
        mig_path, is_insert_versions, is_delete_versions = ::Brick::MigrationsBuilder.check_folder
        return unless mig_path

        # Generate a list of tables that can be chosen
        table_names = salesforce_tables.keys
        chosen = gets_list(list: table_names, chosen: table_names.dup)

        soap_data_types = {
          'tns:ID' => 'string',
          'xsd:string' => 'string',
          'xsd:dateTime' => 'datetime',
          'xsd:boolean' => 'boolean',
          'xsd:double' => 'float',
          'xsd:int' => 'integer',
          'xsd:date' => 'date',
          'xsd:anyType' => 'string', # Don't fully know on this
          'xsd:long' => 'bigint',
          'xsd:base64Binary' => 'bytea',
          'xsd:time' => 'time'
        }
        fk_idx = 0
        # Build out a '::Brick.relations' hash that represents this Salesforce schema
        relations = chosen.each_with_object({}) do |tbl_name, s|
                      tbl = salesforce_tables[tbl_name]
                      # Build out columns and foreign keys
                      cols = { 'id'=>['string', nil, false, true] }
                      fks = {}
                      tbl[:cols].each do |col|
                        next if col[:name] == 'Id'

                        dt = soap_data_types[col[:data_type]] || 'string'
                        cols[col[:name]] = [dt, nil, col[:nillable], false]
                        if (ref_to = col[:fk_reference_to])
                          fk_hash = {
                            is_bt: true,
                            fk: col[:name],
                            assoc_name: "#{col[:name]}_bt",
                            inverse_table: ref_to
                          }
                          fks["fk_salesforce_#{fk_idx += 1}"] = fk_hash
                        end
                      end
                      # Put it all into a relation entry, named the same as the table
                      s[tbl_name] = {
                        pkey: { "#{tbl_name}_pkey" => ['id'] },
                        cols: cols,
                        fks: fks
                      }
                    end
        # Build but do not have foreign keys established yet, and do not put version entries info the schema_migrations table
        ::Brick::MigrationsBuilder.generate_migrations(chosen, mig_path, is_insert_versions, is_delete_versions, relations,
                                                      do_fks_last: 'Separate', do_schema_migrations: false)
      end
      parser = Nokogiri::XML::SAX::Parser.new(::Brick::SalesforceSchema.new(end_document_proc))
      # The WSDL file must have a .xml extension, and can be in any folder in the project
      # Alternatively the user can supply this option on the command line
      @wsdl_file = nil if @wsdl_file == ''
      loop do
        break if (@wsdl_file ||= gets_list(Dir['**/*.xml'] + ['* Cancel *'])) == '* Cancel *'

        parser.parse(File.read(@wsdl_file))

        if relations.length > 300
          puts "A Salesforce installation generally has hundreds to a few thousand tables, and many are empty.
In order to more easily navigate just those tables that have content, you might want to add this
to brick.rb:
  ::Brick.omit_empty_tables_in_dropdown = true"
        end
        break
      rescue Errno::ENOENT
        puts "File \"#{@wsdl_file}\" is not found."
        @wsdl_file = nil
      end
    end
  end
end
