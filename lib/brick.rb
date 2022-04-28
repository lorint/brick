# frozen_string_literal: true

require 'active_record/version'

# ActiveRecord before 4.0 didn't have #version
unless ActiveRecord.respond_to?(:version)
  module ActiveRecord
    def self.version
      ::Gem::Version.new(ActiveRecord::VERSION::STRING)
    end
  end
end

# In ActiveSupport older than 5.0, the duplicable? test tries to new up a BigDecimal,
# and Ruby 2.6 and later deprecates #new.  This removes the warning from BigDecimal.
require 'bigdecimal'
if (ruby_version = ::Gem::Version.new(RUBY_VERSION)) >= ::Gem::Version.new('2.6') &&
   ActiveRecord.version < ::Gem::Version.new('5.0')
  def BigDecimal.new(*args, **kwargs)
    BigDecimal(*args, **kwargs)
  end
end

# Allow ActiveRecord 4.0 and 4.1 to work with newer Ruby (>= 2.4) by avoiding a "stack level too deep"
# error when ActiveSupport tries to smarten up Numeric by messing with Fixnum and Bignum at the end of:
# activesupport-4.0.13/lib/active_support/core_ext/numeric/conversions.rb
if ActiveRecord.version < ::Gem::Version.new('4.2') &&
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
if ActiveRecord.version < ::Gem::Version.new('3.2') &&
   ruby_version >= ::Gem::Version.new('2.7')
  # Remove circular reference for "now"
  ::Brick::Util._patch_require(
    'active_support/values/time_zone.rb', '/activesupport',
    '  def parse(str, now=now)',
    '  def parse(str, now=now())'
  )
  # Remove circular reference for "reflection" for ActiveRecord 3.1
  if ActiveRecord.version >= ::Gem::Version.new('3.1')
    ::Brick::Util._patch_require(
      'active_record/associations/has_many_association.rb', '/activerecord',
      'reflection = reflection)',
      'reflection = reflection())',
      :HasManyAssociation # Make sure the path for this guy is available to be autoloaded
    )
  end
end

# puts ::Brick::Util._patch_require(
#     'cucumber/cli/options.rb', '/cucumber/cli/options', # /cli/options
#     '  def extract_environment_variables',
#     "  def extract_environment_variables\n
#     puts 'Patch test!'"
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
  def self.sti_models
    @sti_models ||= {}
  end

  class << self
    attr_accessor :db_schemas

    def set_db_schema(params)
      schema = params['_brick_schema'] || 'public'
      ActiveRecord::Base.connection.execute("SET SEARCH_PATH='#{schema}';") if schema && ::Brick.db_schemas&.include?(schema)
    end

    # All tables and views (what Postgres calls "relations" including column and foreign key info)
    def relations
      connections = Brick.instance_variable_get(:@relations) ||
        Brick.instance_variable_set(:@relations, (connections = {}))
      # Key our list of relations for this connection off of the connection pool's object_id
      (connections[ActiveRecord::Base.connection_pool.object_id] ||= Hash.new { |h, k| h[k] = Hash.new { |h, k| h[k] = {} } })
    end

    def get_bts_and_hms(model)
      bts, hms = model.reflect_on_all_associations.each_with_object([{}, {}]) do |a, s|
        next if !const_defined?(a.name.to_s.singularize.camelize) && ::Brick.config.exclude_tables.include?(a.plural_name)

        # So that we can map an association name to any special alias name used in an AREL query
        ans = (model._assoc_names[a.name] ||= [])
        ans << a.klass unless ans.include?(a.klass)
        case a.macro
        when :belongs_to
          s.first[a.foreign_key] = [a.name, a.klass]
        when :has_many, :has_one # This gets has_many as well as has_many :through
          # %%% weed out ones that don't have an available model to reference
          s.last[a.name] = a
        end
      end
      # Mark has_manys that go to an associative ("join") table so that they are skipped in the UI,
      # as well as any possible polymorphic associations
      skip_hms = {}
      associatives = hms.each_with_object({}) do |hmt, s|
        if (through = hmt.last.options[:through])
          skip_hms[through] = nil
          s[hmt.first] = hms[through] # End up with a hash of HMT names pointing to join-table associations
        elsif hmt.last.inverse_of.nil?
          puts "SKIPPING #{hmt.last.name.inspect}"
          # %%% If we don't do this then below associative.name will find that associative is nil
          skip_hms[hmt.last.name] = nil
        end
      end
      skip_hms.each do |k, _v|
        puts hms.delete(k).inspect
      end
      [bts, hms, associatives]
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

    # Load additional references (virtual foreign keys)
    # This is attempted early if a brick initialiser file is found, and then again as a failsafe at the end of our engine's initialisation
    # %%% Maybe look for differences the second time 'round and just add new stuff instead of entirely deferring
    def load_additional_references
      return if @_additional_references_loaded

      if (ars = ::Brick.config.additional_references)
        ars.each { |fk| ::Brick._add_bt_and_hm(fk[0..2]) }
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
  end

  module RouteSet
    def finalize!
      existing_controllers = routes.each_with_object({}) { |r, s| c = r.defaults[:controller]; s[c] = nil if c }
      ::Rails.application.routes.append do
        # %%% TODO: If no auto-controllers then enumerate the controllers folder in order to build matching routes
        # If auto-controllers and auto-models are both enabled then this makes sense:
        ::Brick.relations.each do |k, v|
          unless existing_controllers.key?(controller_name = k.underscore.pluralize)
            options = {}
            options[:only] = [:index, :show] if v.key?(:isView)
            send(:resources, controller_name.to_sym, **options)
          end
        end
      end
      super
    end
  end

end

require 'brick/version_number'

require 'active_record'
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
            connection.execute(send(:sanitize_sql_array, [sql] + param_array))
          end
        end
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
                       rslt = klass.connection.execute(relation.arel.to_sql)
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
                values = klass.initialize_attributes(attributes).values

                columns.zip(values).map do |column, value|
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
if ActiveRecord.version < ::Gem::Version.new('5.0') && Object.const_defined?('PG::Connection')
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
