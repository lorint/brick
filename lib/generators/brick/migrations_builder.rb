# frozen_string_literal: true

module Brick
  module MigrationsBuilder
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
                  'double precision' => 'float',
                  'smallint' => 'integer', # %%% Need to put in "limit: 2"
                  'ARRAY' => 'string', # Note that we'll also add ", array: true"
                  # Oracle data types
                  'VARCHAR2' => 'string',
                  'CHAR' => 'string',
                  ['NUMBER', 22] => 'integer',
                  /^INTERVAL / => 'string', # Time interval stuff like INTERVAL YEAR(2) TO MONTH, INTERVAL '999' DAY(3), etc
                  'XMLTYPE' => 'xml',
                  'RAW' => 'binary',
                  'SDO_GEOMETRY' => 'geometry',
                  # MSSQL data types
                  'int' => 'integer',
                  'char' => 'string',
                  'varchar' => 'string',
                  'nvarchar' => 'string',
                  'nchar' => 'string',
                  'datetime2' => 'timestamp',
                  'bit' => 'boolean',
                  'varbinary' => 'binary',
                  'tinyint' => 'integer', # %%% Need to put in "limit: 2"
                  'year' => 'integer',
                  'set' => 'string',
                  # Sqlite data types
                  'TEXT' => 'text',
                  '' => 'string',
                  'INTEGER' => 'integer',
                  'REAL' => 'float',
                  'BLOB' => 'binary',
                  'TIMESTAMP' => 'timestamp',
                  'DATETIME' => 'timestamp'
                }
    # (Still need to find what "inet" and "json" data types map to.)

    class << self
      include FancyGets
      def check_folder(is_insert_versions = true, is_delete_versions = false)
        versions_to_delete_or_append = nil
        if Dir.exist?(mig_path = ActiveRecord::Migrator.migrations_paths.first || "#{::Rails.root}/db/migrate")
          if Dir["#{mig_path}/**/*.rb"].present?
            puts "WARNING: migrations folder #{mig_path} appears to already have ruby files present."
            mig_path2 = "#{::Rails.root}/tmp/brick_migrations"
            is_insert_versions = false unless mig_path == mig_path2
            if Dir.exist?(mig_path2)
              if Dir["#{mig_path2}/**/*.rb"].present?
                puts "As well, temporary folder #{mig_path2} also has ruby files present."
                puts "Choose a destination -- all existing .rb files will be removed:"
                mig_path2 = gets_list(list: ['Cancel operation!', "Append migration files into #{mig_path} anyway", mig_path, mig_path2])
                return if mig_path2.start_with?('Cancel')

                existing_mig_files = Dir["#{mig_path2}/**/*.rb"]
                if (is_insert_versions = mig_path == mig_path2)
                  versions_to_delete_or_append = existing_mig_files.map { |ver| ver.split('/').last.split('_').first }
                end
                if mig_path2.start_with?('Append migration files into ')
                  mig_path2 = mig_path
                else
                  is_delete_versions = true
                  existing_mig_files.each { |rb| File.delete(rb) }
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
        [mig_path, is_insert_versions, is_delete_versions]
      end

      def generate_migrations(chosen, mig_path, is_insert_versions, is_delete_versions,
                              relations = ::Brick.relations, do_fks_last: nil, do_schema_migrations: true)
        if do_fks_last.nil?
          puts 'Would you like for the foreign keys to be built inline inside of each migration file, or as a final migration?'
          options = ['Inline', 'Separate final migration for all FKs']
          options << 'Create "additional_references" entries in brick.rb that emulate foreign keys'
          do_fks = gets_list(list: options).split(' ').first
          do_fks_last = do_fks unless do_fks == 'Inline'
        end

        is_sqlite = ActiveRecord::Base.connection.adapter_name == 'SQLite'
        key_type = ((is_sqlite || ActiveRecord.version < ::Gem::Version.new('5.1')) ? 'integer' : 'bigint')
        is_4x_rails = ActiveRecord.version < ::Gem::Version.new('5.0')
        ar_version = "[#{ActiveRecord.version.segments[0..1].join('.')}]" unless is_4x_rails

        schemas = chosen.each_with_object({}) do |v, s|
          if (v_parts = v.split('.')).length > 1
            s[v_parts.first] = nil unless [::Brick.default_schema, 'public'].include?(v_parts.first)
          end
        end
        separator = ::Brick.config.salesforce_mode ? 'x' : nil
        # Start the timestamps back the same number of minutes from now as expected number of migrations to create
        current_mig_time = [Time.now - (schemas.length + chosen.length).minutes]
        done = []
        fks = {}
        stuck = {}
        indexes = {} # Track index names to make sure things are unique
        built_schemas = {} # Track all built schemas so we can place an appropriate drop_schema command only in the first
                          # migration in which that schema is referenced, thereby allowing rollbacks to function properly.
        versions_to_create = [] # Resulting versions to be used when updating the schema_migrations table
        # Start by making migrations for fringe tables (those with no foreign keys).
        # Continue layer by layer, creating migrations for tables that reference ones already done, until
        # no more migrations can be created.  (At that point hopefully all tables are accounted for.)
        after_fks = [] # Track foreign keys to add after table creation
        while (fringe = chosen.reject do |tbl|
                          snag_fks = []
                          snags = relations.fetch(tbl, nil)&.fetch(:fks, nil)&.select do |_k, v|
                            # Skip any foreign keys which should be deferred ...
                            !Brick.drfgs[tbl]&.any? do |drfg|
                              drfg[0] == v.fetch(:fk, nil) && drfg[1] == v.fetch(:inverse_table, nil)
                            end &&
                            v[:is_bt] && !v[:polymorphic] && # ... and polymorphics ...
                            tbl != v[:inverse_table] && # ... and self-referencing associations (stuff like "parent_id")
                            !done.include?(v[:inverse_table]) &&
                            ::Brick.config.ignore_migration_fks.exclude?(snag_fk = "#{tbl}.#{v[:fk]}") &&
                            snag_fks << snag_fk
                          end
                          if snags&.present?
                            # puts snag_fks.inspect
                            stuck[tbl] = snags
                          end
                        end
              ).present?
          fringe.each do |tbl|
            mig = gen_migration_columns(relations, tbl, (tbl_parts = tbl.split('.')), (add_fks = []), built_schemas, mig_path, current_mig_time,
                                        key_type, is_4x_rails, ar_version, do_fks_last, versions_to_create)
            after_fks.concat(add_fks) if do_fks_last
            current_mig_time[0] += 1.minute
            versions_to_create << migration_file_write(mig_path, "create_#{::Brick._brick_index(tbl, nil, separator, relations[tbl])}", current_mig_time, ar_version, mig)
          end
          done.concat(fringe)
          chosen -= done
        end

        if do_fks_last
          # Write out any more tables that haven't been done yet
          chosen.each do |tbl|
            mig = gen_migration_columns(relations, tbl, (tbl_parts = tbl.split('.')), (add_fks = []), built_schemas, mig_path, current_mig_time,
                                        key_type, is_4x_rails, ar_version, do_fks_last, versions_to_create)
            after_fks.concat(add_fks)
            current_mig_time[0] += 1.minute
            versions_to_create << migration_file_write(mig_path, "create_#{
              ::Brick._brick_index(tbl, :migration, separator, relations[tbl])
            }", current_mig_time, ar_version, mig)
          end
          done.concat(chosen)
          chosen.clear

          case do_fks_last
          when 'Separate' # Add a final migration to create all the foreign keys
            mig = +"  def change\n"
            after_fks.each do |add_fk|
              next unless add_fk[2] # add_fk[2] holds the inverse relation

              unless (pk = add_fk[2][:pkey].values.flatten&.first)
                # No official PK, but if coincidentally there's a column of the same name, take a chance on it
                pk = (add_fk[2][:cols].key?(add_fk[1]) && add_fk[1]) || '???'
              end
              mig << "    add_foreign_key #{add_fk[3]}, " # The tbl_code
              #         to_table               column
              mig << "#{add_fk[0]}, column: :#{add_fk[1]}, primary_key: :#{pk}\n"
            end
            # If there are LOTS of foreign keys then give extra database maintenance info and initially
            # disable the final FK migration by using a ".rbx" file extension.
            fks_extension = if after_fks.length > 500
              minutes = (after_fks.length + 1000) / 1500
              mig << "    if ActiveRecord::Base.connection.adapter_name == 'PostgreSQL'\n"
              mig << "      puts 'NOTE:  It could take around #{minutes} #{'minute'.pluralize(minutes)} on a FAST machine for Postgres to do all the final processing for these foreign keys.  Please be patient!'\n"

              mig << "      # Vacuum takes only about ten seconds when all the tables are empty,
      # and about 2 minutes when the tables are fairly full.
      execute('COMMIT')
      execute('VACUUM FULL')
      execute('BEGIN TRANSACTION')
    end\n"
              'rbx'
            else
              'rb'
            end
            mig << +"  end\n"
            current_mig_time[0] += 1.minute
            versions_to_create << migration_file_write(mig_path, "create_brick_fks.#{fks_extension}", current_mig_time, ar_version, mig)
            puts "Have written out a final migration called 'create_brick_fks.#{fks_extension}' which creates #{after_fks.length} foreign keys."
            if fks_extension == 'rbx'
              puts "  This file extension (.rbx) will cause it not to run yet when you do a 'rails db:migrate'.
  The idea here is to do all data loading first, and then rename that migration file back
  into having a .rb extension, and run a final db:migrate to put the foreign keys in place."
            end

          when 'Create' # Show additional_references entries that can be added into brick.rb
            puts 'Place this block into your brick.rb file:'
            puts '  ::Brick.additional_references = ['
            after_fks.each do |add_fk|
              next unless add_fk[2] # add_fk[2] holds the inverse relation

              unless (pk = add_fk[2][:pkey].values.flatten&.first)
                # No official PK, but if coincidentally there's a column of the same name, take a chance on it
                pk = (add_fk[2][:cols].key?(add_fk[1]) && add_fk[1]) || '???'
              end
              from_table = add_fk[3]
              from_table = "'#{from_table[1..-1]}'" if from_table[0] == ':'
              to_table = add_fk[0]
              to_table = "'#{to_table[1..-1]}'" if to_table[0] == ':'
              puts "    [#{from_table}, #{add_fk[1].inspect}, #{to_table}],"
            end
            puts '  ]'
          end
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
        elsif do_schema_migrations # Successful, and now we can update the schema_migrations table accordingly
          unless ActiveRecord::Migration.table_exists?(ActiveRecord::Base.schema_migrations_table_name)
            ActiveRecord::SchemaMigration.create_table
          end
          # Remove to_delete - to_create
          if ((versions_to_delete_or_append ||= []) - versions_to_create).present? && is_delete_versions
            ActiveRecord::Base.execute_sql("DELETE FROM #{
              ActiveRecord::Base.schema_migrations_table_name} WHERE version IN (#{
              (versions_to_delete_or_append - versions_to_create).map { |vtd| "'#{vtd}'" }.join(', ')}
            )")
          end
          # Add to_create - to_delete
          if is_insert_versions && ((versions_to_create ||= []) - versions_to_delete_or_append).present?
            ActiveRecord::Base.execute_sql("INSERT INTO #{
              ActiveRecord::Base.schema_migrations_table_name} (version) VALUES #{
              (versions_to_create - versions_to_delete_or_append).map { |vtc| "('#{vtc}')" }.join(', ')
            }")
          end
        end
      end

    private

      def gen_migration_columns(relations, tbl, tbl_parts, add_fks, built_schemas, mig_path, current_mig_time,
                                key_type, is_4x_rails, ar_version, do_fks_last, versions_to_create)
        return unless (relation = relations.fetch(tbl, nil))&.fetch(:cols, nil)&.present?

        mig = +''
        pkey_cols = (rpk = relation[:pkey].values.flatten) & (arpk = [::Brick.ar_base.primary_key].flatten.sort)
        # In case things aren't as standard
        if pkey_cols.empty?
          pkey_cols = if rpk.empty? && relation[:cols][arpk.first]&.first == key_type
                        arpk
                      elsif rpk.first
                        rpk
                      end
        end
        schema = if tbl_parts.length > 1
                   if tbl_parts.first == (::Brick.default_schema || 'public')
                     tbl_parts.shift
                     nil
                   else
                     tbl_parts.first
                   end
                 end
        unless schema.blank? || built_schemas.key?(schema)
          mig = +"  def change\n    create_schema(:#{schema}) unless schema_exists?(:#{schema})\n  end\n"
          current_mig_time[0] += 1.minute
          versions_to_create << migration_file_write(mig_path, "create_db_schema_#{schema.underscore}", current_mig_time, ar_version, mig)
          built_schemas[schema] = nil
        end

        # %%% For the moment we're skipping polymorphics
        fkey_cols = relation[:fks].values.select { |assoc| assoc[:is_bt] && !assoc[:polymorphic] }
        # If the primary key is also used as a foreign key, will need to do  id: false  and then build out
        # a column definition which includes :primary_key -- %%% also using a data type of bigserial or serial
        # if this one has come in as bigint or integer.
        pk_is_also_fk = fkey_cols.any? { |assoc| pkey_cols&.first == assoc[:fk] } ? pkey_cols&.first : nil
        id_option = if pk_is_also_fk || !pkey_cols&.present?
                      needs_serial_col = true
                      +', id: false' # Support missing primary key (by adding:  , id: false)
                    elsif ((pkey_col_first = (col_def = relation[:cols][pkey_cols&.first])&.first) &&
                          (pkey_col_first = SQL_TYPES[pkey_col_first] || SQL_TYPES[col_def&.[](0..1)] ||
                                            SQL_TYPES.find { |r| r.first.is_a?(Regexp) && pkey_col_first =~ r.first }&.last ||
                                            pkey_col_first
                          ) != key_type
                          )
                      case pkey_col_first
                      when 'integer'
                        +', id: :serial'
                      when 'bigint'
                        +', id: :bigserial'
                      else
                        +", id: :#{pkey_col_first}" # Something like:  id: :integer, primary_key: :businessentityid
                      end +
                        (pkey_cols.first ? ", primary_key: :#{pkey_cols.first}" : '')
                    end
        if !id_option && pkey_cols.sort != arpk
          id_option = +", primary_key: :#{pkey_cols.first}"
        end
        if !is_4x_rails && (comment = relation&.fetch(:description, nil))&.present?
          (id_option ||= +'') << ", comment: #{comment.inspect}"
        end
        # Find the ActiveRecord class in order to see if the columns have comments
        unless is_4x_rails
          klass = begin
                    tbl.tr('.', '/').singularize.camelize.constantize
                  rescue StandardError
                  end
          if klass
            unless ActiveRecord::Migration.table_exists?(klass.table_name)
              puts "WARNING: Unable to locate table #{klass.table_name} (for #{klass.name})."
              klass = nil
            end
          end
        end
        # Refer to this table name as a symbol or dotted string as appropriate
        tbl_code = tbl_parts.length == 1 ? ":#{tbl_parts.first}" : "'#{tbl}'"
        mig = +"  def change\n    return unless reverting? || !table_exists?(#{tbl_code})\n\n"
        mig << "    create_table #{tbl_code}#{id_option} do |t|\n"
        possible_ts = [] # Track possible generic timestamps
        relation[:cols].each do |col, col_type|
          sql_type = SQL_TYPES[col_type.first] || SQL_TYPES[col_type[0..1]] ||
                     SQL_TYPES.find { |r| r.first.is_a?(Regexp) && col_type.first =~ r.first }&.last ||
                     col_type.first
          suffix = col_type[3] || pkey_cols&.include?(col) ? +', null: false' : +''
          suffix << ', array: true' if (col_type.first == 'ARRAY')
          if !is_4x_rails && klass && (comment = klass.columns_hash.fetch(col, nil)&.comment)&.present?
            suffix << ", comment: #{comment.inspect}"
          end
          # Determine if this column is used as part of a foreign key
          if (fk = fkey_cols.find { |assoc| col == assoc[:fk] })
            to_table = fk[:inverse_table].split('.')
            to_table = to_table.length == 1 ? ":#{to_table.first}" : "'#{fk[:inverse_table]}'"
            if needs_serial_col && pkey_cols&.include?(col) && (new_serial_type = {'integer' => 'serial', 'bigint' => 'bigserial'}[sql_type])
              sql_type = new_serial_type
              needs_serial_col = false
            end
            if do_fks_last || (fk[:fk] != "#{fk[:assoc_name].singularize}_id") # Need to do our own foreign_key tricks, not use references?
              column = fk[:fk]
              mig << emit_column(sql_type, column, suffix)
              add_fks << [to_table, column, relations[fk[:inverse_table]], tbl_code]
            else
              suffix << ", type: :#{sql_type}" unless sql_type == key_type
              # Will the resulting default index name be longer than what Postgres allows?  (63 characters)
              if (idx_name = ActiveRecord::Base.connection.index_name(tbl, {column: col})).length > 63
                # Try to find a shorter name that hasn't been used yet
                unless indexes.key?(shorter = idx_name[0..62]) ||
                       indexes.key?(shorter = idx_name.tr('_', '')[0..62]) ||
                       indexes.key?(shorter = idx_name.tr('aeio', '')[0..62])
                  puts "Unable to easily find unique name for index #{idx_name} that is shorter than 64 characters,"
                  puts "so have resorted to this GUID-based identifier: #{shorter = "#{tbl[0..25]}_#{::SecureRandom.uuid}"}."
                end
                suffix << ", index: { name: '#{shorter || idx_name}' }"
                indexes[shorter || idx_name] = nil
              end
              next if do_fks_last

              primary_key = nil
              begin
                primary_key = relations[fk[:inverse_table]][:class_name]&.constantize&.primary_key
              rescue NameError => e
                primary_key = ::Brick.ar_base.primary_key
              end
              need_pk_specifics = (primary_key != ::Brick.ar_base.primary_key)
              fk_stuff = if need_pk_specifics || to_table != ":#{fk[:assoc_name].pluralize}"
                           ", foreign_key: { to_table: #{to_table}#{", primary_key: :#{primary_key}" if need_pk_specifics} }"
                         else
                           ", foreign_key: true"
                         end
              mig << "      t.references :#{fk[:assoc_name]}#{suffix}#{fk_stuff}\n"
            end
          else
            next if !id_option&.end_with?('id: false') && pkey_cols&.include?(col)

            # See if there are generic timestamps
            if sql_type == 'timestamp' && ['created_at','updated_at'].include?(col)
              possible_ts << [col, !col_type[3]]
            else
              mig << emit_column(sql_type, col, suffix)
            end
          end
        end
        if possible_ts.length == 2 && # Both created_at and updated_at
           # Rails 5 and later timestamps default to NOT NULL
           (possible_ts.first.last == is_4x_rails && possible_ts.last.last == is_4x_rails)
          mig << "\n      t.timestamps\n"
        else # Just one or the other, or a nullability mismatch
          possible_ts.each { |ts| mig << emit_column('timestamp', ts.first, nil) }
        end
        mig << "    end\n"
        if pk_is_also_fk
          mig << "    reversible do |dir|\n"
          mig << "      dir.up { execute('ALTER TABLE #{tbl} ADD PRIMARY KEY (#{pk_is_also_fk})') }\n"
          mig << "    end\n"
        end
        add_fks.each do |add_fk|
          next unless add_fk[2]

          is_commented = false
          # add_fk[2] holds the inverse relation
          unless (pk = add_fk[2][:pkey]&.values&.flatten&.first)
            is_commented = true
            mig << "    # (Unable to create relationship because primary key is missing on table #{add_fk[0]})\n"
            # No official PK, but if coincidentally there's a column of the same name, take a chance on it
            pk = (add_fk[2][:cols].key?(add_fk[1]) && add_fk[1]) || '???'
          end
          mig << "    #{'# ' if do_fks_last}#{'# ' if is_commented}add_foreign_key #{tbl_code}, "
          #         to_table               column
          mig << "#{add_fk[0]}, column: :#{add_fk[1]}, primary_key: :#{pk}\n"
        end
        mig << "  end\n"
      end

      def emit_column(type, name, suffix)
        "      t.#{type.start_with?('numeric') ? 'decimal' : type} :#{name}#{suffix}\n"
      end

      def migration_file_write(mig_path, name, current_mig_time, ar_version, mig)
        File.open("#{mig_path}/#{version = current_mig_time.first.strftime('%Y%m%d%H%M00')}_#{name}#{'.rb' unless name.index('.')}", "w") do |f|
          f.write "class #{name.split('.').first.camelize} < ActiveRecord::Migration#{ar_version}\n"
          f.write mig
          f.write "end\n"
        end
        version
      end
    end
  end
end
