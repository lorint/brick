# frozen_string_literal: true

require 'brick/compatibility'
ruby_version = ::Gem::Version.new(RUBY_VERSION)

# Allow ActiveRecord 4.2.7 and older to work with newer Ruby (>= 2.4) by avoiding a "stack level too deep"
# error when ActiveSupport tries to smarten up Numeric by messing with Fixnum and Bignum at the end of:
# activesupport-4.0.13/lib/active_support/core_ext/numeric/conversions.rb
if ActiveRecord.version < ::Gem::Version.new('4.2.8') &&
   ActiveRecord.version > ::Gem::Version.new('3.2') &&
   Object.const_defined?('Integer') && Integer.superclass.name == 'Numeric'
  class OurFixnum < Integer; end
  Numeric.const_set('Fixnum', OurFixnum)
  class OurBignum < Integer; end
  Numeric.const_set('Bignum', OurBignum)
end

# Allow ActiveRecord < 3.2 to run with newer versions of Psych gem
if BigDecimal.respond_to?(:yaml_tag) && !BigDecimal.respond_to?(:yaml_as)
  class BigDecimal
    class <<self
      alias yaml_as yaml_tag
    end
  end
end

require 'brick/util'

# Add left_outer_joins! to Associations::JoinDependency and Relation::QueryMethods
if ActiveRecord.version >= ::Gem::Version.new('4') && ActiveRecord.version < ::Gem::Version.new('5')
  ::Brick::Util._patch_require(
    'active_record/associations/join_dependency.rb', '/activerecord', # /associations
      ["def join_constraints(outer_joins)
        joins = join_root.children.flat_map { |child|
          make_inner_joins join_root, child
        }",
      "def join_constraints(outer_joins, join_type)
        joins = join_root.children.flat_map { |child|

          if join_type == Arel::Nodes::OuterJoin
            make_left_outer_joins join_root, child
          else
            make_inner_joins join_root, child
          end
        }"],
    :JoinDependency # This one is in an "eager_autoload do" -- so how to handle it?
  )

  # Three changes all in the same file, query_methods.rb:
  ::Brick::Util._patch_require(
    'active_record/relation/query_methods.rb', '/activerecord',
    [
     # Change 1 - Line 904
     ['build_joins(arel, joins_values.flatten) unless joins_values.empty?',
    "build_joins(arel, joins_values.flatten) unless joins_values.empty?
      build_left_outer_joins(arel, left_outer_joins_values.flatten) unless left_outer_joins_values.empty?"
     ],
     # Change 2 - Line 992
     ["raise 'unknown class: %s' % join.class.name
        end
      end",
   "raise 'unknown class: %s' % join.class.name
        end
      end

      build_join_query(manager, buckets, Arel::Nodes::InnerJoin)
   end

   def build_join_query(manager, buckets, join_type)"
     ],
     # Change 3 - Line 1012
     ['s = join_dependency.join_constraints stashed_association_joins',
      's = join_dependency.join_constraints stashed_association_joins, join_type'
     ]
    ],
    :QueryMethods
  )
end

# puts ::Brick::Util._patch_require(
#     'cucumber/cli/options.rb', '/cucumber/cli/options', # /cli/options
#     ['  def extract_environment_variables',
#      "  def extract_environment_variables\n
#     puts 'Patch test!'"]
#   ).inspect

# An ActiveRecord extension that uses INFORMATION_SCHEMA views to reflect on all
# tables and views in the database (just once at the time the database connection
# is first established), and then automatically creates models, controllers, views,
# and routes based on those available relations.
require 'brick/config'
if Gem::Specification.all_names.any? { |g| g.start_with?('rails-') }
  require 'rails'
  require 'brick/frameworks/rails'
end
module Brick
  ALL_API_ACTIONS = [:index, :show, :create, :update, :destroy]
  CURRENCY_SYMBOLS = '$£¢₵€₠ƒ¥₿₩₪₹₫₴₱₲₳₸₺₼₽៛₡₢₣₤₥₦₧₨₭₮₯₰₶₷₻₾'

  class << self
    def sti_models
      @sti_models ||= {}
    end

    def existing_stis
      @existing_stis ||= Brick.config.sti_namespace_prefixes.each_with_object({}) { |snp, s| s[snp.first[2..-1]] = snp.last unless snp.first.end_with?('::') }
    end

    attr_accessor :default_schema, :db_schemas, :test_schema,
                  :routes_done, :is_oracle, :is_eager_loading, :auto_models, :initializer_loaded
    ::Brick.auto_models = []

    def set_db_schema(params = nil)
      # If Apartment::Tenant.current is not still the default (usually 'public') then an elevator has brought us into
      # a different tenant.  If so then don't allow schema navigation.
      chosen = if ActiveRecord::Base.connection.adapter_name == 'PostgreSQL' &&
                  (current_schema = (ActiveRecord::Base.execute_sql('SELECT current_schemas(true)').first['current_schemas'][1..-2]
                                                       .split(',') - ['pg_catalog', 'pg_toast', 'heroku_ext']).first) &&
                  (is_show_schema_list = (apartment_multitenant && current_schema == ::Brick.default_schema)) &&
                  (schema = (params ? params['_brick_schema'] : ::Brick.default_schema)) &&
                  ::Brick.db_schemas&.key?(schema)
                 Apartment::Tenant.switch!(schema)
                 schema
               elsif ::Brick.test_schema
                 is_show_schema_list = true
                 Apartment::Tenant.switch!(::Brick.test_schema)
                 ::Brick.test_schema
               else
                 current_schema # Just return the current schema
               end
      [chosen == ::Brick.default_schema ? nil : chosen, is_show_schema_list]
    end

    # All tables and views (what Postgres calls "relations" including column and foreign key info)
    def relations
      return {} if (ch = ::ActiveRecord::Base.connection_handler).respond_to?(:connection_pool_list) &&
                   ch.connection_pool_list.blank?

      # Key our list of relations for this connection off of the connection pool's object_id
      (@relations ||= {})[ActiveRecord::Base.connection_pool.object_id] ||= Hash.new { |h, k| h[k] = Hash.new { |h, k| h[k] = {} } }
    end

    def apartment_multitenant
      if @apartment_multitenant.nil?
        @apartment_multitenant = ::Brick.config.schema_behavior[:multitenant] && Object.const_defined?('Apartment')
      end
      @apartment_multitenant
    end

    def apartment_default_tenant
      Apartment.default_tenant || 'public'
    end

    # If multitenancy is enabled, a list of non-tenanted "global" models
    def non_tenanted_models
      @pending_models ||= {}
    end

    # Convert spaces to underscores if the second character and onwards is mixed case
    def namify(name, action = nil)
      has_uppers = name =~ /[A-Z]+/
      has_lowers = name =~ /[a-z]+/
      name.downcase! if has_uppers && action == :downcase
      if name.include?(' ')
        # All uppers or all lowers?
        if !has_uppers || !has_lowers
          name.titleize.tr(' ', '_')
        else # Mixed uppers and lowers -- just remove existing spaces
          name.tr(' ', '')
        end
      else
        action == :underscore ? name.underscore : name
      end
    end

    def get_bts_and_hms(model, recalculate = nil)
      if !recalculate && (ret = model.instance_variable_get(:@_brick_bts_and_hms))
        return ret
      end

      model_cols = model.columns_hash
      pk_type = if (mpk = model.primary_key).is_a?(Array)
                  # Composite keys should really use:  model.primary_key.map { |pk_part| model_cols[pk_part].type }
                  model_cols[mpk.first].type
                else
                  mpk && model_cols[mpk].type
                end
      bts, hms = model.reflect_on_all_associations.each_with_object([{}, {}]) do |a, s|
        # %%% The time will come when we will support type checking of composite foreign keys!
        # binding.pry if a.foreign_key.is_a?(Array)
        if a.belongs_to? && !a.polymorphic? && ::Brick.config.polymorphics.fetch(full_assoc_name = "#{model.table_name}.#{a.name}", nil)
          puts "Based on inclusion in ::Brick.polymorphics, marking association #{full_assoc_name} as being polymorphic."
          a.options[:polymorphic] = true
        end
        next unless a.polymorphic? || (!a.belongs_to? && (through = a.options[:through])) ||
                    (a.klass && ::Brick.config.exclude_tables.exclude?(a.klass.table_name) &&
                     (!a.belongs_to? || model_cols[a.foreign_key]&.type == pk_type)
                    )

        if a.belongs_to?
          if a.polymorphic?
            rel_poly_bt = relations[model.table_name][:fks].find { |_k, fk| fk[:assoc_name] == a.name.to_s }
            if (primary_tables = rel_poly_bt&.last&.fetch(:inverse_table, [])).is_a?(Array)
              models = rel_poly_bt[1][:polymorphic]&.map { |table| table.singularize.camelize.constantize }
              s.first[a.foreign_key.to_s] = [a.name, models, true]
            else
              # This will come up when using Devise invitable when invited_by_class_name is not
              # specified because in that circumstance it adds a polymorphic :invited_by association,
              # along with appropriate invited_by_type and invited_by_id columns.

              # See if any currently-loaded models have a has_many association over to this polymorphic belongs_to
              hm_models = ActiveRecord::Base.descendants.select do |m|
                m.reflect_on_all_associations.any? { |assoc| !assoc.belongs_to? && assoc.options[:as]&.to_sym == a.name }
              end
              # No need to include subclassed models if their parent is already in the list
              hm_models.reject! { |m| hm_models.any? { |parent| parent != m && m < parent } }
              if hm_models.empty?
                puts "Missing any real indication as to which models \"has_many\" this polymorphic BT in model #{a.active_record.name}:"
                puts "  belongs_to :#{a.name}, polymorphic: true"
              else
                puts "Having analysed all currently-loaded models to infer the various polymorphic has_many associations for #{model.name}, here are the current results:"
                puts "::Brick.polymorphics = { \"#{model.table_name}.#{a.name}\" =>
                         #{hm_models.map(&:name).inspect}
                       }"
                puts 'If you add the above to your brick.rb, it will "cement" these options into place, and avoid this lookup process.'
                s.first[a.foreign_key.to_s] = [a.name, hm_models, true]
              end
            end
          else
            bt_key = a.foreign_key.is_a?(Array) ? a.foreign_key : a.foreign_key.to_s
            s.first[bt_key] = [a.name, a.klass]
          end
        else # This gets all forms of has_many and has_one
          if through # has_many :through or has_one :through
            is_invalid_source = nil
            begin
              if a.through_reflection.macro != :has_many # This HM goes through either a belongs_to or a has_one, so essentially a HOT?
                # Treat it like a belongs_to - just keyed on the association name instead of a foreign_key
                s.first[a.name] = [a.name, a.klass]
                next
              elsif !a.source_reflection # Had considered:  a.active_record.reflect_on_association(a.source_reflection_name).nil?
                is_invalid_source = true
              end
            rescue
              is_invalid_source = true
            end
            if is_invalid_source
              puts "WARNING:  HMT relationship :#{a.name} in model #{model.name} has invalid source :#{a.source_reflection_name}."
              next
            end
          else
            if !a.options.key?(:as) && a.klass.column_names.exclude?(a.foreign_key.to_s)
              options = ", #{a.options.map { |k, v| "#{k.inspect} => #{v.inspect}" }.join(', ')}" if a.options.present?
              puts "WARNING:  Model #{model.name} has this association:
            has_many :#{a.name}#{options}
          which expects column #{a.foreign_key} to exist in table #{a.klass.table_name}.  This column is missing."
              next

            end
          end
          s.last[a.name] = a
        end
      end
      # Mark has_manys that go to an associative ("join") table so that they are skipped in the UI,
      # as well as any possible polymorphic associations
      skip_hms = {}
      hms.each do |hmt|
        if (through = hmt.last.options[:through])
          # ::Brick.relations[hmt.last.through_reflection.table_name]
          skip_hms[through] = nil if hms[through] && model.is_brick? &&
                                     hmt.last.klass != hmt.last.active_record # Don't pull HMs for HMTs that point back to the same table
          # End up with a hash of HMT names pointing to join-table associations
          model._br_associatives[hmt.first] = hms[through] # || hms["#{(opt = hmt.last.options)[:through].to_s.singularize}_#{opt[:source].to_s.pluralize}".to_sym]
        end
      end
      skip_hms.each { |k, _v| hms.delete(k) }
      model.instance_variable_set(:@_brick_bts_and_hms, [bts, hms]) # Cache and return this result
    end

    def exclude_column(table, col)
      puts "Excluding #{table}.#{col}"
      true
    end
    def unexclude_column(table, col)
      puts "Unexcluding #{table}.#{col}"
      true
    end

    # @api public
    def mode=(setting)
      Brick.config.mode = setting
    end

    # Any path prefixing to apply to all auto-generated Brick routes
    # @api public
    def path_prefix=(path)
      Brick.config.path_prefix = path
    end

    # Switches Brick auto-models on or off, for all threads
    # @api public
    def enable_models=(value)
      Brick.config.enable_models = value
    end

    # Returns `true` if Brick models are on, `false` otherwise. This affects all
    # threads. Enabled by default.
    # @api public
    def enable_models?
      !!Brick.config.enable_models
    end

    # Switches Brick auto-controllers on or off, for all threads
    # @api public
    def enable_controllers=(value)
      Brick.config.enable_controllers = value
    end

    # Returns `true` if Brick controllers are on, `false` otherwise. This affects all
    # threads. Enabled by default.
    # @api public
    def enable_controllers?
      !!Brick.config.enable_controllers
    end

    # Switches Brick auto-views on or off, for all threads
    # @api public
    def enable_views=(value)
      Brick.config.enable_views = value
    end

    # Returns `true` if Brick views are on, `false` otherwise. This affects all
    # threads. Enabled by default.
    # @api public
    def enable_views?
      !!Brick.config.enable_views
    end

    # Switches Brick auto-routes on or off, for all threads
    # @api public
    def enable_routes=(value)
      Brick.config.enable_routes = value
    end

    # Returns `true` if Brick routes are on, `false` otherwise. This affects all
    # threads. Enabled by default.
    # @api public
    def enable_routes?
      !!Brick.config.enable_routes
    end

    # @api public
    def enable_api=(path)
      Brick.config.enable_api = path
    end

    # @api public
    def enable_api
      Brick.config.enable_api
    end

    # @api public
    def api_root=(path)
      Brick.config.api_roots = [path]
    end

    # @api public
    def api_roots=(paths)
      Brick.config.api_roots = paths
    end

    # @api public
    def api_roots
      Brick.config.api_roots
    end

    # @api public
    def api_filter=(proc)
      Brick.config.api_filter = proc
    end

    # @api public
    def api_filter
      Brick.config.api_filter
    end

    # @api public
    def skip_database_views=(value)
      Brick.config.skip_database_views = value
    end

    # @api public
    def exclude_tables=(value)
      Brick.config.exclude_tables = value
    end

    # @api public
    def models_inherit_from=(value)
      Brick.config.models_inherit_from = value
    end

    # @api public
    def table_name_prefixes=(value)
      Brick.config.table_name_prefixes = value
    end

    # @api public
    def metadata_columns=(value)
      Brick.config.metadata_columns = value
    end

    # @api public
    def not_nullables=(value)
      Brick.config.not_nullables = value
    end

    # Additional table associations to use (Think of these as virtual foreign keys perhaps)
    # @api public
    def additional_references=(ars)
      if ars
        ars = ars.call if ars.is_a?(Proc)
        ars = ars.to_a unless ars.is_a?(Array)
        ars = [ars] unless ars.empty? || ars.first.is_a?(Array)
        Brick.config.additional_references = ars
      end
    end

    # Custom columns to add to a table, minimally defined with a name and DSL string.
    # @api public
    def custom_columns=(cust_cols)
      if cust_cols
        cust_cols = cust_cols.call if cust_cols.is_a?(Proc)
        Brick.config.custom_columns = cust_cols
      end
    end

    # @api public
    def order=(value)
      Brick.config.order = value
    end

    # Skip creating a has_many association for these
    # (Uses the same exact three-part format as would define an additional_reference)
    # @api public
    def exclude_hms=(skips)
      if skips
        skips = skips.call if skips.is_a?(Proc)
        skips = skips.to_a unless skips.is_a?(Array)
        skips = [skips] unless skips.empty? || skips.first.is_a?(Array)
        Brick.config.exclude_hms = skips
      end
    end

    # Skip showing counts for these specific has_many associations when building auto-generated #index views
    # @api public
    def skip_index_hms=(value)
      Brick.config.skip_index_hms = value
    end

    # Associations to treat as a has_one
    # @api public
    def has_ones=(hos)
      if hos
        hos = hos.call if hos.is_a?(Proc)
        hos = hos.to_a unless hos.is_a?(Array)
        hos = [hos] unless hos.empty? || hos.first.is_a?(Array)
        # Translate to being nested hashes
        Brick.config.has_ones = hos&.each_with_object(Hash.new { |h, k| h[k] = {} }) do |v, s|
          s[v.first][v[1]] = v[2] if v[1]
          s
        end
      end
    end

    # Polymorphic associations
    def polymorphics=(polys)
      polys = polys.each_with_object({}) { |poly, s| s[poly] = nil } if polys.is_a?(Array)
      Brick.config.polymorphics = polys || {}
    end

    # @api public
    def json_columns=(cols)
      Brick.config.json_columns = cols
    end

    # DSL templates for individual models to provide prettier descriptions of objects
    # @api public
    def model_descrips=(descrips)
      Brick.config.model_descrips = descrips
    end

    # Module prefixes to build out and associate with specific base STI models
    # @api public
    def sti_namespace_prefixes=(snp)
      Brick.config.sti_namespace_prefixes = snp
    end

    # Database schema to use when analysing existing data, such as deriving a list of polymorphic classes
    # for polymorphics in which it wasn't originally specified.
    # @api public
    def schema_behavior=(behavior)
      Brick.config.schema_behavior = (behavior.is_a?(Symbol) ? { behavior => nil } : behavior)
    end
    # For any Brits out there
    def schema_behaviour=(behavior)
      Brick.schema_behavior = behavior
    end

    def sti_type_column=(type_col)
      Brick.config.sti_type_column = (type_col.is_a?(String) ? { type_col => nil } : type_col)
    end

    def default_route_fallback=(resource_name)
      Brick.config.default_route_fallback = resource_name
    end

    def license=(key)
      Brick.config.license = key
    end

    def always_load_fields=(field_set)
      Brick.config.always_load_fields = field_set
    end

    # Load additional references (virtual foreign keys)
    # This is attempted early if a brick initialiser file is found, and then again as a failsafe at the end of our engine's initialisation
    # %%% Maybe look for differences the second time 'round and just add new stuff instead of entirely deferring
    def load_additional_references
      return if @_additional_references_loaded || ::Brick.config.mode != :on

      relations = ::Brick.relations
      if (ars = ::Brick.config.additional_references) || ::Brick.config.polymorphics
        is_optional = ActiveRecord.version >= ::Gem::Version.new('5.0')
        if ars
          ars.each do |ar|
            fk = ar.length < 5 ? [nil, +ar[0], ar[1], nil, +ar[2]] : [ar[0], +ar[1], ar[2], ar[3], +ar[4], ar[5]]
            ::Brick._add_bt_and_hm(fk, relations, false, is_optional)
          end
        end
        if (polys = ::Brick.config.polymorphics)
          if (schema = ::Brick.config.schema_behavior[:multitenant]&.fetch(:schema_to_analyse, nil)) && ::Brick.db_schemas&.key?(schema)
            ActiveRecord::Base.execute_sql("SET SEARCH_PATH = ?;", schema)
          end
          missing_stis = {}
          polys.each do |k, v|
            table_name, poly = k.split('.')
            v ||= ActiveRecord::Base.execute_sql("SELECT DISTINCT #{poly}_type AS typ FROM #{table_name}").each_with_object([]) { |result, s| s << result['typ'] if result['typ'] }
            v.each do |type|
              # Allow polymorphic BT to relate to an STI subclass
              base_type = ::Brick.config.sti_namespace_prefixes["::#{type}"] ||
                          ::Brick.config.sti_namespace_prefixes.find { |k, _v| k.end_with?('::') && type.start_with?(k[2..-1]) }&.last&.[](2..-1)
              if relations.key?(primary_table = (base_type || type).underscore.pluralize)
                ::Brick._add_bt_and_hm([nil, table_name, poly, nil, primary_table, "(brick) #{table_name}_#{poly}"], relations,
                                       type, # Polymorphic class
                                       is_optional)
              elsif relations.present?
                missing_stis[primary_table] = type unless ::Brick.existing_stis.key?(type)
              end
            end
          end
          unless missing_stis.empty?
            print "
You might be missing an STI namespace prefix entry for these tables:  #{missing_stis.keys.join(', ')}.
In config/initializers/brick.rb appropriate entries would look something like:
  Brick.sti_namespace_prefixes = {"
            puts missing_stis.map { |_k, missing_sti| "\n    '#{missing_sti}' => 'SomeParentModel'" }.join(',')
            puts "  }
(Just trade out SomeParentModel with some more appropriate one.)"
          end
        end
        @_additional_references_loaded = true
      end

      # Find associative tables that can be set up for has_many :through
      ::Brick.relations.each do |_key, tbl|
        tbl_cols = tbl[:cols].keys
        fks = tbl[:fks].each_with_object({}) { |fk, s| s[fk.last[:fk]] = [fk.last[:assoc_name], fk.last[:inverse_table]] if fk.last[:is_bt]; s }
        # Aside from the primary key and the metadata columns created_at, updated_at, and deleted_at, if this table only has
        # foreign keys then it can act as an associative table and thus be used with has_many :through.
        if fks.length > 1 && (tbl_cols - fks.keys - (::Brick.config.metadata_columns || []) - (tbl[:pkey].values.first || [])).length.zero?
          fks.each { |fk| tbl[:hmt_fks][fk.first] = fk.last }
        end
      end
    end


    # Returns Brick's `::Gem::Version`, convenient for comparisons. This is
    # recommended over `::Brick::VERSION::STRING`.
    #
    # @api public
    def gem_version
      ::Gem::Version.new(VERSION::STRING)
    end

    # Set the Brick serializer. This setting affects all threads.
    # @api public
    def serializer=(value)
      Brick.config.serializer = value
    end

    # Get the Brick serializer used by all threads.
    # @api public
    def serializer
      Brick.config.serializer
    end

    # Returns Brick's global configuration object, a singleton. These
    # settings affect all threads.
    # @api private
    def config
      @config ||= Brick::Config.instance
      yield @config if block_given?
      @config
    end
    alias configure config

    def version
      VERSION::STRING
    end

    def eager_load_classes(do_ar_abstract_bases = false)
      ::Brick.is_eager_loading = true
      if ::ActiveSupport.version < ::Gem::Version.new('6') ||
         ::Rails.configuration.instance_variable_get(:@autoloader) == :classic
        if ::ActiveSupport.version < ::Gem::Version.new('4')
          ::Rails.application.eager_load!
        else
          ::Rails.configuration.eager_load_namespaces.select { |ns| ns < ::Rails::Application }.each(&:eager_load!)
        end
      else
        # Same as:  Zeitwerk::Loader.eager_load_all -- plus retry when something skips a beat
        Zeitwerk::Registry.loaders.each { |loader| load_with_retry(loader) }
      end
      abstract_ar_bases = if do_ar_abstract_bases
                            ActiveRecord::Base.descendants.select { |ar| ar.abstract_class? }.map(&:name)
                          end
      ::Brick.is_eager_loading = false
      abstract_ar_bases
    end

    # Some classes (like Phlex::Testing::Rails) will successfully auto-load after a retry
    def load_with_retry(loader, autoloaded = nil)
      autoloaded ||= loader.send(:autoloaded_dirs).dup
      begin
        loader.eager_load
      rescue Zeitwerk::SetupRequired
        # This is fine -- we eager load what can be eager loaded
      rescue Zeitwerk::NameError
        if autoloaded != (new_auto = loader.send(:autoloaded_dirs))
          load_with_retry(loader, new_auto.dup) # Try one more time and it could come together
        end
      end
    end

    def display_classes(prefix, rels, max_length)
      rels.sort.each do |rel|
        ::Brick.auto_models << rel.first
        puts "#{rel.first}#{' ' * (max_length - rel.first.length)}  /#{prefix}#{"#{rel[1]}/" if rel[1]}#{rel.last}"
      end
      puts "\n"
    end

    # Attempt to determine an ActiveRecord::Base class and additional STI information when given a controller's path
    def ctrl_to_klass(ctrl_path, res_names = {})
      klass = nil
      sti_type = nil

      if res_names.empty?
        ::Brick.relations.each_with_object({}) do |v, s|
          v_parts = v.first.split('.')
          v_parts.shift if v_parts.first == 'public'
          res_names[v_parts.join('.')] = v.first
        end
      end

      c_path_parts = ctrl_path.split('/')
      found = nil
      while c_path_parts.present?
        possible_c_path = c_path_parts.join('.')
        possible_c_path_singular = c_path_parts[0..-2] + [c_path_parts.last.singularize]
        possible_sti = possible_c_path_singular.join('/').camelize
        break if (
                   res_name = res_names[found = possible_c_path] ||
                              ((klass = Brick.config.sti_namespace_prefixes.key?("::#{possible_sti}") && possible_sti.constantize) &&
                               (sti_type = possible_sti)) ||
                              # %%% Used to have the more flexible:  (DidYouMean::SpellChecker.new(dictionary: res_names.keys).correct(possible_c_path)).first
                              res_names[found = possible_c_path] || res_names[found = possible_c_path_singular.join('.')] ||
                              ((::Brick.config.table_name_prefixes.key?(tn_prefix = c_path_parts.first) ||
                                ::Brick.config.table_name_prefixes.key?(tn_prefix = "#{c_path_parts.first}_")) &&
                               res_names[found = tn_prefix + c_path_parts.last]
                              )
                 ) &&
                 (
                   klass ||
                   ((rel = ::Brick.relations.fetch(res_name, nil)) &&
                   (klass ||= rel[:class_name]&.constantize))
                 )
        c_path_parts.shift
      end
      [klass, sti_type, found]
    end

    def apply_double_underscore_patch
      unless @double_underscore_applied
        # Same as normal #camelize and #underscore, just that double-underscores turn into a single underscore
        ActiveSupport::Inflector.class_eval do
          def camelize(term, uppercase_first_letter = true)
            strings = term.to_s.split('__').map do |string|
              # String#camelize takes a symbol (:upper or :lower), so here we also support :lower to keep the methods consistent.
              if !uppercase_first_letter || uppercase_first_letter == :lower
                string = string.sub(inflections.acronyms_camelize_regex) { |match| match.downcase! || match }
              else
                string = string.sub(/^[a-z\d]*/) { |match| inflections.acronyms[match] || match.capitalize! || match }
              end
              string.gsub!(/(?:_|(\/))([a-z\d]*)/i) do
                word = $2
                substituted = inflections.acronyms[word] || word.capitalize! || word
                $1 ? "::#{substituted}" : substituted
              end
              string
            end
            strings.join('_')
          end

          def underscore(camel_cased_word)
            return camel_cased_word.to_s unless /[A-Z-]|::/.match?(camel_cased_word)
            regex = inflections.respond_to?(:acronyms_underscore_regex) ? inflections.acronyms_underscore_regex : inflections.acronym_regex
            camel_cased_word.to_s.gsub('::', '/').split('_').map do |word|
              word.gsub!(regex) { "#{$1 && '_' }#{$2.downcase}" }
              word.gsub!(/([A-Z]+)(?=[A-Z][a-z])|([a-z\d])(?=[A-Z])/) { ($1 || $2) << '_' }
              word.tr!('-', '_')
              word.downcase!
              word
            end.join('__')
          end
        end
        @double_underscore_applied = true
      end
    end
  end

  module RouteSet
    def finalize!
      routeset_to_use = ::Rails.application.routes
      return super if self != routeset_to_use || ::Brick.routes_done

      path_prefix = ::Brick.config.path_prefix
      existing_controllers = routes.each_with_object({}) do |r, s|
        c = r.defaults[:controller]
        s[c] = nil if c
      end
      append do
        tables = []
        views = []
        table_class_length = 38 # Length of "Classes that can be built from tables:"
        view_class_length = 37 # Length of "Classes that can be built from views:"

        brick_namespace_create = lambda do |path_names, res_name, options|
          if path_names&.present?
            if (path_name = path_names.pop).is_a?(Array)
              module_name = path_name[1]
              path_name = path_name.first
            end
            send(:scope, { module: module_name || path_name, path: path_name, as: path_name }) do
              brick_namespace_create.call(path_names, res_name, options)
            end
          else
            send(:resources, res_name.to_sym, **options)
          end
        end

        # %%% TODO: If no auto-controllers then enumerate the controllers folder in order to build matching routes
        # If auto-controllers and auto-models are both enabled then this makes sense:
        controller_prefix = (path_prefix ? "#{path_prefix}/" : '')
        sti_subclasses = ::Brick.config.sti_namespace_prefixes.each_with_object(Hash.new { |h, k| h[k] = [] }) do |v, s|
                            # Turn something like {"::Spouse"=>"Person", "::Friend"=>"Person"} into {"Person"=>["Spouse", "Friend"]}
                            s[v.last] << v.first[2..-1] unless v.first.end_with?('::')
                          end
        versioned_views = {} # Track which views have already been done for each api_root
        ::Brick.relations.each do |k, v|
          if (schema_name = v.fetch(:schema, nil))
            schema_prefix = "#{schema_name}."
          end

          next if !(resource_name = v.fetch(:resource, nil)) ||
                  existing_controllers.key?(
                    controller_prefix + (resource_name = "#{schema_prefix&.tr('.', '/')}#{resource_name}".pluralize)
                  )

          object_name = k.split('.').last # Take off any first schema part

          full_schema_prefix = if (aps = v.fetch(:auto_prefixed_schema, nil))
                                  aps = aps[0..-2] if aps[-1] == '_'
                                  (schema_prefix&.dup || +'') << "#{aps}."
                                else
                                  schema_prefix
                                end

          # Track routes being built
          if (class_name = v.fetch(:class_name, nil))
            if v.key?(:isView)
              view_class_length = class_name.length if class_name.length > view_class_length
              views
            else
              table_class_length = class_name.length if class_name.length > table_class_length
              tables
            end << [class_name, aps, resource_name]
          end

          options = {}
          options[:only] = [:index, :show] if v.key?(:isView)

          # First do the normal routes
          prefixes = []
          prefixes << [aps, v[:class_name]&.split('::')[-2]&.underscore] if aps
          prefixes << schema_name if schema_name
          prefixes << path_prefix if path_prefix
          brick_namespace_create.call(prefixes, v[:resource], options)
          sti_subclasses.fetch(class_name, nil)&.each do |sc| # Add any STI subclass routes for this relation
            brick_namespace_create.call(prefixes, sc.underscore.tr('/', '_').pluralize, options)
          end

          # Now the API routes if necessary
          full_resource = nil
          ::Brick.api_roots&.each do |api_root|
            api_done_views = (versioned_views[api_root] ||= {})
            found = nil
            test_ver_num = nil
            view_relation = nil
            # If it's a view then see if there's a versioned one available by searching for resource names
            # versioned with the closest number (equal to or less than) compared with our API version number.
            if v.key?(:isView)
              if (ver = object_name.match(/^v([\d_]*)/)&.captures&.first) && ver[-1] == '_'
                core_object_name = object_name[ver.length + 1..-1]
                next if api_done_views.key?(unversioned = "#{schema_prefix}v_#{core_object_name}")

                # Expect that the last item in the path generally holds versioning information
                api_ver = api_root.split('/')[-1]&.gsub('_', '.')
                vn_idx = api_ver.rindex(/[^\d._]/) # Position of the first numeric digit at the end of the version number
                # Was:  .to_d
                test_ver_num = api_ver_num = api_ver[vn_idx + 1..-1].gsub('_', '.').to_i # Attempt to turn something like "v3" into the decimal value 3
                # puts [api_ver, vn_idx, api_ver_num, unversioned].inspect

                next if ver.to_i > api_ver_num # Don't surface any newer views in an older API

                test_ver_num -= 1 until test_ver_num.zero? ||
                                        (view_relation = ::Brick.relations.fetch(
                                          found = "#{schema_prefix}v#{test_ver_num}_#{core_object_name}", nil
                                        ))
                api_done_views[unversioned] = nil # Mark that for this API version this view is done

                # puts "Found #{found}" if view_relation
                # If we haven't found "v3_view_name" or "v2_view_name" or so forth, at the last
                # fall back to simply looking for "v_view_name", and then finally  "view_name".
                no_v_prefix_name = "#{schema_prefix}#{core_object_name}"
                standard_prefix = 'v_'
              else
                core_object_name = object_name
              end
              if (rvp = ::Brick.config.api_remove_view_prefix) && core_object_name.start_with?(rvp)
                core_object_name.slice!(0, rvp.length)
              end
              no_prefix_name = "#{schema_prefix}#{core_object_name}"
              unversioned = "#{schema_prefix}#{standard_prefix}#{::Brick.config.api_add_view_prefix}#{core_object_name}"
            else
              unversioned = k
            end

            view_relation ||= ::Brick.relations.fetch(found = unversioned, nil) ||
                              (no_v_prefix_name && ::Brick.relations.fetch(found = no_v_prefix_name, nil)) ||
                              (no_prefix_name && ::Brick.relations.fetch(found = no_prefix_name, nil))
            if view_relation
              actions = view_relation.key?(:isView) ? [:index, :show] : ::Brick::ALL_API_ACTIONS # By default all actions are allowed
              # Call proc that limits which endpoints get surfaced based on version, table or view name, method (get list / get one / post / patch / delete)
              # Returning nil makes it do nothing, false makes it skip creating this endpoint, and an array of up to
              # these 3 things controls and changes the nature of the endpoint that gets built:
              # (updated api_name, name of different relation to route to, allowed actions such as :index, :show, :create, etc)
              proc_result = if (filter = ::Brick.config.api_filter).is_a?(Proc)
                              begin
                                num_args = filter.arity.negative? ? 6 : filter.arity
                                filter.call(*[unversioned, k, view_relation, actions, api_ver_num, found, test_ver_num][0...num_args])
                              rescue StandardError => e
                                puts "::Brick.api_filter Proc error: #{e.message}"
                              end
                            end
              # proc_result expects to receive back: [updated_api_name, to_other_relation, allowed_actions]

              case proc_result
              when NilClass
                # Do nothing differently than what normal behaviour would be
              when FalseClass # Skip implementing this endpoint
                view_relation[:api][api_ver_num] = nil
                next
              when Array # Did they give back an array of actions?
                unless proc_result.any? { |pr| ::Brick::ALL_API_ACTIONS.exclude?(pr) }
                  proc_result = [unversioned, to_relation, proc_result]
                end
                # Otherwise don't change this array because it's probably legit
              when String
                proc_result = [proc_result] # Treat this as the surfaced api_name (path) they want to use for this endpoint
              else
                puts "::Brick.api_filter Proc warning: Unable to parse this result returned: \n  #{proc_result.inspect}"
                proc_result = nil # Couldn't understand what in the world was returned
              end

              if proc_result&.present?
                if proc_result[1] # to_other_relation
                  if (new_view_relation = ::Brick.relations.fetch(proc_result[1], nil))
                    k = proc_result[1] # Route this call over to this different relation
                    view_relation = new_view_relation
                  else
                    puts "::Brick.api_filter Proc warning: Unable to find new suggested relation with name #{proc_result[1]} -- sticking with #{k} instead."
                  end
                end
                if proc_result.first&.!=(k) # updated_api_name -- a different name than this relation would normally have
                  found = proc_result.first
                end
                actions &= proc_result[2] if proc_result[2] # allowed_actions
              end
              (view_relation[:api][api_ver_num] ||= {})[unversioned] = actions # Add to the list of API paths this resource responds to

              # view_ver_num = if (first_part = k.split('_').first) =~ /^v[\d_]+/
              #                  first_part[1..-1].gsub('_', '.').to_i
              #                end
              controller_name = if (last = view_relation.fetch(:resource, nil)&.pluralize)
                                  "#{full_schema_prefix}#{last}"
                                else
                                  found
                                end.tr('.', '/')

              { :index => 'get', :create => 'post' }.each do |action, method|
                if actions.include?(action)
                  # Normally goes to something like:  /api/v1/employees
                  send(method, "#{api_root}#{unversioned.tr('.', '/')}", { to: "#{controller_prefix}#{controller_name}##{action}" })
                end
              end
              # %%% We do not yet surface the #show action
              if (id_col = view_relation[:pk]&.first) # ID-dependent stuff
                { :update => ['put', 'patch'], :destroy => ['delete'] }.each do |action, methods|
                  if actions.include?(action)
                    methods.each do |method|
                      send(method, "#{api_root}#{unversioned.tr('.', '/')}/:#{id_col}", { to: "#{controller_prefix}#{controller_name}##{action}" })
                    end
                  end
                end
              end
            end
          end

          # Trestle compatibility
          if Object.const_defined?('Trestle') && ::Trestle.config.options&.key?(:site_title) &&
             !Object.const_defined?("#{(res_name = resource_name.tr('/', '_')).camelize}Admin")
            begin
              ::Trestle.resource(res_sym = res_name.to_sym, model: class_name&.constantize) do
                menu { item res_sym, icon: "fa fa-star" }
              end
            rescue
            end
          end
        end

        if (named_routes = instance_variable_get(:@set).named_routes).respond_to?(:find)
          if ::Brick.config.add_status && (status_as = "#{controller_prefix.tr('/', '_')}brick_status".to_sym)
            (
              !(status_route = instance_variable_get(:@set).named_routes.find { |route| route.first == status_as }&.last) ||
              !status_route.ast.to_s.include?("/#{controller_prefix}brick_status/")
            )
            get("/#{controller_prefix}brick_status", to: 'brick_gem#status', as: status_as.to_s)
          end

          if ::Brick.config.add_orphans && (orphans_as = "#{controller_prefix.tr('/', '_')}brick_orphans".to_sym)
            (
              !(orphans_route = instance_variable_get(:@set).named_routes.find { |route| route.first == orphans_as }&.last) ||
              !orphans_route.ast.to_s.include?("/#{controller_prefix}brick_orphans/")
            )
            get("/#{controller_prefix}brick_orphans", to: 'brick_gem#orphans', as: 'brick_orphans')
          end
        end

        if instance_variable_get(:@set).named_routes.names.exclude?(:brick_crosstab)
          get("/#{controller_prefix}brick_crosstab", to: 'brick_gem#crosstab', as: 'brick_crosstab')
          get("/#{controller_prefix}brick_crosstab/data", to: 'brick_gem#crosstab_data')
        end

        if Object.const_defined?('Rswag::Ui')
          rswag_path = routeset_to_use.routes.find { |r| r.app.app == Rswag::Ui::Engine }&.instance_variable_get(:@path_formatter)&.instance_variable_get(:@parts)&.join
          first_endpoint_parts = nil
          (doc_endpoints = Rswag::Ui.config.config_object[:urls])&.each do |doc_endpoint|
            puts "Mounting OpenApi 3.0 documentation endpoint for \"#{doc_endpoint[:name]}\" on #{doc_endpoint[:url]}" unless ::Brick.routes_done
            send(:get, doc_endpoint[:url], { to: 'brick_openapi#index' })
            endpoint_parts = doc_endpoint[:url]&.split('/')
            first_endpoint_parts ||= endpoint_parts
          end
        end
        next if ::Brick.routes_done

        if Object.const_defined?('Rswag::Ui')
          if doc_endpoints.present?
            if rswag_path && first_endpoint_parts
              puts "API documentation now available when navigating to:  /#{first_endpoint_parts&.find(&:present?)}/index.html"
            else
              puts "In order to make documentation available you can put this into your routes.rb:"
              puts "  mount Rswag::Ui::Engine => '/#{first_endpoint_parts&.find(&:present?) || 'api-docs'}'"
            end
          else
            sample_path = rswag_path || '/api-docs'
            puts
            puts "Brick:  rswag-ui gem detected -- to make OpenAPI 3.0 documentation available from a path such as  '#{sample_path}/v1/swagger.json',"
            puts '        put code such as this in an initializer:'
            puts '  Rswag::Ui.configure do |config|'
            puts "    config.swagger_endpoint '#{sample_path}/v1/swagger.json', 'API V1 Docs'"
            puts '  end'
            unless rswag_path
              puts
              puts '        and put this into your routes.rb:'
              puts "  mount Rswag::Ui::Engine => '/api-docs'"
            end
          end
        end

        puts "\n" if tables.present? || views.present?
        if tables.present?
          puts "Classes that can be built from tables:#{' ' * (table_class_length - 38)}  Path:"
          puts "======================================#{' ' * (table_class_length - 38)}  ====="
          ::Brick.display_classes(controller_prefix, tables, table_class_length)
        end
        if views.present?
          puts "Classes that can be built from views:#{' ' * (view_class_length - 37)}  Path:"
          puts "=====================================#{' ' * (view_class_length - 37)}  ====="
          ::Brick.display_classes(controller_prefix, views, view_class_length)
        end
      end
      super
      ::Brick.routes_done = true
    end
  end

end

require 'brick/version_number'

# Older versions of ActiveRecord would only show more serious error information from "panic" level, which is
# a level only available in Postgres 12 and older.  This patch will allow older and newer versions of Postgres
# to work along with fairly old versions of Rails.
if (is_postgres = (Object.const_defined?('PG::VERSION') || Gem::Specification.find_all_by_name('pg').present?)) &&
   ActiveRecord.version < ::Gem::Version.new('4.2.6')
  ::Brick::Util._patch_require(
    'active_record/connection_adapters/postgresql_adapter.rb', '/activerecord', [
      ["'panic'", "'error'"],
      # ActiveRecord < 3.2.13 uses the pg_attrdef.adsrc column, but it's missing in Postgres 12 and later, so we need to use pg_get_expr(d.adbin, d.adrelid).
      [', d.adsrc,', ', pg_get_expr(d.adbin, d.adrelid),']
    ]
  )
end

require 'active_record'
require 'active_record/relation'
# To support adding left_outer_join
require 'active_record/relation/query_methods' if ActiveRecord.version < ::Gem::Version.new('5')
require 'rails/railtie' if ActiveRecord.version < ::Gem::Version.new('4.2')

# Rake tasks
class Railtie < ::Rails::Railtie
  Dir.glob("#{File.expand_path(__dir__)}/brick/tasks/**/*.rake").each { |task| load task }
end

# Rails < 4.2 does not have env
module ::Rails
  unless respond_to?(:env)
    def self.env
      @_env ||= ActiveSupport::StringInquirer.new(ENV["RAILS_ENV"] || ENV["RACK_ENV"] || "development")
    end

    def self.env=(environment)
      @_env = ActiveSupport::StringInquirer.new(environment)
    end
  end
end

# # Support for when a table or view is named just 's'
# ActiveSupport::Inflector.class_eval do
#   class << self
#     alias _brick_singularize singularize
#     def singularize(word, locale = :en)
#       if word.present? && ((ret = _brick_singularize(word, locale)).empty? || ret[-1] == '/')
#         # puts word
#         # binding.pry if ret.empty? || ret[-1] == '/'
#         ret << 's'
#       end
#       ret
#     end
#   end
# end

# Major compatibility fixes for ActiveRecord < 4.2
# ================================================
ActiveSupport.on_load(:active_record) do
  # rubocop:disable Lint/ConstantDefinitionInBlock
  module ActiveRecord
    class Base
      unless respond_to?(:execute_sql)
        class << self
          def execute_sql(sql, *param_array)
            param_array = param_array.first if param_array.length == 1 && param_array.first.is_a?(Array)
            if ['OracleEnhanced', 'SQLServer'].include?(ActiveRecord::Base.connection.adapter_name)
              connection.exec_query(send(:sanitize_sql_array, [sql] + param_array)).rows
            else
              connection.execute(send(:sanitize_sql_array, [sql] + param_array))
            end
          end
        end
      end
      # ActiveRecord < 4.2 does not have default_timezone
      # :singleton-method:
      # Determines whether to use Time.utc (using :utc) or Time.local (using :local) when pulling
      # dates and times from the database. This is set to :utc by default.
      unless respond_to?(:default_timezone)
        puts "ADDING!!! 4.w"
        mattr_accessor :default_timezone, instance_writer: false
        self.default_timezone = :utc
      end
    end

    # Rails < 4.0 cannot do #find_by, #find_or_create_by, or do #pluck on multiple columns, so here are the patches:
    if version < ::Gem::Version.new('4.0')
      # Normally find_by is in FinderMethods, which older AR doesn't have
      module Calculations
        def find_by(*args)
          where(*args).limit(1).to_a.first
        end

        def find_or_create_by(attributes, &block)
          find_by(attributes) || create(attributes, &block)
        end

        def pluck(*column_names)
          column_names.map! do |column_name|
            if column_name.is_a?(Symbol) && self.column_names.include?(column_name.to_s)
              "#{connection.quote_table_name(table_name)}.#{connection.quote_column_name(column_name)}"
            else
              column_name
            end
          end

          # Same as:  if has_include?(column_names.first)
          if eager_loading? || (includes_values.present? && (column_names.first || references_eager_loaded_tables?))
            construct_relation_for_association_calculations.pluck(*column_names)
          else
            relation = clone # spawn
            relation.select_values = column_names
            result = if klass.connection.class.name.end_with?('::PostgreSQLAdapter')
                       rslt = klass.execute_sql(relation.arel.to_sql)
                       rslt.type_map =
                         @type_map ||= proc do
                           # This aliasing avoids the warning:
                           # "no type cast defined for type "numeric" with oid 1700. Please cast this type
                           # explicitly to TEXT to be safe for future changes."
                           PG::BasicTypeRegistry.alias_type(0, 'numeric', 'text') # oid 1700
                           PG::BasicTypeRegistry.alias_type(0, 'time', 'text') # oid 1083
                           PG::BasicTypeMapForResults.new(klass.connection.raw_connection)
                         end.call
                       rslt.to_a
                     elsif respond_to?(:bind_values)
                       klass.connection.select_all(relation.arel, nil, bind_values)
                     else
                       klass.connection.select_all(relation.arel.to_sql, nil)
                     end
            if result.empty?
              []
            else
              columns = result.first.keys.map do |key|
                # rubocop:disable Style/SingleLineMethods Naming/MethodParameterName
                klass.columns_hash.fetch(key) do
                  Class.new { def type_cast(v); v; end }.new
                end
                # rubocop:enable Style/SingleLineMethods Naming/MethodParameterName
              end

              result = result.map do |attributes|
                columns.zip(klass.initialize_attributes(attributes).values).map do |column, value|
                  column.type_cast(value)
                end
              end
              columns.one? ? result.map!(&:first) : result
            end
          end
        end
      end

      unless Base.is_a?(Calculations)
        class Base
          class << self
            delegate :pluck, :find_by, :find_or_create_by, to: :scoped
          end
        end
      end

      # ActiveRecord < 3.2 doesn't have initialize_attributes, used by .pluck()
      unless AttributeMethods.const_defined?('Serialization')
        class Base
          class << self
            def initialize_attributes(attributes, options = {}) #:nodoc:
              serialized = (options.delete(:serialized) { true }) ? :serialized : :unserialized
              # super(attributes, options)

              serialized_attributes.each do |key, coder|
                attributes[key] = Attribute.new(coder, attributes[key], serialized) if attributes.key?(key)
              end

              attributes
            end
          end
        end
      end

      module Reflection
        # This only gets added for ActiveRecord < 3.2
        unless AssociationReflection.instance_methods.include?(:foreign_key)
          class AssociationReflection < MacroReflection
            alias foreign_key association_foreign_key
          end
        end
        # And this for ActiveRecord < 4.0
        unless AssociationReflection.instance_methods.include?(:polymorphic?)
          class AssociationReflection < MacroReflection
            def polymorphic?
              options[:polymorphic]
            end
          end
        end
      end

      # ActiveRecord 3.1 and 3.2 didn't try to bring in &block for the .extending() convenience thing
      # that smartens up scopes, and Ruby 2.7 complained loudly about just doing the magical "Proc.new"
      # that historically would just capture the incoming block.
      module QueryMethods
        unless instance_method(:extending).parameters.include?([:block, :block])
          # These first two lines used to be:
          # def extending(*modules)
          #   modules << Module.new(&Proc.new) if block_given?

          def extending(*modules, &block)
            modules << Module.new(&block) if block_given?

            return self if modules.empty?

            relation = clone
            relation.send(:apply_modules, modules.flatten)
            relation
          end
        end
      end

      # Same kind of thing for ActiveRecord::Scoping::Default#default_scope
      module Scoping
        module Default
          module ClassMethods
            if instance_methods.include?(:default_scope) &&
               !instance_method(:default_scope).parameters.include?([:block, :block])
              # Fix for AR 3.2-5.1
              def default_scope(scope = nil, &block)
                scope = block if block_given?

                if scope.is_a?(Relation) || !scope.respond_to?(:call)
                  raise ArgumentError,
                        'Support for calling #default_scope without a block is removed. For example instead ' \
                        "of `default_scope where(color: 'red')`, please use " \
                        "`default_scope { where(color: 'red') }`. (Alternatively you can just redefine " \
                        'self.default_scope.)'
                end

                self.default_scopes += [scope]
              end
            end
          end
        end
      end
    end

    # Migration stuff
    module ConnectionAdapters
      # Override the downcasing implementation from the OracleEnhanced gem as it has bad regex
      if const_defined?(:OracleEnhanced)
        module OracleEnhanced::Quoting
          private

          def oracle_downcase(column_name)
            return nil if column_name.nil?

            /^[A-Za-z0-9_]+$/ =~ column_name ? column_name.downcase : column_name
          end
        end
      end
      if const_defined?(:SQLServerAdapter)
        class SQLServer::TableDefinition
          alias _brick_new_column_definition new_column_definition
          def new_column_definition(name, type, **options)
            case type
            when :serial
              type = :integer
              options[:is_identity] = true
            when :bigserial
              type = :bigint
              options[:is_identity] = true
            end
            _brick_new_column_definition(name, type, **options)
          end
          def serial(*args)
            options = args.extract_options!
            options[:is_identity] = true
            args.each { |name| column(name, 'integer', options) }
          end
          def bigserial(*args)
            options = args.extract_options!
            options[:is_identity] = true
            args.each { |name| column(name, 'bigint', options) }
          end
          # Seems that geography gets used a fair bit in MSSQL
          def geography(*args)
            options = args.extract_options!
            # options[:precision] ||= 8
            # options[:scale] ||= 2
            args.each { |name| column(name, 'geography', options) }
          end
        end
        class SQLServerAdapter
          unless respond_to?(:schema_exists?)
            def schema_exists?(schema)
              schema_sql = 'SELECT 1 FROM sys.schemas WHERE name = ?'
              ActiveRecord::Base.execute_sql(schema_sql, schema).present?
            end
          end
        end
      end
    end
  end
  # rubocop:enable Lint/ConstantDefinitionInBlock

  if ruby_version >= ::Gem::Version.new('2.7') && ::ActiveRecord.const_defined?(:StatementCache) &&
     (arsc = ::ActiveRecord::StatementCache).respond_to?(:create) &&
     (params = arsc.method(:create).parameters).length == 2 && params.last == [:opt, :block]
    arsc.class_exec do
      def self.create(connection, callable = nil, &block)
        relation = (callable || block).call ::ActiveRecord::StatementCache::Params.new
        bind_map = ::ActiveRecord::StatementCache::BindMap.new(
                     # AR <= 4.2 uses relation.bind_values
                     relation.respond_to?(:bound_attributes) ? relation.bound_attributes : relation.bind_values
                   )
        options = [self, relation.arel]
        options.shift if connection.method(:cacheable_query).arity == 1 # Rails <= 5.0
        query_builder = connection.cacheable_query(*options)
        new query_builder, bind_map
      end
    end
  end

  # Rails < 4.2 is not innately compatible with Ruby 2.4 and later, and comes up with:
  # "TypeError: Cannot visit Integer" unless we patch like this:
  if ruby_version >= ::Gem::Version.new('2.4') &&
     Arel::Visitors.const_defined?('DepthFirst') &&
     !Arel::Visitors::DepthFirst.private_instance_methods.include?(:visit_Integer)
    module Arel
      module Visitors
        class DepthFirst < Visitor
          alias visit_Integer terminal
        end

        class Dot < Visitor
          alias visit_Integer visit_String
        end

        class ToSql < Visitor
        private

          # ActiveRecord before v3.2 uses Arel < 3.x, which does not have Arel#literal.
          unless private_instance_methods.include?(:literal)
            def literal(obj)
              obj
            end
          end
          alias visit_Integer literal
        end
      end
    end
  end

  unless DateTime.instance_methods.include?(:nsec)
    class DateTime < Date
      def nsec
        (sec_fraction * 1_000_000_000).to_i
      end
    end
  end

  if ActiveRecord.version < ::Gem::Version.new('6.1.4') &&
     Psych.method(:load).parameters.any? { |param| param.first == :key && param.last == :aliases }
    Psych.class_exec do
      class << self
        alias _original_load load
        def load(yaml, *args, **kwargs)
          if kwargs[:aliases].nil? && caller[0..4].any? { |line| line.end_with?("`database_configuration'") }
            kwargs[:aliases] = true
          end
          _original_load(yaml, *args, **kwargs)
        end
      end
    end
  end

  # def aliased_table_for(arel_table, table_name = nil)
  #   table_name ||= arel_table.name

  #   if aliases[table_name] == 0
  #     # If it's zero, we can have our table_name
  #     aliases[table_name] = 1
  #     arel_table = arel_table.alias(table_name) if arel_table.name != table_name
  #   else
  #     # Otherwise, we need to use an alias
  #     aliased_name = @connection.table_alias_for(yield)

  #     # Update the count
  #     count = aliases[aliased_name] += 1

  #     aliased_name = "#{truncate(aliased_name)}_#{count}" if count > 1

  #     arel_table = arel_table.alias(aliased_name)
  #   end

  #   arel_table
  # end
  # def aliased_table_for(table_name, aliased_name, type_caster)

  class ActiveRecord::Associations::JoinDependency
    if JoinBase.instance_method(:initialize).arity < 3 # Older ActiveRecord <= 5.1?
      def initialize(base, associations, joins, eager_loading: true)
        araat = ::ActiveRecord::Associations::AliasTracker
        if araat.respond_to?(:create_with_joins) # Rails 5.0 and 5.1
          cwj_options = [base.connection, base.table_name, joins]
          cwj_options << base.type_caster if araat.method(:create_with_joins).arity > 3 # Rails <= 5.1
          @alias_tracker = araat.create_with_joins(*cwj_options)
          @eager_loading = eager_loading # (Unused in Rails 5.0)
        elsif araat.respond_to?(:create) # Rails 4.1 and 4.2
          @alias_tracker = araat.create(base.connection, joins)
          @alias_tracker.aliased_table_for(base, base.table_name) # Updates the count for base.table_name to 1
        else # Rails <= 4.0
          is_rails_4 = true
          @base_klass    = base
          @table_joins   = joins
          @join_parts    = [JoinBase.new(base)]
          @associations  = {}
          @reflections   = []
          @alias_tracker = if araat.instance_method(:initialize).parameters.length == 2 # Rails > 3.2.8
                             araat.new(base.connection, joins)
                           else
                             araat.new(joins)
                           end
          @alias_tracker.aliased_name_for(base.table_name) # Updates the count for base.table_name to 1
          tree = build(associations)
        end
        tree ||= self.class.make_tree associations

        # Provide a way to find the original relation that this tree is being used for
        # (so that we can maintain a list of links for all tables used in JOINs)
        if (relation = associations.instance_variable_get(:@relation))
          tree.instance_variable_set(:@relation, relation)
        end
        return if is_rails_4 # Rails <= 4.0 doesn't know about the rest

        @join_root = JoinBase.new base, build(tree, base)
        @join_root.children.each { |child| construct_tables! @join_root, child }
      end

    else # For ActiveRecord 5.2 - 7.1

      def initialize(base, table, associations, join_type = nil)
        tree = self.class.make_tree associations

        # Provide a way to find the original relation that this tree is being used for
        # (so that we can maintain a list of links for all tables used in JOINs)
        if (relation = associations.instance_variable_get(:@relation))
          tree.instance_variable_set(:@relation, relation)
        end

        @join_root = JoinBase.new(base, table, build(tree, base))
        @join_type = join_type if join_type
      end
    end
  end

  # was:  ActiveRecord.version >= ::Gem::Version.new('3.2') &&
  if ActiveRecord.version < ::Gem::Version.new('5.0')
    module ActiveRecord
      # Final pieces for left_outer_joins support, which was derived from this commit:
      # https://github.com/rails/rails/commit/3f46ef1ddab87482b730a3f53987e04308783d8b
      module Associations
        class JoinDependency
          def make_left_outer_joins(parent, child)
            tables    = child.tables
            join_type = Arel::Nodes::OuterJoin
            info      = make_constraints parent, child, tables, join_type

            [info] + child.children.flat_map { |c| make_left_outer_joins(child, c) }
          end
        end
      end
      module Querying
        delegate :left_outer_joins, to: :all
      end
      class Relation
        alias :model :klass unless respond_to?(:model) # To support AR < 4.2
        unless MULTI_VALUE_METHODS.include?(:left_outer_joins)
          _multi_value_methods = MULTI_VALUE_METHODS + [:left_outer_joins]
          send(:remove_const, :MULTI_VALUE_METHODS)
          MULTI_VALUE_METHODS = _multi_value_methods
        end
      end
      module QueryMethods
        attr_writer :left_outer_joins_values
        def left_outer_joins_values
          @left_outer_joins_values ||= []
        end

        def left_outer_joins(*args)
          check_if_method_has_arguments!(:left_outer_joins, args)

          args.compact!
          args.flatten!

          spawn.left_outer_joins!(*args)
        end

        def left_outer_joins!(*args) # :nodoc:
          self.left_outer_joins_values += args
          self
        end

        def build_left_outer_joins(manager, outer_joins)
          buckets = outer_joins.group_by do |join|
            case join
            when Hash, Symbol, Array
              :association_join
            else
              raise ArgumentError, 'only Hash, Symbol and Array are allowed'
            end
          end

          build_join_query(manager, buckets, Arel::Nodes::OuterJoin)
        end
      end
      # (End of left_outer_joins support)
    end
  end

  # include ::Brick::Extensions

  # unless ::Brick::Extensions::IS_AMOEBA
  #   # Add amoeba-compatible support
  #   module ActiveRecord
  #     class Base
  #       def self.amoeba(*args)
  #         puts "Amoeba called from #{name} with #{args.inspect}"
  #       end
  #     end
  #   end
  # end
end

# Do this earlier because stuff here gets mixed into JoinDependency::JoinAssociation and AssociationScope
if is_postgres && ActiveRecord.version < ::Gem::Version.new('5.0') # Was:  && Object.const_defined?('PG::Connection')
  require 'pg' # For ActiveRecord < 4.2
  # Avoid pg gem deprecation warning:  "You should use PG::Connection, PG::Result, and PG::Error instead"
  PGconn = PG::Connection
  PGresult = PG::Result
  PGError = PG::Error
end

if ActiveRecord.version < ::Gem::Version.new('5.2')
  # Specifically for AR 3.1 and 3.2 to avoid:  "undefined method `delegate' for ActiveRecord::Reflection::ThroughReflection:Class"
  require 'active_support/core_ext/module/delegation' if ActiveRecord.version < ::Gem::Version.new('4.0')
  module ActiveRecord
    module Reflection
      # AR < 4.0 doesn't know about join_table and derive_join_table
      unless AssociationReflection.instance_methods.include?(:join_table)
        class AssociationReflection < MacroReflection
          def join_table
            @join_table ||= options[:join_table] || derive_join_table
          end

        private

          def derive_join_table
            [active_record.table_name, klass.table_name].sort.join("\0").gsub(/^(.*[._])(.+)\0\1(.+)/, '\1\2_\3').gsub("\0", '_')
          end
        end
      end
    end
  end
end

# By default the awesome_nested_set gem from CollectiveIdea does not prefix the ORDER BY column with its table name.
# You can see this snag in action in the popular Spree project -- check out the Taxonomy model.  Here is a fix:
if Gem::Specification.all_names.find { |g| g.start_with?('awesome_nested_set-') }
  require 'awesome_nested_set/columns'
  ::CollectiveIdea::Acts::NestedSet::Columns.class_exec do
    alias _brick_order_column_name order_column_name
    def order_column_name
      unless (ord_col = _brick_order_column_name).start_with?(tbl_prefix = +"#{table_name}.")
        ord_col = tbl_prefix << ord_col
      end
      ord_col
    end
  end
end

# The "brick_links" patch -- this finds how every AR chain of association names
# relates back to an exact table correlation name chosen by AREL when the AST tree is
# walked.  For instance, from a Customer model there could be a join_tree such as
# { orders: { line_items: :product} }, which would end up recording three entries, the
# last of which for products would have a key of "orders.line_items.product" after
# having gone through two HMs and one BT.  AREL would have chosen a correlation name of
# "products", being able to use the same name as the table name because it's the first
# time that table is used in this query.  But let's see what happens if each customer
# also had a BT to a favourite product, referenced earlier in the join_tree like this:
# [:favourite_product, orders: { line_items: :product}] -- then the second reference to
# "products" would end up being called "products_line_items" in order to differentiate
# it from the first reference, which would have already snagged the simpler name
# "products".  It's essential that The Brick can find accurate correlation names when
# there are multiple JOINs to the same table.
module ActiveRecord
  module QueryMethods
  private

    if private_instance_methods.include?(:build_join_query)
      alias _brick_build_join_query build_join_query
      def build_join_query(manager, buckets, *args) # , **kwargs)
        # %%% Better way to bring relation into the mix
        if (aj = buckets.fetch(:association_join, nil))
          aj.instance_variable_set(:@relation, self)
        end

        _brick_build_join_query(manager, buckets, *args) # , **kwargs)
      end

    elsif private_instance_methods.include?(:select_association_list)
      alias _brick_select_association_list select_association_list
      def select_association_list(associations, stashed_joins = nil)
        result = _brick_select_association_list(associations, stashed_joins)
        result.instance_variable_set(:@relation, self)
        result
      end

    # else # Rails 4.1 ? and older
    #   alias _brick_build_joins build_joins
    #   def build_joins(manager, joins)
    #     result = _brick_build_joins(manager, joins)
    #     result.instance_variable_set(:@relation, self)
    #     result
    #   end
    end
  end

  # require 'active_record/associations/join_dependency'
  module Associations
    if self.const_defined?('JoinHelper') # ActiveRecord < 4.1
      module JoinHelper
        alias _brick_construct_tables construct_tables
        def construct_tables
          result = _brick_construct_tables
          # Capture the table alias name that was chosen
          # if (relation = node.instance_variable_get(:@assocs)&.instance_variable_get(:@relation))
          #   link_path = node.instance_variable_get(:@link_path)
          #   relation.brick_links[link_path] = result.first.table_alias || result.first.table_name
          # end
          result
        end
      end
    else # For AR >= 4.2
      class JoinDependency
        # An intelligent .eager_load() and .includes() that creates t0_r0 style aliases only for the columns
        # used in .select().  To enable this behaviour, include the flag :_brick_eager_load as the first
        # entry in your .select().
        # More information:  https://discuss.rubyonrails.org/t/includes-and-select-for-joined-data/81640
        def apply_column_aliases(relation)
          if !(@join_root_alias = relation.select_values.empty?) &&
             relation.select_values.first.to_s == '_brick_eager_load'
            relation.select_values.shift
            used_cols = {}
            # Find and expand out all column names being used in select(...)
            new_select_values = relation.select_values.map(&:to_s).each_with_object([]) do |col, s|
              if col.include?(' ') # Some expression? (No chance for a simple column reference)
                s << col # Just pass it through
              else
                col = if (col_parts = col.split('.')).length == 1
                        [col]
                      else
                        [col_parts[0..-2].join('.'), col_parts.last]
                      end
                used_cols[col] = nil
              end
            end
            if new_select_values.present?
              relation.select_values = new_select_values
            else
              relation.select_values.clear
            end

            @aliases ||= Aliases.new(join_root.each_with_index.map do |join_part, i|
              join_alias = join_part.table&.table_alias || join_part.table_name
              keys = [join_part.base_klass.primary_key] # Always include the primary key

              # # %%% Optional to include all foreign keys:
              # keys.concat(join_part.base_klass.reflect_on_all_associations.select { |a| a.belongs_to? }.map(&:foreign_key))

              # Add foreign keys out to referenced tables that we belongs_to
              join_part.children.each { |child| keys << child.reflection.foreign_key if child.reflection.belongs_to? }

              # Add the foreign key that got us here -- "the train we rode in on" -- if we arrived from
              # a has_many or has_one:
              if join_part.is_a?(ActiveRecord::Associations::JoinDependency::JoinAssociation) &&
                 !join_part.reflection.belongs_to?
                keys << join_part.reflection.foreign_key
              end
              keys = keys.compact # In case we're using composite_primary_keys
              j = 0
              columns = join_part.column_names.each_with_object([]) do |column_name, s|
                # Include columns chosen in select(...) as well as the PK and any relevant FKs
                if used_cols.keys.find { |c| (c.length == 1 || c.first == join_alias) && c.last == column_name } ||
                   keys.find { |c| c == column_name }
                  s << Aliases::Column.new(column_name, "t#{i}_r#{j}")
                end
                j += 1
              end
              Aliases::Table.new(join_part, columns)
            end)
          end

          relation._select!(-> { aliases.columns })
        end

      private

        # %%% Pretty much have to flat-out replace this guy (I think anyway)
        # Good with Rails 5.24 through 7 on this
        # Ransack gem includes Polyamorous which replaces #build in a different way (which we handle below)
        unless Gem::Specification.all_names.any? { |g| g.start_with?('ransack-') }
          def build(associations, base_klass, root = nil, path = '')
            root ||= associations
            associations.map do |name, right|
              reflection = find_reflection base_klass, name
              reflection.check_validity!
              reflection.check_eager_loadable! if reflection.respond_to?(:check_eager_loadable!) # Used in AR >= 4.2

              if reflection.polymorphic?
                raise EagerLoadPolymorphicError.new(reflection)
              end

              link_path = path.blank? ? name.to_s : path + ".#{name}"
              ja = JoinAssociation.new(reflection, build(right, reflection.klass, root, link_path))
              ja.instance_variable_set(:@link_path, link_path) # Make note on the JoinAssociation of its AR path
              ja.instance_variable_set(:@assocs, root)
              ja
            end
          end
        end

        # No matter if it's older or newer Rails, now extend so that we can associate AR links to table_alias names
        if ActiveRecord.version < ::Gem::Version.new('6.1')
          alias _brick_table_aliases_for table_aliases_for
          def table_aliases_for(parent, node)
            result = _brick_table_aliases_for(parent, node)
            # Capture the table alias name that was chosen
            if (relation = node.instance_variable_get(:@assocs)&.instance_variable_get(:@relation))
              link_path = node.instance_variable_get(:@link_path)
              relation.brick_links[link_path] = result.first.table_alias || result.first.table_name
            end
            result
          end
        else # Same idea but for Rails >= 6.1
          alias _brick_make_constraints make_constraints
          def make_constraints(parent, child, join_type)
            result = _brick_make_constraints(parent, child, join_type)
            # Capture the table alias name that was chosen
            if (relation = child.instance_variable_get(:@assocs)&.instance_variable_get(:@relation))
              link_path = child.instance_variable_get(:@link_path)
              relation.brick_links[link_path] = if child.table.is_a?(Arel::Nodes::TableAlias)
                                                  child.table.right
                                                else
                                                  # Was:  result.first&.left&.table_alias || child.table_name
                                                  child.table.table_alias || child.table_name
                                                end
            end
            result
          end
        end
      end
    end
  end
end

# Now the Ransack Polyamorous version of #build
if Gem::Specification.all_names.any? { |g| g.start_with?('ransack-') }
  require "polyamorous/activerecord_#{::ActiveRecord::VERSION::STRING[0, 3]}_ruby_2/join_dependency"
  module Polyamorous::JoinDependencyExtensions
    def build(associations, base_klass, root = nil, path = '')
      root ||= associations
      # puts associations.map(&:first)

      associations.map do |name, right|
        link_path = path.blank? ? name.to_s : path + ".#{name}"
        ja = if name.is_a? ::Polyamorous::Join
               reflection = find_reflection base_klass, name.name
               reflection.check_validity!
               reflection.check_eager_loadable!

               klass = if reflection.polymorphic?
                         name.klass || base_klass
                       else
                         reflection.klass
                       end
               ::ActiveRecord::Associations::JoinDependency::JoinAssociation.new(
                 reflection, build(right, klass, root, link_path), name.klass, name.type
               )
             else
               reflection = find_reflection base_klass, name
               reflection.check_validity!
               reflection.check_eager_loadable!

               if reflection.polymorphic?
                 raise ActiveRecord::EagerLoadPolymorphicError.new(reflection)
               end
               ::ActiveRecord::Associations::JoinDependency::JoinAssociation.new(
                 reflection, build(right, reflection.klass, root, link_path)
               )
             end
        ja.instance_variable_set(:@link_path, link_path) # Make note on the JoinAssociation of its AR path
        ja.instance_variable_set(:@assocs, root)
        ja
      end
    end
  end
end

# Patch Enumerize so that #becomes works when an STI subclass is becoming a base class
# which does not include Enumerize.
# (See https://github.com/brainspec/enumerize/issues/426)
if Object.const_defined?('Enumerize') && Enumerize.const_defined?('ActiveRecordSupport')
  Enumerize::ActiveRecordSupport::InstanceMethods.class_exec do
    def becomes(klass)
      became = super
      klass = self.class unless klass.respond_to?(:enumerized_attributes)
      klass.enumerized_attributes.each do |attr|
        begin
          if became.respond_to?(setter = "#{attr.name}=")
            became.send(setter, send(attr.name))
          end
        rescue ActiveModel::MissingAttributeError
        rescue ActiveRecord::SerializationTypeMismatch
          became.send(setter, send(attr.name).to_ary)
        end
      end
      became
    end
  end
end

# Keyword arguments updates for Rails <= 5.2.x and Ruby >= 3.0
if ActiveRecord.version < ::Gem::Version.new('6.0') && ruby_version >= ::Gem::Version.new('3.0')
  admsm = ActionDispatch::MiddlewareStack::Middleware
  admsm.class_exec do
    # redefine #build
    def build(app, **kwargs)
      # puts klass.name
      if args.length > 1 && args.last.is_a?(Hash)
        kwargs.merge!(args.pop)
      end
      # binding.pry if klass == ActionDispatch::Static # ActionDispatch::Reloader
      klass.new(app, *args, **kwargs, &block)
    end
  end

  require 'active_model'
  begin
    require 'active_model/type'
    require 'active_model/type/value'
    class ActiveModel::Type::Value
      def initialize(*args, precision: nil, limit: nil, scale: nil)
        @precision = precision
        @scale = scale
        @limit = limit
      end
    end
  rescue LoadError => e # AR <= 4.2 doesn't have ActiveModel::Type
  end

  if Object.const_defined?('I18n')
    module I18n::Base
      alias _brick_translate translate
      def translate(key = nil, *args, throw: false, raise: false, locale: nil, **options)
        options.merge!(args.pop) if args.last.is_a?(Hash)
        _brick_translate(key = nil, throw: false, raise: false, locale: nil, **options)
      end
    end
  end

  module ActionController::RequestForgeryProtection
  private

    # Creates the authenticity token for the current request.
    def form_authenticity_token(*args, form_options: {}) # :doc:
      if method(:masked_authenticity_token).arity == 1
        masked_authenticity_token(session) # AR <= 4.2 doesn't use form_options
      else
        form_options.merge!(args.pop) if args.last.is_a?(Hash)
        masked_authenticity_token(session, form_options: form_options)
      end
    end
  end

  module ActiveSupport
    class MessageEncryptor
      def encrypt_and_sign(value, *args, expires_at: nil, expires_in: nil, purpose: nil)
        encrypted = if method(:_encrypt).arity == 1
                      _encrypt(value) # Rails <= 5.1
                    else
                      if args.last.is_a?(Hash)
                        expires_at ||= args.last[:expires_at]
                        expires_in ||= args.last[:expires_in]
                        purpose ||= args.last[:purpose]
                      end
                      _encrypt(value, expires_at: expires_at, expires_in: expires_in, purpose: purpose)
                    end
        verifier.generate(encrypted)
      end
    end
    if const_defined?('Messages')
      class Messages::Metadata
        def self.wrap(message, *args, expires_at: nil, expires_in: nil, purpose: nil)
          if args.last.is_a?(Hash)
            expires_at ||= args.last[:expires_at]
            expires_in ||= args.last[:expires_in]
            purpose ||= args.last[:purpose]
          end
          if expires_at || expires_in || purpose
            JSON.encode new(encode(message), pick_expiry(expires_at, expires_in), purpose)
          else
            message
          end
        end
      end
    end
  end
end

require 'brick/extensions'
