# frozen_string_literal: true

require 'brick/compatibility'

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

# Allow ActiveRecord < 3.2 to work with Ruby 2.7 and later
if (ruby_version = ::Gem::Version.new(RUBY_VERSION)) >= ::Gem::Version.new('2.7')
  if ActiveRecord.version < ::Gem::Version.new('3.2')
    # Remove circular reference for "now"
    ::Brick::Util._patch_require(
      'active_support/values/time_zone.rb', '/activesupport',
      ['  def parse(str, now=now)',
      '  def parse(str, now=now())']
    )
    # Remove circular reference for "reflection" for ActiveRecord 3.1
    if ActiveRecord.version >= ::Gem::Version.new('3.1')
      ::Brick::Util._patch_require(
        'active_record/associations/has_many_association.rb', '/activerecord',
        ['reflection = reflection)',
        'reflection = reflection())'],
        :HasManyAssociation # Make sure the path for this guy is available to be autoloaded
      )
    end
  end

  # # Create unfrozen route path in Rails 3.2
  # if ActiveRecord.version < ::Gem::Version.new('4')
  #   ::Brick::Util._patch_require(
  #     'action_dispatch/routing/route_set.rb', '/actiondispatch',
  #     ["script_name.chomp('/')).to_s",
  #      "script_name.chomp('/')).to_s.dup"],
  #     :RouteSet # Make sure the path for this guy is available to be autoloaded
  #   )
  # end
end

# Add left_outer_join! to Associations::JoinDependency and Relation::QueryMethods
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
    ['join_infos = join_dependency.join_constraints stashed_association_joins',
    'join_infos = join_dependency.join_constraints stashed_association_joins, join_type'
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
  class << self
    def sti_models
      @sti_models ||= {}
    end

    def existing_stis
      @existing_stis ||= Brick.config.sti_namespace_prefixes.each_with_object({}) { |snp, s| s[snp.first[2..-1]] = snp.last unless snp.first.end_with?('::') }
    end

    attr_accessor :default_schema, :db_schemas, :routes_done, :is_oracle, :is_eager_loading, :auto_models

    def set_db_schema(params = nil)
      schema = (params ? params['_brick_schema'] : ::Brick.default_schema)
      if schema && ::Brick.db_schemas&.key?(schema)
        ActiveRecord::Base.execute_sql("SET SEARCH_PATH = ?;", schema)
        schema
      elsif ActiveRecord::Base.connection.adapter_name == 'PostgreSQL'
        # Just return the current schema
        orig_schema = ActiveRecord::Base.execute_sql('SELECT current_schemas(true)').first['current_schemas'][1..-2].split(',')
        # ::Brick.apartment_multitenant && tbl_parts.first == Apartment.default_schema
        (orig_schema - ['pg_catalog']).first
      end
    end

    # All tables and views (what Postgres calls "relations" including column and foreign key info)
    def relations
      # Key our list of relations for this connection off of the connection pool's object_id
      (@relations ||= {})[ActiveRecord::Base.connection_pool.object_id] ||= Hash.new { |h, k| h[k] = Hash.new { |h, k| h[k] = {} } }
    end

    def apartment_multitenant
      if @apartment_multitenant.nil?
        @apartment_multitenant = ::Brick.config.schema_behavior[:multitenant] && Object.const_defined?('Apartment')
      end
      @apartment_multitenant
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

    def get_bts_and_hms(model)
      bts, hms = model.reflect_on_all_associations.each_with_object([{}, {}]) do |a, s|
        next if !const_defined?(a.name.to_s.singularize.camelize) && ::Brick.config.exclude_tables.include?(a.plural_name)

        case a.macro
        when :belongs_to
          if a.polymorphic?
            rel_poly_bt = relations[model.table_name][:fks].find { |_k, fk| fk[:assoc_name] == a.name.to_s }
            if (primary_tables = rel_poly_bt&.last&.fetch(:inverse_table, [])).is_a?(Array)
              models = primary_tables&.map { |table| table.singularize.camelize.constantize }
              s.first[a.foreign_key] = [a.name, models, true]
            else
              # This will come up when using Devise invitable when invited_by_class_name is not
              # specified because in that circumstance it adds a polymorphic :invited_by association,
              # along with appropriate invited_by_type and invited_by_id columns.
              puts "Missing any real indication as to which models \"has_many\" this polymorphic BT in model #{a.active_record.name}:"
              puts "  belongs_to :#{a.name}, polymorphic: true"
            end
          else
            s.first[a.foreign_key] = [a.name, a.klass]
          end
        when :has_many, :has_one # This gets has_many as well as has_many :through
          # %%% weed out ones that don't have an available model to reference
          s.last[a.name] = a
        end
      end
      # Mark has_manys that go to an associative ("join") table so that they are skipped in the UI,
      # as well as any possible polymorphic associations
      skip_hms = {}
      hms.each do |hmt|
        if (through = hmt.last.options[:through])
          # ::Brick.relations[hmt.last.through_reflection.table_name]
          skip_hms[through] = nil if hms[through] && model.is_brick?
          # End up with a hash of HMT names pointing to join-table associations
          model._br_associatives[hmt.first] = hms[through] # || hms["#{(opt = hmt.last.options)[:through].to_s.singularize}_#{opt[:source].to_s.pluralize}".to_sym]
        elsif hmt.last.inverse_of.nil?
          puts "SKIPPING #{hmt.last.name.inspect}"
          # %%% If we don't do this then below associative.name will find that associative is nil
          skip_hms[hmt.last.name] = nil
        end
      end
      skip_hms.each { |k, _v| hms.delete(k) }
      [bts, hms]
    end

    def exclude_column(table, col)
      puts "Excluding #{table}.#{col}"
      true
    end
    def unexclude_column(table, col)
      puts "Unexcluding #{table}.#{col}"
      true
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
      Brick.config.api_root = path
    end

    # @api public
    def api_root
      Brick.config.api_root
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

    # Load additional references (virtual foreign keys)
    # This is attempted early if a brick initialiser file is found, and then again as a failsafe at the end of our engine's initialisation
    # %%% Maybe look for differences the second time 'round and just add new stuff instead of entirely deferring
    def load_additional_references
      return if @_additional_references_loaded

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
              if relations.key?(primary_table = type.underscore.pluralize)
                ::Brick._add_bt_and_hm([nil, table_name, poly, nil, primary_table, "(brick) #{table_name}_#{poly}"], relations, true, is_optional)
              else
                missing_stis[primary_table] = type unless ::Brick.existing_stis.key?(type)
              end
            end
          end
          unless missing_stis.empty?
            print "
You might be missing an STI namespace prefix entry for these tables:  #{missing_stis.keys.join(', ')}.
In config/initializers/brick.rb appropriate entries would look something like:
  Brick.sti_namespace_prefixes = {"
            puts missing_stis.map { |_k, missing_sti| "\n    '::#{missing_sti}' => 'SomeParentModel'" }.join(',')
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
        ::Rails.configuration.eager_load_namespaces.select { |ns| ns < ::Rails::Application }.each(&:eager_load!)
      else
        Zeitwerk::Loader.eager_load_all
      end
      abstract_ar_bases = if do_ar_abstract_bases
                            ActiveRecord::Base.descendants.select { |ar| ar.abstract_class? }.map(&:name)
                          end
      ::Brick.is_eager_loading = false
      abstract_ar_bases
    end

    def display_classes(prefix, rels, max_length)
      rels.sort.each do |rel|
        (::Brick.auto_models ||= []) << rel.first
        puts "#{rel.first}#{' ' * (max_length - rel.first.length)}  /#{prefix}#{rel.last}"
      end
      puts "\n"
    end
  end

  module RouteSet
    def finalize!
      unless ::Rails.application.routes.named_routes.route_defined?(:brick_status_path)
        path_prefix = ::Brick.config.path_prefix
        existing_controllers = routes.each_with_object({}) do |r, s|
          c = r.defaults[:controller]
          s[c] = nil if c
        end
        ::Rails.application.routes.append do
          tables = []
          views = []
          table_class_length = 38 # Length of "Classes that can be built from tables:"
          view_class_length = 37 # Length of "Classes that can be built from views:"

          brick_routes_create = lambda do |schema_name, controller_name, v, options|
            if schema_name # && !Object.const_defined('Apartment')
              send(:namespace, schema_name) do
                send(:resources, v[:resource].to_sym, **options)
              end
            else
              send(:resources, v[:resource].to_sym, **options)
            end
          end

          # %%% TODO: If no auto-controllers then enumerate the controllers folder in order to build matching routes
          # If auto-controllers and auto-models are both enabled then this makes sense:
          controller_prefix = (path_prefix ? "#{path_prefix}/" : '')
          ::Brick.relations.each do |k, v|
            unless !(controller_name = v.fetch(:resource, nil)&.pluralize) || existing_controllers.key?(controller_name)
              options = {}
              options[:only] = [:index, :show] if v.key?(:isView)
              # First do the API routes
              full_resource = nil
              if (schema_name = v.fetch(:schema, nil))
                full_resource = "#{schema_name}/#{v[:resource]}"
                send(:get, "#{::Brick.api_root}#{full_resource}", { to: "#{controller_prefix}#{schema_name}/#{controller_name}#index" }) if Object.const_defined?('Rswag::Ui')
              else
                # Normally goes to something like:  /api/v1/employees
                send(:get, "#{::Brick.api_root}#{v[:resource]}", { to: "#{controller_prefix}#{controller_name}#index" }) if Object.const_defined?('Rswag::Ui')
              end
              # Now the normal routes
              if path_prefix
                # Was:  send(:scope, path: path_prefix) do
                send(:namespace, path_prefix) do
                  brick_routes_create.call(schema_name, controller_name, v, options)
                end
              else
                brick_routes_create.call(schema_name, controller_name, v, options)
              end

              if (class_name = v.fetch(:class_name, nil))
                if v.key?(:isView)
                  view_class_length = class_name.length if class_name.length > view_class_length
                  views
                else
                  table_class_length = class_name.length if class_name.length > table_class_length
                  tables
                end << [class_name, full_resource || v[:resource]]
              end
            end
          end

          if ::Brick.config.add_status && instance_variable_get(:@set).named_routes.names.exclude?(:brick_status)
            get("/#{controller_prefix}brick_status", to: 'brick_gem#status', as: 'brick_status')
          end

          if ::Brick.config.add_orphans && instance_variable_get(:@set).named_routes.names.exclude?(:brick_orphans)
            get("/#{controller_prefix}brick_orphans", to: 'brick_gem#orphans', as: 'brick_orphans')
          end

          unless ::Brick.routes_done
            if Object.const_defined?('Rswag::Ui')
              rswag_path = ::Rails.application.routes.routes.find { |r| r.app.app == Rswag::Ui::Engine }&.instance_variable_get(:@path_formatter)&.instance_variable_get(:@parts)&.join
              if (doc_endpoint = Rswag::Ui.config.config_object[:urls]&.last)
                puts "Mounting OpenApi 3.0 documentation endpoint for \"#{doc_endpoint[:name]}\" on #{doc_endpoint[:url]}"
                send(:get, doc_endpoint[:url], { to: 'brick_openapi#index' })
                endpoint_parts = doc_endpoint[:url]&.split('/')
                if rswag_path && endpoint_parts
                  puts "API documentation now available when navigating to:  /#{endpoint_parts&.find(&:present?)}/index.html"
                else
                  puts "In order to make documentation available you can put this into your routes.rb:"
                  puts "  mount Rswag::Ui::Engine => '/#{endpoint_parts&.find(&:present?) || 'api-docs'}'"
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

            ::Brick.routes_done = true
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
        end
      end
      super
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
    'active_record/connection_adapters/postgresql_adapter.rb', '/activerecord', ["'panic'", "'error'"]
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

      # This only gets added for ActiveRecord < 3.2
      module Reflection
        unless AssociationReflection.instance_methods.include?(:foreign_key)
          class AssociationReflection < MacroReflection
            alias foreign_key association_foreign_key
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

  # First part of arel_table_type stuff:
  # ------------------------------------
  # (more found below)
  # was:  ActiveRecord.version >= ::Gem::Version.new('3.2') &&
  if ActiveRecord.version < ::Gem::Version.new('5.0')
    # Used by Util#_arel_table_type
    module ActiveRecord
      class Base
        def self.arel_table
          @arel_table ||= Arel::Table.new(table_name, arel_engine).tap do |x|
            x.instance_variable_set(:@_arel_table_type, self)
          end
        end
      end

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

# More arel_table_type stuff:
# ---------------------------
if ActiveRecord.version < ::Gem::Version.new('5.2')
  # Specifically for AR 3.1 and 3.2 to avoid:  "undefined method `delegate' for ActiveRecord::Reflection::ThroughReflection:Class"
  require 'active_support/core_ext/module/delegation' if ActiveRecord.version < ::Gem::Version.new('4.0')
  # Used by Util#_arel_table_type
  # rubocop:disable Style/CommentedKeyword
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

    module Associations
      # Specific to AR 4.2 - 5.1:
      if Associations.const_defined?('JoinDependency') && JoinDependency.private_instance_methods.include?(:table_aliases_for)
        class JoinDependency
        private

          if ActiveRecord.version < ::Gem::Version.new('5.1') # 4.2 or 5.0
            def table_aliases_for(parent, node)
              node.reflection.chain.map do |reflection|
                alias_tracker.aliased_table_for(
                  reflection.table_name,
                  table_alias_for(reflection, parent, reflection != node.reflection)
                ).tap do |x|
                  # %%% Specific only to Rails 4.2 (and maybe 4.1?)
                  x = x.left if x.is_a?(Arel::Nodes::TableAlias)
                  y = reflection.chain.find { |c| c.table_name == x.name }
                  x.instance_variable_set(:@_arel_table_type, y.klass)
                end
              end
            end
          end
        end
      elsif Associations.const_defined?('JoinHelper') && JoinHelper.private_instance_methods.include?(:construct_tables)
        module JoinHelper
        private

          # AR > 3.0 and < 4.2 (%%% maybe only < 4.1?) uses construct_tables like this:
          def construct_tables
            tables = []
            chain.each do |reflection|
              tables << alias_tracker.aliased_table_for(
                table_name_for(reflection),
                table_alias_for(reflection, reflection != self.reflection)
              ).tap do |x|
                x = x.left if x.is_a?(Arel::Nodes::TableAlias)
                x.instance_variable_set(:@_arel_table_type, reflection.chain.find { |c| c.table_name == x.name }.klass)
              end

              next unless reflection.source_macro == :has_and_belongs_to_many

              tables << alias_tracker.aliased_table_for(
                (reflection.source_reflection || reflection).join_table,
                table_alias_for(reflection, true)
              )
            end
            tables
          end
        end
      end
    end
  end # module ActiveRecord
  # rubocop:enable Style/CommentedKeyword
end

require 'brick/extensions'
