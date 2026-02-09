module Brick
  class << self
    # This is done separately so that during testing it can be called right after a migration
    # in order to make sure everything is good.
    def reflect_tables
      require 'brick/join_array'
      return unless ::Brick.config.mode == :on

      # return if ActiveRecord::Base.connection.current_database == 'postgres'

      # Accommodate funky table names for Salesforce mode
      ::Brick.apply_double_underscore_patch if ::Brick.config.salesforce_mode

      # Utilise Elasticsearch indexes, if any
      if Object.const_defined?('Elasticsearch')
        if ::Elasticsearch.const_defined?('Client')
          # Allow Elasticsearch gem > 7.10 to work with Opensearch
          ::Elasticsearch::Client.class_exec do
            alias _original_initialize initialize
            def initialize(arguments = {}, &block)
              _original_initialize(arguments,  &block)
              @verified = true
              @transport
            end

            # Auto-create when there is a missing index
            alias _original_method_missing method_missing
            def method_missing(name, *args, &block)
              return if name == :transport # Avoid infinite loop if Elasticsearch isn't yet initialized

              _original_method_missing(name, *args, &block)
            rescue Elastic::Transport::Transport::Errors::NotFound => e
              if (missing_index = args.last&.fetch(:defined_params, nil)&.fetch(:index, nil)) &&
                 (es_table_name = ::Brick.elasticsearch_possible&.fetch(missing_index, nil)) &&
                 ::Brick.elasticsearch_models&.fetch(es_table_name, nil)&.include?('i')
                self.indices.create({ index: missing_index,
                                      body: { settings: {}, mappings: { properties: {} } } })
                puts "Auto-creating missing index \"#{missing_index}\""
                _original_method_missing(name, *args, &block)
              else
                raise e
              end
            end
          end
        end
        if ::Elasticsearch.const_defined?('Model') && 
           # By setting the environment variable ELASTICSEARCH_URL then you can specify an Elasticsearch/Opensearch
           # host that is picked up here
           (host = (client = ::Elasticsearch::Model.client).transport&.hosts&.first)
          es_uri = URI.parse("#{host[:protocol]}://#{host[:host]}:#{host[:port]}")
          es_uri = nil if es_uri.to_s == 'http://localhost:9200'
          begin
            cluster_info = client.info.body
            if (es_ver = cluster_info['version'])
              puts "Found Elasticsearch gem and #{'local ' unless es_uri}#{es_ver['distribution'].titleize} #{es_ver['number']} installation#{" at #{es_uri}" if es_uri}."
              if ::Brick.elasticsearch_models.empty?
                puts "Enable Elasticsearch support by either setting \"::Brick.elasticsearch_models = :all\" or by picking specific models by name."
              end
            else
              ::Brick.elasticsearch_models = nil
            end
          rescue StandardError => e # Errno::ECONNREFUSED
            ::Brick.elasticsearch_models = nil
            puts "Found Elasticsearch gem, but could not connect to #{'local ' unless es_uri}Elasticsearch/Opensearch server#{" at #{es_uri}" if es_uri}."
          end
        end
      end

      # Overwrite SQLite's #begin_db_transaction so it opens in IMMEDIATE mode instead of
      # the default DEFERRED mode.
      #   https://discuss.rubyonrails.org/t/failed-write-transaction-upgrades-in-sqlite3/81480/2
      if ActiveRecord::Base.connection.adapter_name == 'SQLite' && ActiveRecord.version >= Gem::Version.new('5.1')
        arca = ::ActiveRecord::ConnectionAdapters
        db_statements = arca::SQLite3.const_defined?('DatabaseStatements') ? arca::SQLite3::DatabaseStatements : arca::SQLite3::SchemaStatements
        # Rails 7.1 and later
        if arca::AbstractAdapter.private_instance_methods.include?(:with_raw_connection)
          db_statements.define_method(:begin_db_transaction) do
            log("begin immediate transaction", "TRANSACTION") do
              with_raw_connection(allow_retry: true, materialize_transactions: false) do |conn|
                conn.transaction(:immediate)
              end
            end
          end
        else # Rails < 7.1
          db_statements.define_method(:begin_db_transaction) do
            log('begin immediate transaction', 'TRANSACTION') { @connection.transaction(:immediate) }
          end
        end
      end

      orig_schema = nil
      if (relations = ::Brick.relations).keys == [:db_name]
        # ::Brick.remove_instance_variable(:@_additional_references_loaded) if ::Brick.instance_variable_defined?(:@_additional_references_loaded)

        # Only for Postgres  (Doesn't work in sqlite3 or MySQL)
        # puts ActiveRecord::Base.execute_sql("SELECT current_setting('SEARCH_PATH')").to_a.inspect

        # ---------------------------
        # 1. Figure out schema things
        is_postgres = nil
        is_mssql = ActiveRecord::Base.connection.adapter_name == 'SQLServer'
        case ActiveRecord::Base.connection.adapter_name
        when 'PostgreSQL', 'SQLServer'
          is_postgres = !is_mssql
          db_schemas = if is_postgres
                         ActiveRecord::Base.execute_sql('SELECT nspname AS table_schema, MAX(oid) AS dt FROM pg_namespace GROUP BY 1 ORDER BY 1;')
                       else
                         ActiveRecord::Base.execute_sql('SELECT DISTINCT table_schema, NULL AS dt FROM INFORMATION_SCHEMA.tables;')
                       end
          ::Brick.db_schemas = db_schemas.each_with_object({}) do |row, s|
            row = case row
                  when Array
                    row
                  else
                    [row['table_schema'], row['dt']]
                  end
            # Remove any system schemas
            s[row.first] = { dt: row.last } unless ['information_schema', 'pg_catalog', 'pg_toast', 'heroku_ext',
                                                    'INFORMATION_SCHEMA', 'sys'].include?(row.first)
          end
          possible_schema, possible_schemas, multitenancy = ::Brick.get_possible_schemas
          if possible_schemas
            if possible_schema
              ::Brick.default_schema = ::Brick.apartment_default_tenant
              schema = possible_schema
              orig_schema = ActiveRecord::Base.execute_sql('SELECT current_schemas(true)').first['current_schemas'][1..-2].split(',')
              ActiveRecord::Base.execute_sql("SET SEARCH_PATH = ?", schema)
            # When testing, just find the most recently-created schema
            elsif begin
                    Rails.env == 'test' ||
                      ActiveRecord::Base.execute_sql("SELECT value FROM ar_internal_metadata WHERE key='environment';").first&.fetch('value', nil) == 'test'
                  rescue
                  end
              ::Brick.default_schema = ::Brick.apartment_default_tenant
              ::Brick.test_schema = schema = ::Brick.db_schemas.to_a.sort { |a, b| b.last[:dt] <=> a.last[:dt] }.first.first
              if possible_schema.blank?
                puts "While running tests, using the most recently-created schema, #{schema}."
              else
                puts "While running tests, had noticed in the brick.rb initializer that the line \"::Brick.schema_behavior = ...\" refers to a schema called \"#{possible_schema}\" which does not exist.  Reading table structure from the most recently-created schema, #{schema}."
              end
              orig_schema = ActiveRecord::Base.execute_sql('SELECT current_schemas(true)').first['current_schemas'][1..-2].split(',')
              ::Brick.config.schema_behavior = { multitenant: {} } # schema_to_analyse: [schema]
              ActiveRecord::Base.execute_sql("SET SEARCH_PATH = ?", schema)
            else
              puts "*** In the brick.rb initializer the line \"::Brick.schema_behavior = ...\" refers to schema(s) called #{possible_schemas.map { |s| "\"#{s}\"" }.join(', ')}.  No mentioned schema exists. ***"
              if ::Brick.db_schemas.key?(::Brick.apartment_default_tenant)
                ::Brick.default_schema = schema = ::Brick.apartment_default_tenant
              end
            end
          end
        when 'Mysql2', 'Trilogy'
          ::Brick.default_schema = schema = ActiveRecord::Base.connection.current_database
        when 'OracleEnhanced'
          # ActiveRecord::Base.connection.current_database will be something like "XEPDB1"
          ::Brick.default_schema = schema = ActiveRecord::Base.connection.raw_connection.username
          ::Brick.db_schemas = {}
          ActiveRecord::Base.execute_sql("SELECT username FROM sys.all_users WHERE ORACLE_MAINTAINED != 'Y'").each { |s| ::Brick.db_schemas[s.first] = {} }
        when 'SQLite'
          sql = "SELECT m.name AS relation_name, UPPER(m.type) AS table_type,
            p.name AS column_name, p.type AS data_type,
            CASE p.pk WHEN 1 THEN 'PRIMARY KEY' END AS const
          FROM sqlite_master AS m
            INNER JOIN pragma_table_info(m.name) AS p
          WHERE m.name NOT IN ('sqlite_sequence', ?, ?)
          ORDER BY m.name, p.cid"
        else
          puts "Unfamiliar with connection adapter #{ActiveRecord::Base.connection.adapter_name}"
        end

        ::Brick.db_schemas ||= {}

        # ---------------------
        # 2. Tables and columns
        # %%% Retrieve internal ActiveRecord table names like this:
        # ActiveRecord::Base.internal_metadata_table_name, ActiveRecord::Base.schema_migrations_table_name
        # For if it's not SQLite -- so this is the Postgres and MySQL version
        measures = []
        ::Brick.is_oracle = true if ActiveRecord::Base.connection.adapter_name == 'OracleEnhanced'
        case ActiveRecord::Base.connection.adapter_name
        when 'PostgreSQL', 'SQLite' # These bring back a hash for each row because the query uses column aliases
          # schema ||= 'public' if ActiveRecord::Base.connection.adapter_name == 'PostgreSQL'
          retrieve_schema_and_tables(sql, is_postgres, is_mssql, schema).each do |r|
            # If Apartment gem lists the table as being associated with a non-tenanted model then use whatever it thinks
            # is the default schema, usually 'public'.
            schema_name = if ::Brick.config.schema_behavior[:multitenant]
                            ::Brick.apartment_default_tenant if ::Brick.is_apartment_excluded_table(r['relation_name'])
                          elsif ![schema, 'public'].include?(r['schema'])
                            r['schema']
                          end
            relation_name = schema_name ? "#{schema_name}.#{r['relation_name']}" : r['relation_name']
            # Both uppers and lowers as well as underscores?
            ::Brick.apply_double_underscore_patch if relation_name =~ /[A-Z]/ && relation_name =~ /[a-z]/ && relation_name.index('_')
            relation = relations[relation_name]
            relation[:isView] = true if r['table_type'] == 'VIEW'
            relation[:description] = r['table_description'] if r['table_description']
            col_name = r['column_name']
            key = case r['const']
                  when 'PRIMARY KEY'
                    relation[:pkey][r['key'] || relation_name] ||= []
                  when 'UNIQUE'
                    relation[:ukeys][r['key'] || "#{relation_name}.#{col_name}"] ||= []
                    # key = (relation[:ukeys] = Hash.new { |h, k| h[k] = [] }) if key.is_a?(Array)
                    # key[r['key']]
                  else
                    if r['data_type'] == 'uuid'
                      # && r['column_name'] == ::Brick.ar_base.primary_key
                      # binding.pry
                      relation[:pkey][r['key'] || relation_name] ||= []
                    end
                  end
            # binding.pry if key && r['data_type'] == 'uuid'
            key << col_name if key
            cols = relation[:cols] # relation.fetch(:cols) { relation[:cols] = [] }
            cols[col_name] = [r['data_type'], r['max_length'], measures&.include?(col_name), r['is_nullable'] == 'NO']
            # puts "KEY! #{r['relation_name']}.#{col_name} #{r['key']} #{r['const']}" if r['key']
            relation[:col_descrips][col_name] = r['column_description'] if r['column_description']
          end
        else # MySQL2, OracleEnhanced, and MSSQL act a little differently, bringing back an array for each row
          schema_and_tables = case ActiveRecord::Base.connection.adapter_name
                              when 'OracleEnhanced'
                                sql =
"SELECT c.owner AS schema, c.table_name AS relation_name,
  CASE WHEN v.owner IS NULL THEN 'BASE_TABLE' ELSE 'VIEW' END AS table_type,
  c.column_name, c.data_type,
  COALESCE(c.data_length, c.data_precision) AS max_length,
  CASE ac.constraint_type WHEN 'P' THEN 'PRIMARY KEY' END AS const,
  ac.constraint_name AS \"key\",
  CASE c.nullable WHEN 'Y' THEN 'YES' ELSE 'NO' END AS is_nullable
FROM all_tab_cols c
  LEFT OUTER JOIN all_cons_columns acc ON acc.owner = c.owner AND acc.table_name = c.table_name AND acc.column_name = c.column_name
  LEFT OUTER JOIN all_constraints ac ON ac.owner = acc.owner AND ac.table_name = acc.table_name AND ac.constraint_name = acc.constraint_name AND constraint_type = 'P'
  LEFT OUTER JOIN all_views v ON c.owner = v.owner AND c.table_name = v.view_name
WHERE c.owner IN (#{::Brick.db_schemas.keys.map { |s| "'#{s}'" }.join(', ')})
  AND c.table_name NOT IN (?, ?)
ORDER BY 1, 2, c.internal_column_id, acc.position"
                                ActiveRecord::Base.execute_sql(sql, *ar_tables)
                              else
                                retrieve_schema_and_tables(sql)
                              end

          schema_and_tables.each do |r|
            next if r[1].index('$') # Oracle can have goofy table names with $

            if (relation_name = r[1]) =~ /^[A-Z0-9_]+$/
              relation_name.downcase!
            # Both uppers and lowers as well as underscores?
            elsif relation_name =~ /[A-Z]/ && relation_name =~ /[a-z]/ && relation_name.index('_')
              ::Brick.apply_double_underscore_patch
            end
            # Expect the default schema for SQL Server to be 'dbo'.
            if (::Brick.is_oracle && r[0] != schema) || (is_mssql && r[0] != 'dbo')
              relation_name = "#{r[0]}.#{relation_name}"
            end

            relation = relations[relation_name] # here relation represents a table or view from the database
            relation[:isView] = true if r[2] == 'VIEW' # table_type
            col_name = ::Brick.is_oracle ? connection.send(:oracle_downcase, r[3]) : r[3]
            key = case r[6] # constraint type
                  when 'PRIMARY KEY'
                    # key
                    relation[:pkey][r[7] || relation_name] ||= []
                  when 'UNIQUE'
                    relation[:ukeys][r[7] || "#{relation_name}.#{col_name}"] ||= []
                    # key = (relation[:ukeys] = Hash.new { |h, k| h[k] = [] }) if key.is_a?(Array)
                    # key[r['key']]
                  end
            key << col_name if key
            cols = relation[:cols] # relation.fetch(:cols) { relation[:cols] = [] }
            # 'data_type', 'max_length', measure, 'is_nullable'
            cols[col_name] = [r[4], r[5], measures&.include?(col_name), r[8] == 'NO']
            # puts "KEY! #{r['relation_name']}.#{col_name} #{r['key']} #{r['const']}" if r['key']
          end
        end

        # PostGIS adds three views which would confuse Rails if models were to be built for them.
        if ActiveRecord::Base.connection.adapter_name == 'PostgreSQL'
          if relations.key?('geography_columns') && relations.key?('geometry_columns') && relations.key?('spatial_ref_sys')
            (::Brick.config.exclude_tables ||= []) << 'geography_columns'
            ::Brick.config.exclude_tables << 'geometry_columns'
            ::Brick.config.exclude_tables << 'spatial_ref_sys'
          end
        end

        # # Add unique OIDs
        # if ActiveRecord::Base.connection.adapter_name == 'PostgreSQL'
        #   ActiveRecord::Base.execute_sql(
        #     "SELECT c.oid, n.nspname, c.relname
        #     FROM pg_catalog.pg_namespace AS n
        #       INNER JOIN pg_catalog.pg_class AS c ON n.oid = c.relnamespace
        #     WHERE c.relkind IN ('r', 'v')"
        #   ).each do |r|
        #     next if ['pg_catalog', 'information_schema', ''].include?(r['nspname']) ||
        #       ['ar_internal_metadata', 'schema_migrations'].include?(r['relname'])
        #     relation = relations.fetch(r['relname'], nil)
        #     if relation
        #       (relation[:oid] ||= {})[r['nspname']] = r['oid']
        #     else
        #       puts "Where is #{r['nspname']} #{r['relname']} ?"
        #     end
        #   end
        # end
        # schema = ::Brick.default_schema # Reset back for this next round of fun

        # ---------------------------------------------
        # 3. Foreign key info
        # (done in two parts which get JOINed together in Ruby code)
        kcus = nil
        entry_type = nil
        case ActiveRecord::Base.connection.adapter_name
        when 'PostgreSQL', 'Mysql2', 'Trilogy', 'SQLServer'
          # Part 1 -- all KCUs
          sql = "SELECT CONSTRAINT_CATALOG, CONSTRAINT_SCHEMA, CONSTRAINT_NAME, ORDINAL_POSITION,
                        TABLE_NAME, COLUMN_NAME
                FROM INFORMATION_SCHEMA.KEY_COLUMN_USAGE#{"
                WHERE CONSTRAINT_SCHEMA = COALESCE(current_setting('SEARCH_PATH'), 'public')" if is_postgres && schema }#{"
                WHERE CONSTRAINT_SCHEMA = '#{ActiveRecord::Base.connection.current_database&.tr("'", "''")}'" if ActiveRecord::Base.is_mysql
                }"
          kcus = ActiveRecord::Base.execute_sql(sql).each_with_object({}) do |v, s|
                   if (entry_type ||= v.is_a?(Array) ? :array : :hash) == :hash
                     key = "#{v['constraint_name']}.#{v['constraint_schema']}.#{v['constraint_catalog']}.#{v['ordinal_position']}"
                     key << ".#{v['table_name']}.#{v['column_name']}" unless is_postgres || is_mssql
                     s[key] = [v['constraint_schema'], v['table_name']]
                   else # Array
                     key = "#{v[2]}.#{v[1]}.#{v[0]}.#{v[3]}"
                     key << ".#{v[4]}.#{v[5]}" unless is_postgres || is_mssql
                     s[key] = [v[1], v[4]]
                   end
                 end

          # Part 2 -- fk_references
          sql = "SELECT kcu.CONSTRAINT_SCHEMA, kcu.TABLE_NAME, kcu.COLUMN_NAME,
              #{# These will get filled in with real values (effectively doing the JOIN in Ruby)
                is_postgres || is_mssql ? 'NULL as primary_schema, NULL as primary_table' :
                                          'kcu.REFERENCED_TABLE_NAME, kcu.REFERENCED_COLUMN_NAME'},
              kcu.CONSTRAINT_NAME AS CONSTRAINT_SCHEMA_FK,
              rc.UNIQUE_CONSTRAINT_NAME, rc.UNIQUE_CONSTRAINT_SCHEMA, rc.UNIQUE_CONSTRAINT_CATALOG, kcu.ORDINAL_POSITION
            FROM INFORMATION_SCHEMA.REFERENTIAL_CONSTRAINTS AS rc
              INNER JOIN INFORMATION_SCHEMA.KEY_COLUMN_USAGE AS kcu
                ON kcu.CONSTRAINT_CATALOG = rc.CONSTRAINT_CATALOG
                AND kcu.CONSTRAINT_SCHEMA = rc.CONSTRAINT_SCHEMA
                AND kcu.CONSTRAINT_NAME = rc.CONSTRAINT_NAME#{"
            WHERE kcu.CONSTRAINT_SCHEMA = COALESCE(current_setting('SEARCH_PATH'), 'public')" if is_postgres && schema}#{"
            WHERE kcu.CONSTRAINT_SCHEMA = '#{ActiveRecord::Base.connection.current_database&.tr("'", "''")}'" if ActiveRecord::Base.is_mysql}"
          fk_references = ActiveRecord::Base.execute_sql(sql)
        when 'SQLite'
          sql = "SELECT NULL AS constraint_schema, m.name, fkl.\"from\", NULL AS primary_schema, fkl.\"table\", m.name || '_' || fkl.\"from\" AS constraint_name
          FROM sqlite_master m
            INNER JOIN pragma_foreign_key_list(m.name) fkl ON m.type = 'table'
          ORDER BY m.name, fkl.seq"
          fk_references = ActiveRecord::Base.execute_sql(sql)
        when 'OracleEnhanced'
          schemas = ::Brick.db_schemas.keys.map { |s| "'#{s}'" }.join(', ')
          sql =
          "SELECT -- fk
                 ac.owner AS constraint_schema, acc_fk.table_name, acc_fk.column_name,
                 -- referenced pk
                 ac.r_owner AS primary_schema, acc_pk.table_name AS primary_table, acc_fk.constraint_name AS constraint_schema_fk
                 -- , acc_pk.column_name
          FROM all_cons_columns acc_fk
            INNER JOIN all_constraints ac ON acc_fk.owner = ac.owner
              AND acc_fk.constraint_name = ac.constraint_name
            INNER JOIN all_cons_columns acc_pk ON ac.r_owner = acc_pk.owner
              AND ac.r_constraint_name = acc_pk.constraint_name
          WHERE ac.constraint_type = 'R'
            AND ac.owner IN (#{schemas})
            AND ac.r_owner IN (#{schemas})"
          fk_references = ActiveRecord::Base.execute_sql(sql)
        end
        ::Brick.is_oracle = true if ActiveRecord::Base.connection.adapter_name == 'OracleEnhanced'
        # ::Brick.default_schema ||= schema ||= 'public' if ActiveRecord::Base.connection.adapter_name == 'PostgreSQL'
        ::Brick.default_schema ||= 'public' if is_postgres
        fk_references&.each do |fk|
          fk = fk.values unless fk.is_a?(Array)
          # Virtually JOIN KCUs to fk_references in order to fill in the primary schema and primary table
          kcu_key = "#{fk[6]}.#{fk[7]}.#{fk[8]}.#{fk[9]}"
          kcu_key << ".#{fk[3]}.#{fk[4]}" unless is_postgres || is_mssql
          if (kcu = kcus&.fetch(kcu_key, nil))
            fk[3] = kcu[0]
            fk[4] = kcu[1]
          end
          # Multitenancy makes things a little more general overall, except for non-tenanted tables
          if ::Brick.is_apartment_excluded_table(::Brick.namify(fk[1]))
            fk[0] = ::Brick.apartment_default_tenant
          elsif (is_postgres && (fk[0] == 'public' || (multitenancy && fk[0] == schema))) ||
                (::Brick.is_oracle && fk[0] == schema) ||
                (is_mssql && fk[0] == 'dbo') ||
                (!is_postgres && !::Brick.is_oracle && !is_mssql && ['mysql', 'performance_schema', 'sys'].exclude?(fk[0]))
            fk[0] = nil
          end
          if ::Brick.is_apartment_excluded_table(fk[4])
            fk[3] = ::Brick.apartment_default_tenant
          elsif (is_postgres && (fk[3] == 'public' || (multitenancy && fk[3] == schema))) ||
                (::Brick.is_oracle && fk[3] == schema) ||
                (is_mssql && fk[3] == 'dbo') ||
                (!is_postgres && !::Brick.is_oracle && !is_mssql && ['mysql', 'performance_schema', 'sys'].exclude?(fk[3]))
            fk[3] = nil
          end
          if ::Brick.is_oracle
            fk[1].downcase! if fk[1] =~ /^[A-Z0-9_]+$/
            fk[4].downcase! if fk[4] =~ /^[A-Z0-9_]+$/
            fk[2] = connection.send(:oracle_downcase, fk[2])
          end
          ::Brick._add_bt_and_hm(fk, relations, nil, nil)
        end
        kcus = nil # Allow this large item to be garbage collected
      end

      table_name_lookup = (::Brick.table_name_lookup ||= {})
      relations.each do |k, v|
        next if k.is_a?(Symbol)

        rel_name = k.split('.').map { |rel_part| ::Brick.namify(rel_part, :underscore) }
        schema_names = rel_name[0..-2]
        schema_names.shift if ::Brick.apartment_multitenant && schema_names.first == ::Brick.apartment_default_tenant
        v[:schema] = schema_names.join('.') unless schema_names.empty?
        # %%% If more than one schema has the same table name, will need to add a schema name prefix to have uniqueness
        if (singular = rel_name.last.singularize).blank?
          singular = rel_name.last
        end
        name_parts = if (tnp = ::Brick.config.table_name_prefixes
                                      &.find do |k1, v1|
                                        k.start_with?(k1) &&
                                        ((k.length >= k1.length && v1) ||
                                         (k.length == k1.length && (v1.nil? || v1.start_with?('::'))))
                                      end
                        )&.present?
                       if tnp.last&.start_with?('::') # TNP that points to an exact class?
                         # Had considered:  [tnp.last[2..-1]]
                         [singular]
                       elsif tnp.last
                         v[:auto_prefixed_schema], v[:auto_prefixed_class] = tnp
                         # v[:resource] = rel_name.last[tnp.first.length..-1]
                         [tnp.last, singular[tnp.first.length..-1]]
                       else # Override applying an auto-prefix for any TNP that points to nil
                         [singular]
                       end
                     else
                       # v[:resource] = rel_name.last
                       [singular]
                     end
        proposed_name_parts = (schema_names + name_parts).map { |p| ::Brick.namify(p, :underscore).camelize }
        # Find out if the proposed name leads to a module or class that already exists and is not an AR class
        colliding_thing = nil
        loop do
          klass = Object
          proposed_name_parts.each do |part|
            if klass.const_defined?(part) && klass.name != part
              begin
                klass = klass.const_get(part)
              rescue NoMethodError => e
                klass = nil
                break
              end
            else
              klass = nil
              break
            end
          end
          break if !klass || (klass < ActiveRecord::Base) # Break if all good -- no conflicts

          # Find a unique name since there's already something that's non-AR with that same name
          last_idx = proposed_name_parts.length - 1
          proposed_name_parts[last_idx] = ::Brick.ensure_unique(proposed_name_parts[last_idx], 'X')
          colliding_thing ||= klass
        end
        v[:class_name] = proposed_name_parts.join('::')
        # Was:  v[:resource] = v[:class_name].underscore.tr('/', '.')
        v[:resource] = proposed_name_parts.last.underscore
        if colliding_thing
          message_start = if colliding_thing.is_a?(Module) && Object.const_defined?(:Rails) &&
                             colliding_thing.constants.find { |c| (ctc = colliding_thing.const_get(c)).is_a?(Class) && ctc < ::Rails::Application }
                            "The module for the Rails application itself, \"#{colliding_thing.name}\","
                          else
                            "Non-AR #{colliding_thing.class.name.downcase} \"#{colliding_thing.name}\""
                          end
          puts "WARNING:  #{message_start} already exists.\n  Will set up to auto-create model #{v[:class_name]} for table #{k}."
        end
        # Track anything that's out-of-the-ordinary
        table_name_lookup[v[:class_name]] = k.split('.').last unless v[:class_name].underscore.pluralize == k
      end
      ::Brick.load_additional_references if ::Brick.initializer_loaded

      if is_postgres
        params = []
        ActiveRecord::Base.execute_sql("-- inherited and partitioned tables counts
        SELECT n.nspname, parent.relname,
          ((SUM(child.reltuples::float) / greatest(SUM(child.relpages), 1))) *
          (SUM(pg_relation_size(child.oid))::float / (current_setting('block_size')::float))::integer AS rowcount
        FROM pg_inherits
          INNER JOIN pg_class parent ON pg_inherits.inhparent = parent.oid
          INNER JOIN pg_class child ON pg_inherits.inhrelid = child.oid
          INNER JOIN pg_catalog.pg_namespace n ON n.oid = parent.relnamespace#{
      if schema
        params << schema
        "
        WHERE n.nspname = COALESCE(?, 'public')"
      end}
        GROUP BY n.nspname, parent.relname, child.reltuples, child.relpages, child.oid

        UNION ALL

        -- table count
        SELECT n.nspname, pg_class.relname,
          (pg_class.reltuples::float / greatest(pg_class.relpages, 1)) *
            (pg_relation_size(pg_class.oid)::float / (current_setting('block_size')::float))::integer AS rowcount
        FROM pg_class
          INNER JOIN pg_catalog.pg_namespace n ON n.oid = pg_class.relnamespace#{
      if schema
        params << schema
        "
        WHERE n.nspname = COALESCE(?, 'public')"
      end}
        GROUP BY n.nspname, pg_class.relname, pg_class.reltuples, pg_class.relpages, pg_class.oid", params).each do |tblcount|
          # %%% What is the default schema here?
          prefix = "#{tblcount['nspname']}." unless tblcount['nspname'] == (schema || 'public')
          relations.fetch("#{prefix}#{tblcount['relname']}", nil)&.[]=(:rowcount, tblcount['rowcount'].to_i.round)
        end
      end

      if (ems = ::Brick.elasticsearch_models)
        access = case ems
                 when Hash, String # Hash is a list of resource names and ES permissions such as 'r' or 'icr'
                   ems
                 when :all
                   'crud' # All CRUD
                 when :full
                   'icrud' # Also able to auto-create indexes
                 else
                   ''
                 end
        # Rewriting this to have all valid indexes and their perms
        ::Brick.elasticsearch_models = unless access.blank?
          # Find all existing indexes
          client = Elastic::Transport::Client.new
          ::Brick.elasticsearch_existings = client.perform_request('GET', '_aliases').body.each_with_object({}) do |entry, s|
            rel_name = entry.first.tr('-', '.')
            s[entry.first] = rel_name if relations.include?(entry.first)
            s[entry.first] = rel_name.singularize if relations.include?(rel_name.singularize)
            entry.last.fetch('aliases', nil)&.each do |k, _v|
              rel_name = k.tr('-', '.')
              s[k] = rel_name if relations.include?(rel_name)
              s[k] = rel_name.singularize if relations.include?(rel_name.singularize)
            end
          end
          # Add this either if...
          if access.is_a?(String) # ...they have permissions over absolutely anything,
            relations.each_with_object({}) do |rel, s|
              next if rel.first.is_a?(Symbol)

              perms = rel.last.fetch(:isView, nil) ? access.tr('cud', '') : access
              unless ::Brick.elasticsearch_existings[es_index = rel.first.tr('.', '-').pluralize]
                (::Brick.elasticsearch_possible ||= {})[es_index] = rel.first
              end
              s[rel.first] = perms
            end
          else # or there are specific permissions for each resource, so find the matching indexes
            client = Elastic::Transport::Client.new
            ::Brick.elasticsearch_existings.each_with_object({}) do |index, s|
              this_access = access.is_a?(String) ? access : access[index.first] || '' # Look up permissions from above
              next unless (rel = relations.fetch(index.first, nil))

              perms = rel&.fetch(:isView, nil) ? this_access.tr('cud', '') : this_access
              s[index.first] = perms unless perms.blank?
            end
          end
        end
      end

      if orig_schema && (orig_schema = (orig_schema - ['pg_catalog', 'pg_toast', 'heroku_ext']).first)
        puts "Now switching back to \"#{orig_schema}\" schema."
        ActiveRecord::Base.execute_sql("SET SEARCH_PATH = ?", orig_schema)
      end
    end

    def retrieve_schema_and_tables(sql = nil, is_postgres = nil, is_mssql = nil, schema = nil)
      is_mssql = ActiveRecord::Base.connection.adapter_name == 'SQLServer' if is_mssql.nil?
      params = ar_tables
      sql ||= "SELECT t.table_schema AS \"schema\", t.table_name AS relation_name, t.table_type,#{"
        pg_catalog.obj_description(
          ('\"' || t.table_schema || '\".\"' || t.table_name || '\"')::regclass::oid, 'pg_class'
        ) AS table_description,
        pg_catalog.col_description(
          ('\"' || t.table_schema || '\".\"' || t.table_name || '\"')::regclass::oid, c.ordinal_position
        ) AS column_description," if is_postgres}
        c.column_name, #{is_postgres ? "CASE c.data_type WHEN 'USER-DEFINED' THEN pg_t.typname ELSE c.data_type END AS data_type" : 'c.data_type'},
        COALESCE(c.character_maximum_length, c.numeric_precision) AS max_length,
        kcu.constraint_type AS const, kcu.constraint_name AS \"key\",
        c.is_nullable
      FROM INFORMATION_SCHEMA.tables AS t
        LEFT OUTER JOIN INFORMATION_SCHEMA.columns AS c ON t.table_schema = c.table_schema
          AND t.table_name = c.table_name
          LEFT OUTER JOIN
          (SELECT kcu1.constraint_schema, kcu1.table_name, kcu1.column_name, kcu1.ordinal_position,
          tc.constraint_type, kcu1.constraint_name
          FROM INFORMATION_SCHEMA.KEY_COLUMN_USAGE AS kcu1
          INNER JOIN INFORMATION_SCHEMA.table_constraints AS tc
            ON kcu1.CONSTRAINT_SCHEMA = tc.CONSTRAINT_SCHEMA
            AND kcu1.TABLE_NAME = tc.TABLE_NAME
            AND kcu1.CONSTRAINT_NAME = tc.constraint_name
            AND tc.constraint_type != 'FOREIGN KEY' -- For MSSQL
          ) AS kcu ON
          -- kcu.CONSTRAINT_CATALOG = t.table_catalog AND
          kcu.CONSTRAINT_SCHEMA = c.table_schema
          AND kcu.TABLE_NAME = c.table_name
          AND kcu.column_name = c.column_name#{"
      --    AND kcu.position_in_unique_constraint IS NULL" unless is_mssql}#{"
        INNER JOIN pg_catalog.pg_namespace pg_n ON pg_n.nspname = t.table_schema
        INNER JOIN pg_catalog.pg_class pg_c ON pg_n.oid = pg_c.relnamespace AND pg_c.relname = c.table_name
        INNER JOIN pg_catalog.pg_attribute pg_a ON pg_c.oid = pg_a.attrelid AND pg_a.attname = c.column_name
        INNER JOIN pg_catalog.pg_type pg_t ON pg_t.oid = pg_a.atttypid" if is_postgres}
      WHERE t.table_schema #{is_postgres || is_mssql ?
          "NOT IN ('information_schema', 'pg_catalog', 'pg_toast', 'heroku_ext',
                   'INFORMATION_SCHEMA', 'sys')"
          :
          "= '#{ActiveRecord::Base.connection.current_database&.tr("'", "''")}'"}#{
      if is_postgres && schema
        params = params.unshift(schema) # Used to use this SQL:  current_setting('SEARCH_PATH')
        "
        AND t.table_schema = COALESCE(?, 'public')"
      end}
    --          AND t.table_type IN ('VIEW') -- 'BASE TABLE', 'FOREIGN TABLE'
        AND t.table_name NOT IN ('pg_stat_statements', ?, ?)
      ORDER BY 1, t.table_type DESC, 2, c.ordinal_position"
      ActiveRecord::Base.execute_sql(sql, *params)
    end

    def ar_tables
      ar_imtn = ActiveRecord.version >= ::Gem::Version.new('5.0') ? ActiveRecord::Base.internal_metadata_table_name : 'ar_internal_metadata'
      [self._schema_migrations_table_name, ar_imtn]
    end

    def _schema_migrations_table_name
      if ActiveRecord::Base.respond_to?(:schema_migrations_table_name)
        ActiveRecord::Base.schema_migrations_table_name
      else
        'schema_migrations'
      end
    end
  end
end
