# frozen_string_literal: true

require 'rails/generators'
require 'rails/generators/active_record'
require 'fancy_gets'

module Brick
  # Auto-generates migration files
  class MigrationsGenerator < ::Rails::Generators::Base
    include FancyGets
    # include ::Rails::Generators::Migration

    # Many SQL types are the same as their migration data type name:
    #   text, integer, bigint, date, boolean, decimal, float
    # These however are not:
    SQL_TYPES = { 'character varying' => 'string',
                  'character' => 'string', # %%% Need to put in "limit: 1"
                  'xml' => 'text',
                  'bytea' => 'binary',
                  'timestamp without time zone' => 'timestamp',
                  'timestamp with time zone' => 'timestamp',
                  'time without time zone' => 'time',
                  'time with time zone' => 'time',
                  'double precision' => 'float', # might work with 'double'
                  'smallint' => 'integer' } # %%% Need to put in "limit: 2"
    # (Still need to find what "inet" and "json" data types map to.)

    desc 'Auto-generates migration files for an existing database.'

    def brick_migrations
      # If Apartment is active, see if a default schema to analyse is indicated

      # # Load all models
      # Rails.configuration.eager_load_namespaces.select { |ns| ns < Rails::Application }.each(&:eager_load!)

      if (tables = ::Brick.relations.reject { |k, v| v.key?(:isView) && v[:isView] == true }.map(&:first).sort).empty?
        puts "No tables found in database #{ActiveRecord::Base.connection.current_database}."
        return
      end

      is_4x_rails = ActiveRecord.version < ::Gem::Version.new('5.0')
      ar_version = "[#{ActiveRecord.version.segments[0..1].join('.')}]" unless is_4x_rails
      default_mig_path = (mig_path = ActiveRecord::Migrator.migrations_paths.first || "#{::Rails.root}/db/migrate")
      if Dir.exist?(mig_path)
        if Dir["#{mig_path}/**/*.rb"].present?
          puts "WARNING: migrations folder #{mig_path} appears to already have ruby files present."
          mig_path2 = "#{::Rails.root}/tmp/brick_migrations"
          if Dir.exist?(mig_path2)
            if Dir["#{mig_path2}/**/*.rb"].present?
              puts "As well, temporary folder #{mig_path2} also has ruby files present."
              puts "Choose a destination -- all existing .rb files will be removed:"
              mig_path2 = gets_list(list: ['Cancel operation!', "Append migration files into #{mig_path} anyway", mig_path, mig_path2])
              return if mig_path2.start_with?('Cancel')

              if mig_path2.start_with?('Append migration files into ')
                mig_path2 = mig_path
              else
                Dir["#{mig_path2}/**/*.rb"].each { |rb| File.delete(rb) }
              end
            else
              puts "Using temporary folder #{mig_path2} for created migration files.\n\n"
            end
          else
            puts "Creating the temporary folder #{mig_path2} for created migration files.\n\n"
            Dir.mkdir(mig_path2)
          end
          mig_path = mig_path2
        else
          puts "Using standard migration folder #{mig_path} for created migration files.\n\n"
        end
      else
        puts "Creating standard ActiveRecord migration folder #{mig_path} to hold new migration files.\n\n"
        Dir.mkdir(mig_path)
      end

      # Generate a list of tables that can be chosen
      chosen = gets_list(list: tables, chosen: tables.dup)
      # Start the timestamps back the same number of minutes from now as expected number of migrations to create
      current_mig_time = Time.now - chosen.length.minutes
      done = []
      fks = {}
      stuck = {}
      # Start by making migrations for fringe tables (those with no foreign keys).
      # Continue layer by layer, creating migrations for tables that reference ones already done, until
      # no more migrations can be created.  (At that point hopefully all tables are accounted for.)
      while (fringe = chosen.reject do |tbl|
                        snags = ::Brick.relations.fetch(tbl, nil)&.fetch(:fks, nil)&.select do |_k, v|
                          v[:is_bt] && !v[:polymorphic] &&
                          tbl != v[:inverse_table] && # Ignore self-referencing associations (stuff like "parent_id")
                          !done.include?(v[:inverse_table])
                        end
                        stuck[tbl] = snags if snags&.present?
                      end).present?
        fringe.each do |tbl|
          next unless (relation = ::Brick.relations.fetch(tbl, nil))&.fetch(:cols, nil)&.present?

          pkey_cols = ::Brick.relations[chosen.first][:pkey].values.flatten
          # %%% For the moment we're skipping polymorphics
          fkey_cols = relation[:fks].values.select { |assoc| assoc[:is_bt] && !assoc[:polymorphic] }
          mig = +"class Create#{table_name = tbl.camelize} < ActiveRecord::Migration#{ar_version}\n"
          # %%% Support missing foreign key (by adding:  ,id: false)
          # also bigint / uuid / other non-standard data type for primary key
          mig << "  def change\n    create_table :#{tbl} do |t|\n"
          possible_ts = [] # Track possible generic timestamps
          relation[:cols].each do |col, col_type|
            next if pkey_cols.include?(col)

            # See if there are generic timestamps
            if (sql_type = SQL_TYPES[col_type.first]) == 'timestamp' &&
               ['created_at','updated_at'].include?(col)
              possible_ts << col
              next
            end

            sql_type ||= col_type.first
            # Determine if this column is used as part of a foreign key
            if fk = fkey_cols.find { |assoc| col == assoc[:fk] }
              mig << "      t.references :#{fk[:assoc_name]}#{", type: #{sql_type}" unless sql_type == 'integer'}\n"
            else
              mig << emit_column(sql_type, col)
            end
          end
          if possible_ts.length == 2 # Both created_at and updated_at
            mig << "\n      t.timestamps\n"
          else # Just one or the other
            possible_ts.each { |ts| emit_column('timestamp', ts) }
          end
          mig << "    end\n  end\nend\n"
          current_mig_time += 1.minute
          File.open("#{mig_path}/#{current_mig_time.strftime('%Y%m%d%H%M00')}_create_#{tbl}.rb", "w") { |f| f.write mig }
        end
        done.concat(fringe)
        chosen -= done
      end
      stuck_counts = Hash.new { |h, k| h[k] = 0 }
      chosen.each do |leftover|
        puts "Can't do #{leftover} because:\n  #{stuck[leftover].map do |snag|
          stuck_counts[snag.last[:inverse_table]] += 1
          snag.last[:assoc_name]
        end.join(', ')}"
      end
      if mig_path.start_with?(cur_path = ::Rails.root.to_s)
        pretty_mig_path = mig_path[cur_path.length..-1]
      end
      puts "\n*** Created #{done.length} migration files under #{pretty_mig_path || mig_path} ***"
      if (stuck_sorted = stuck_counts.to_a.sort { |a, b| b.last <=> a.last }).length.positive?
        puts "-----------------------------------------"
        puts "Unable to create migrations for #{stuck_sorted.length} tables#{
          ".  Here's the top 5 blockers" if stuck_sorted.length > 5
        }:"
        pp stuck_sorted[0..4]
      end
    end

  private

    def emit_column(type, name)
      "      t.#{type.start_with?('numeric') ? 'decimal' : type} :#{name}\n"
    end
  end
end
