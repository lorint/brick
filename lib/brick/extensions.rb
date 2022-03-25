# frozen_string_literal: true

# Have markers on HM relationships to indicate "load this one every time" or "lazy load it" or "don't bother"
# Others on BT to indicate "this is a lookup"

# Mark specific tables as being lookups and they get put on the main screen as an editable thing
# If they relate to multiple different things (like looking up countries or something) then they only get edited from the main page, and importing new addresses can create a new country if needed.
# Indications of how relationships should operate will be useful soon (lookup is one kind, but probably more other kinds like this stuff makes a table or makes a list or who knows what.)
# Security must happen now -- at the model level, really low AR level automatically applied.

# Similar to .includes or .joins or something, bring in all records related through a HM, and include them in a trim way in a block of JSON
# Javascript thing that automatically makes nested table things from a block of hierarchical data (maybe sorta use one dimension of the crosstab thing)

# Finally incorporate the crosstab so that many dimensions can be set up as columns or rows and be made editable.

# X or Y axis can be made as driven by either columns or a row of data, so traditional table or crosstab can be shown, or a hybrid kind of thing of the two.

# Sensitive stuff -- make a lock icon thing so people don't accidentally edit stuff

# Static text that can go on pages - headings and footers and whatever
# Eventually some indication about if it should be a paginated table / unpaginated / a list of just some fields / etc

# Grid where each cell is one field and then when you mouse over then it shows a popup other table of detail inside

# DSL that describes the rows / columns and then what each cell can have, which could be nested related data, the specifics of X and Y driving things in the cell definition like a formula

# colour coded origins

# Drag something like TmfModel#name onto the rows and have it automatically add five columns -- where type=zone / where type = section / etc

# Support for Postgres / MySQL enums (add enum to model, use model enums to make a drop-down in the UI)

# Currently quadrupling up routes

# ==========================================================
# Dynamically create model or controller classes when needed
# ==========================================================

# By default all models indicate that they are not views
module ActiveRecord
  class Base
    def self.is_view?
      false
    end

    # Used to show a little prettier name for an object
    def brick_descrip
      klass = self.class
      # If available, parse simple DSL attached to a model in order to provide a friendlier name.
      # Object property names can be referenced in square brackets like this:
      # { 'User' => '[profile.firstname] [profile.lastname]' }

      # If there's no DSL yet specified, just try to find the first usable column on this model
      unless ::Brick.config.model_descrips[klass.name]
        descrip_col = (klass.columns.map(&:name) - klass._brick_get_fks -
                      (::Brick.config.metadata_columns || []) -
                      [klass.primary_key]).first
        ::Brick.config.model_descrips[klass.name] = "[#{descrip_col}]" if descrip_col
      end
      if (dsl ||= ::Brick.config.model_descrips[klass.name])
        caches = {}
        output = +''
        is_brackets_have_content = false
        bracket_name = nil
        dsl.each_char do |ch|
          if bracket_name
            if ch == ']' # Time to process a bracketed thing?
              obj_name = +''
              obj = self
              bracket_name.split('.').each do |part|
                obj_name += ".#{part}"
                obj = if caches.key?(obj_name)
                        caches[obj_name]
                      else
                        (caches[obj_name] = obj&.send(part.to_sym))
                      end
              end
              is_brackets_have_content = true unless (obj&.to_s).blank?
              output << (obj&.to_s || '')
              bracket_name = nil
            else
              bracket_name << ch
            end
          elsif ch == '['
            bracket_name = +''
          else
            output << ch
          end
        end
        output += bracket_name if bracket_name
      end
      if is_brackets_have_content
        output
      elsif klass.primary_key
        "#{klass.name} ##{send(klass.primary_key)}"
      else
        to_s
      end
    end

  private

    def self._brick_get_fks
      @_brick_get_fks ||= reflect_on_all_associations.select { |a2| a2.macro == :belongs_to }.map(&:foreign_key)
    end
  end

  class Relation
    def brick_where(params)
      wheres = {}
      rel_joins = []
      params.each do |k, v|
        case (ks = k.split('.')).length
        when 1
          next unless klass._brick_get_fks.include?(k)
        when 2
          assoc_name = ks.first.to_sym
          # Make sure it's a good association name and that the model has that column name
          next unless klass.reflect_on_association(assoc_name)&.klass&.columns&.map(&:name)&.include?(ks.last)

          rel_joins << assoc_name unless rel_joins.include?(assoc_name)
        end
        wheres[k] = v.split(',')
      end
      unless wheres.empty?
        where!(wheres)
        joins!(rel_joins) unless rel_joins.empty?
        wheres # Return the specific parameters that we did use
      end
    end
  end

  module Inheritance
    module ClassMethods
      private

      alias _brick_find_sti_class find_sti_class
      def find_sti_class(type_name)
        if ::Brick.sti_models.key?(type_name)
          _brick_find_sti_class(type_name)
        else
          # This auto-STI is more of a brute-force approach, building modules where needed
          # The more graceful alternative is the overload of ActiveSupport::Dependencies#autoload_module! found below
          ::Brick.sti_models[type_name] = { base: self } unless type_name.blank?
          module_prefixes = type_name.split('::')
          module_prefixes.unshift('') unless module_prefixes.first.blank?
          module_name = module_prefixes[0..-2].join('::')
          if ::Brick.config.sti_namespace_prefixes&.key?(module_name) ||
             ::Brick.config.sti_namespace_prefixes&.key?(module_name[2..-1]) # Take off the leading '::' and see if this matches
            _brick_find_sti_class(type_name)
          elsif File.exists?(candidate_file = Rails.root.join('app/models' + module_prefixes.map(&:underscore).join('/') + '.rb'))
            _brick_find_sti_class(type_name) # Find this STI class normally
          else
            # Build missing prefix modules if they don't yet exist
            this_module = Object
            module_prefixes[1..-2].each do |module_name|
              mod = if this_module.const_defined?(module_name)
                      this_module.const_get(module_name)
                    else
                      this_module.const_set(module_name.to_sym, Module.new)
                    end
            end
            # Build STI subclass and place it into the namespace module
            this_module.const_set(module_prefixes.last.to_sym, klass = Class.new(self))
            klass
          end
        end
      end
    end
  end
end

module ActiveSupport::Dependencies
  class << self
    # %%% Probably a little more targeted than other approaches we've taken thusfar
    # This happens before the whole parent check
    alias _brick_autoload_module! autoload_module!
    def autoload_module!(*args)
      into, const_name, qualified_name, path_suffix = args
      if (base_class = ::Brick.config.sti_namespace_prefixes&.fetch(into.name, nil)&.constantize)
        ::Brick.sti_models[qualified_name] = { base: base_class }
        # Build subclass and place it into the specially STI-namespaced module
        into.const_set(const_name.to_sym, klass = Class.new(base_class))
        # %%% used to also have:  autoload_once_paths.include?(base_path) || 
        autoloaded_constants << qualified_name unless autoloaded_constants.include?(qualified_name)
        klass
      else
        _brick_autoload_module!(*args)
      end
    end
  end
end

class Object
  class << self
    alias _brick_const_missing const_missing
    def const_missing(*args)
      return self.const_get(args.first) if self.const_defined?(args.first)
      return Object.const_get(args.first) if Object.const_defined?(args.first) unless self == Object

      class_name = args.first.to_s
      # See if a file is there in the same way that ActiveSupport::Dependencies#load_missing_constant
      # checks for it in ~/.rvm/gems/ruby-2.7.5/gems/activesupport-5.2.6.2/lib/active_support/dependencies.rb
      # that is, checking #qualified_name_for with:  from_mod, const_name
      # If we want to support namespacing in the future, might have to utilise something like this:
      # path_suffix = ActiveSupport::Dependencies.qualified_name_for(Object, args.first).underscore
      # return self._brick_const_missing(*args) if ActiveSupport::Dependencies.search_for_file(path_suffix)
      # If the file really exists, go and snag it:
      if !(is_found = ActiveSupport::Dependencies.search_for_file(class_name.underscore)) && (filepath = self.name&.split('::'))
        filepath = (filepath[0..-2] + [class_name]).join('/').underscore + '.rb'
      end
      if is_found
        return self._brick_const_missing(*args)
      elsif ActiveSupport::Dependencies.search_for_file(filepath) # Last-ditch effort to pick this thing up before we fill in the gaps on our own
        my_const = parent.const_missing(class_name) # ends up having:  MyModule::MyClass
        return my_const
      end

      relations = ::Brick.instance_variable_get(:@relations)[ActiveRecord::Base.connection_pool.object_id] || {}
      is_controllers_enabled = ::Brick.enable_controllers? || (ENV['RAILS_ENV'] || ENV['RACK_ENV'])  == 'development'
      result = if is_controllers_enabled && class_name.end_with?('Controller') && (plural_class_name = class_name[0..-11]).length.positive?
                 # Otherwise now it's up to us to fill in the gaps
                 if (model = ActiveSupport::Inflector.singularize(plural_class_name).constantize)
                   # if it's a controller and no match or a model doesn't really use the same table name, eager load all models and try to find a model class of the right name.
                   build_controller(class_name, plural_class_name, model, relations)
                 end
               elsif ::Brick.enable_models?
                 # See if a file is there in the same way that ActiveSupport::Dependencies#load_missing_constant
                 # checks for it in ~/.rvm/gems/ruby-2.7.5/gems/activesupport-5.2.6.2/lib/active_support/dependencies.rb
                 plural_class_name = ActiveSupport::Inflector.pluralize(model_name = class_name)
                 singular_table_name = ActiveSupport::Inflector.underscore(model_name)
 
                 # Adjust for STI if we know of a base model for the requested model name
                 table_name = if (base_model = ::Brick.sti_models[model_name]&.fetch(:base, nil))
                               base_model.table_name
                             else
                               ActiveSupport::Inflector.pluralize(singular_table_name)
                             end
 
                 # Maybe, just maybe there's a database table that will satisfy this need
                 if (matching = [table_name, singular_table_name, plural_class_name, model_name].find { |m| relations.key?(m) })
                   build_model(model_name, singular_table_name, table_name, relations, matching)
                 end
               end
      if result
        built_class, code = result
        puts "\n#{code}"
        built_class
      elsif ::Brick.config.sti_namespace_prefixes&.key?(class_name)
#         module_prefixes = type_name.split('::')
#         path = self.name.split('::')[0..-2] + []
#         module_prefixes.unshift('') unless module_prefixes.first.blank?
#         candidate_file = Rails.root.join('app/models' + module_prefixes.map(&:underscore).join('/') + '.rb')
        self._brick_const_missing(*args)
      else
        puts "MISSING! #{args.inspect} #{table_name}"
        self._brick_const_missing(*args)
      end
    end

  private

    def build_model(model_name, singular_table_name, table_name, relations, matching)
      return if ((is_view = (relation = relations[matching]).key?(:isView)) && ::Brick.config.skip_database_views) ||
                ::Brick.config.exclude_tables.include?(matching)

      # Are they trying to use a pluralised class name such as "Employees" instead of "Employee"?
      if table_name == singular_table_name && !ActiveSupport::Inflector.inflections.uncountable.include?(table_name)
        puts "Warning: Class name for a model that references table \"#{matching}\" should be \"#{ActiveSupport::Inflector.singularize(model_name)}\"."
        return
      end
      if (base_model = ::Brick.sti_models[model_name]&.fetch(:base, nil))
        is_sti = true
      else
        base_model = ::Brick.config.models_inherit_from || ActiveRecord::Base
      end
      code = +"class #{model_name} < #{base_model.name}\n"
      built_model = Class.new(base_model) do |new_model_class|
        Object.const_set(model_name.to_sym, new_model_class)
        # Accommodate singular or camel-cased table names such as "order_detail" or "OrderDetails"
        code << "  self.table_name = '#{self.table_name = matching}'\n" unless table_name == matching

        # Override models backed by a view so they return true for #is_view?
        # (Dynamically-created controllers and view templates for such models will then act in a read-only way)
        if is_view
          new_model_class.define_singleton_method :'is_view?' do
            true
          end
          code << "  def self.is_view?; true; end\n"
        end

        # Missing a primary key column?  (Usually "id")
        ar_pks = primary_key.is_a?(String) ? [primary_key] : primary_key || []
        db_pks = relation[:cols]&.map(&:first)
        has_pk = ar_pks.length.positive? && (db_pks & ar_pks).sort == ar_pks.sort
        our_pks = relation[:pkey].values.first
        # No primary key, but is there anything UNIQUE?
        # (Sort so that if there are multiple UNIQUE constraints we'll pick one that uses the least number of columns.)
        our_pks = relation[:ukeys].values.sort { |a, b| a.length <=> b.length }.first unless our_pks&.present?
        if has_pk
          code << "  # Primary key: #{ar_pks.join(', ')}\n" unless ar_pks == ['id']
        elsif our_pks&.present?
          if our_pks.length > 1 && respond_to?(:'primary_keys=') # Using the composite_primary_keys gem?
            new_model_class.primary_keys = our_pks
            code << "  self.primary_keys = #{our_pks.map(&:to_sym).inspect}\n"
          else
            new_model_class.primary_key = (pk_sym = our_pks.first.to_sym)
            code << "  self.primary_key = #{pk_sym.inspect}\n"
          end
        else
          code << "  # Could not identify any column(s) to use as a primary key\n" unless is_view
        end

        unless is_sti
          fks = relation[:fks] || {}
          # Do the bulk of the has_many / belongs_to processing, and store details about HMT so they can be done at the very last
          hmts = fks.each_with_object(Hash.new { |h, k| h[k] = [] }) do |fk, hmts|
            # The key in each hash entry (fk.first) is the constraint name
            assoc_name = (assoc = fk.last)[:assoc_name]
            inverse_assoc_name = assoc[:inverse]&.fetch(:assoc_name, nil)
            options = {}
            singular_table_name = ActiveSupport::Inflector.singularize(assoc[:inverse_table])
            macro = if assoc[:is_bt]
                      need_class_name = singular_table_name.underscore != assoc_name
                      need_fk = "#{assoc_name}_id" != assoc[:fk]
                      if (inverse = assoc[:inverse])
                        inverse_assoc_name, _x = _brick_get_hm_assoc_name(relations[assoc[:inverse_table]], inverse)
                        if (has_ones = ::Brick.config.has_ones&.fetch(inverse[:alternate_name].camelize, nil))&.key?(singular_inv_assoc_name = ActiveSupport::Inflector.singularize(inverse_assoc_name))
                          inverse_assoc_name = if has_ones[singular_inv_assoc_name]
                                                need_inverse_of = true
                                                has_ones[singular_inv_assoc_name]
                                              else
                                                singular_inv_assoc_name
                                              end
                        end
                      end
                      :belongs_to
                    else
                      # need_class_name = ActiveSupport::Inflector.singularize(assoc_name) == ActiveSupport::Inflector.singularize(table_name.underscore)
                      # Are there multiple foreign keys out to the same table?
                      assoc_name, need_class_name = _brick_get_hm_assoc_name(relation, assoc)
                      need_fk = "#{ActiveSupport::Inflector.singularize(assoc[:inverse][:inverse_table])}_id" != assoc[:fk]
                      # fks[table_name].find { |other_assoc| other_assoc.object_id != assoc.object_id && other_assoc[:assoc_name] == assoc[assoc_name] }
                      if (has_ones = ::Brick.config.has_ones&.fetch(model_name, nil))&.key?(singular_assoc_name = ActiveSupport::Inflector.singularize(assoc_name))
                        assoc_name = if has_ones[singular_assoc_name]
                                      need_class_name = true
                                      has_ones[singular_assoc_name]
                                    else
                                      singular_assoc_name
                                    end
                        :has_one
                      else
                        :has_many
                      end
                    end
            # Figure out if we need to specially call out the class_name and/or foreign key
            # (and if either of those then definitely also a specific inverse_of)
            options[:class_name] = singular_table_name.camelize if need_class_name
            # Work around a bug in CPK where self-referencing belongs_to associations double up their foreign keys
            if need_fk # Funky foreign key?
              options[:foreign_key] = if assoc[:fk].is_a?(Array)
                                        assoc_fk = assoc[:fk].uniq
                                        assoc_fk.length < 2 ? assoc_fk.first : assoc_fk
                                      else
                                        assoc[:fk].to_sym
                                      end
            end
            options[:inverse_of] = inverse_assoc_name.to_sym if inverse_assoc_name && (need_class_name || need_fk || need_inverse_of)

            # Prepare a list of entries for "has_many :through"
            if macro == :has_many
              relations[assoc[:inverse_table]][:hmt_fks].each do |k, hmt_fk|
                next if k == assoc[:fk]

                hmts[ActiveSupport::Inflector.pluralize(hmt_fk.last)] << [assoc, hmt_fk.first]
              end
            end

            # And finally create a has_one, has_many, or belongs_to for this association
            assoc_name = assoc_name.to_sym
            code << "  #{macro} #{assoc_name.inspect}#{options.map { |k, v| ", #{k}: #{v.inspect}" }.join}\n"
            self.send(macro, assoc_name, **options)
            hmts
          end
          hmts.each do |hmt_fk, fks|
            fks.each do |fk|
              source = nil
              this_hmt_fk = if fks.length > 1
                              singular_assoc_name = ActiveSupport::Inflector.singularize(fk.first[:inverse][:assoc_name])
                              source = fk.last
                              through = ActiveSupport::Inflector.pluralize(fk.first[:alternate_name])
                              "#{singular_assoc_name}_#{hmt_fk}"
                            else
                              through = fk.first[:assoc_name]
                              hmt_fk
                            end
              code << "  has_many :#{this_hmt_fk}, through: #{(assoc_name = through.to_sym).to_sym.inspect}#{", source: :#{source}" if source}\n"
              options = { through: assoc_name }
              options[:source] = source.to_sym if source
              self.send(:has_many, this_hmt_fk.to_sym, **options)
            end
          end
        end
        code << "end # model #{model_name}\n\n"
      end # class definition
      [built_model, code]
    end

    def build_controller(class_name, plural_class_name, model, relations)
      table_name = ActiveSupport::Inflector.underscore(plural_class_name)
      singular_table_name = ActiveSupport::Inflector.singularize(table_name)

      code = +"class #{class_name} < ApplicationController\n"
      built_controller = Class.new(ActionController::Base) do |new_controller_class|
        Object.const_set(class_name.to_sym, new_controller_class)

        code << "  def index\n"
        code << "    @#{table_name} = #{model.name}#{model.primary_key ? ".order(#{model.primary_key.inspect})" : '.all'}\n"
        code << "    @#{table_name}.brick_where(params)\n"
        code << "  end\n"
        self.define_method :index do
          ::Brick.set_db_schema(params)
          ar_relation = model.primary_key ? model.order(model.primary_key) : model.all
          instance_variable_set(:@_brick_params, ar_relation.brick_where(params))
          instance_variable_set("@#{table_name}".to_sym, ar_relation)
        end

        if model.primary_key
          code << "  def show\n"
          code << "    @#{singular_table_name} = #{model.name}.find(params[:id].split(','))\n"
          code << "  end\n"
          self.define_method :show do
            ::Brick.set_db_schema(params)
            instance_variable_set("@#{singular_table_name}".to_sym, model.find(params[:id].split(',')))
          end
        end

        # By default, views get marked as read-only
        unless (relation = relations[model.table_name]).key?(:isView)
          code << "  # (Define :new, :create, :edit, :update, and :destroy)\n"
          # Get column names for params from relations[model.table_name][:cols].keys
        end
        code << "end # #{class_name}\n\n"
      end # class definition
      [built_controller, code]
    end

    def _brick_get_hm_assoc_name(relation, hm_assoc)
      if relation[:hm_counts][hm_assoc[:assoc_name]]&.> 1
        [ActiveSupport::Inflector.pluralize(hm_assoc[:alternate_name]), true]
      else
        [ActiveSupport::Inflector.pluralize(hm_assoc[:inverse_table]), nil]
      end
    end
  end
end

# ==========================================================
# Get info on all relations during first database connection
# ==========================================================

module ActiveRecord::ConnectionHandling
  alias _brick_establish_connection establish_connection
  def establish_connection(*args)
    conn = _brick_establish_connection(*args)
    _brick_reflect_tables
    conn
  end

  def _brick_reflect_tables
      if (relations = ::Brick.relations).empty?
      # Only for Postgres?  (Doesn't work in sqlite3)
      # puts ActiveRecord::Base.connection.execute("SELECT current_setting('SEARCH_PATH')").to_a.inspect

    schema_sql = 'SELECT NULL AS table_schema;'
    case ActiveRecord::Base.connection.adapter_name
      when 'PostgreSQL'
        schema = 'public'
        schema_sql = 'SELECT DISTINCT table_schema FROM INFORMATION_SCHEMA.tables;'
      when 'Mysql2'
        schema = ActiveRecord::Base.connection.current_database
      when 'SQLite'
        sql = "SELECT m.name AS relation_name, UPPER(m.type) AS table_type,
          p.name AS column_name, p.type AS data_type,
          CASE p.pk WHEN 1 THEN 'PRIMARY KEY' END AS const
        FROM sqlite_master AS m
          INNER JOIN pragma_table_info(m.name) AS p
        WHERE m.name NOT IN ('ar_internal_metadata', 'schema_migrations')
        ORDER BY m.name, p.cid"
      else
        puts "Unfamiliar with connection adapter #{ActiveRecord::Base.connection.adapter_name}"
      end

      sql ||= ActiveRecord::Base.send(:sanitize_sql_array, [
        "SELECT t.table_name AS relation_name, t.table_type,
          c.column_name, c.data_type,
          COALESCE(c.character_maximum_length, c.numeric_precision) AS max_length,
          tc.constraint_type AS const, kcu.constraint_name AS \"key\"
        FROM INFORMATION_SCHEMA.tables AS t
          LEFT OUTER JOIN INFORMATION_SCHEMA.columns AS c ON t.table_schema = c.table_schema
            AND t.table_name = c.table_name
          LEFT OUTER JOIN INFORMATION_SCHEMA.KEY_COLUMN_USAGE AS kcu ON
            -- ON kcu.CONSTRAINT_CATALOG = t.table_catalog AND
            kcu.CONSTRAINT_SCHEMA = c.table_schema
            AND kcu.TABLE_NAME = c.table_name
            AND kcu.position_in_unique_constraint IS NULL
            AND kcu.ordinal_position = c.ordinal_position
          LEFT OUTER JOIN INFORMATION_SCHEMA.table_constraints AS tc
            ON kcu.CONSTRAINT_SCHEMA = tc.CONSTRAINT_SCHEMA
            AND kcu.TABLE_NAME = tc.TABLE_NAME
            AND kcu.CONSTRAINT_NAME = tc.constraint_name
        WHERE t.table_schema = ? -- COALESCE(current_setting('SEARCH_PATH'), 'public')
  --          AND t.table_type IN ('VIEW') -- 'BASE TABLE', 'FOREIGN TABLE'
          AND t.table_name NOT IN ('pg_stat_statements', 'ar_internal_metadata', 'schema_migrations')
        ORDER BY 1, t.table_type DESC, c.ordinal_position", schema
      ])

      measures = []
      case ActiveRecord::Base.connection.adapter_name
      when 'PostgreSQL', 'SQLite' # These bring back a hash for each row because the query uses column aliases
        ActiveRecord::Base.connection.execute(sql).each do |r|
          # next if internal_views.include?(r['relation_name']) # Skip internal views such as v_all_assessments
          relation = relations[(relation_name = r['relation_name'])]
          relation[:isView] = true if r['table_type'] == 'VIEW'
          col_name = r['column_name']
          key = case r['const']
                when 'PRIMARY KEY'
                  relation[:pkey][r['key'] || relation_name] ||= []
                when 'UNIQUE'
                  relation[:ukeys][r['key'] || "#{relation_name}.#{col_name}"] ||= []
                  # key = (relation[:ukeys] = Hash.new { |h, k| h[k] = [] }) if key.is_a?(Array)
                  # key[r['key']]
                end
          key << col_name if key
          cols = relation[:cols] # relation.fetch(:cols) { relation[:cols] = [] }
          cols[col_name] = [r['data_type'], r['max_length'], measures&.include?(col_name)]
          # puts "KEY! #{r['relation_name']}.#{col_name} #{r['key']} #{r['const']}" if r['key']
        end
      else # MySQL2 acts a little differently, bringing back an array for each row
        ActiveRecord::Base.connection.execute(sql).each do |r|
          # next if internal_views.include?(r['relation_name']) # Skip internal views such as v_all_assessments
          relation = relations[(relation_name = r[0])] # here relation represents a table or view from the database
          relation[:isView] = true if r[1] == 'VIEW' # table_type
          col_name = r[2]
          key = case r[5] # constraint type
                when 'PRIMARY KEY'
                  # key
                  relation[:pkey][r[6] || relation_name] ||= []
                when 'UNIQUE'
                  relation[:ukeys][r[6] || "#{relation_name}.#{col_name}"] ||= []
                  # key = (relation[:ukeys] = Hash.new { |h, k| h[k] = [] }) if key.is_a?(Array)
                  # key[r['key']]
                end
          key << col_name if key
          cols = relation[:cols] # relation.fetch(:cols) { relation[:cols] = [] }
          # 'data_type', 'max_length'
          cols[col_name] = [r[3], r[4], measures&.include?(col_name)]
          # puts "KEY! #{r['relation_name']}.#{col_name} #{r['key']} #{r['const']}" if r['key']
        end
      end

      case ActiveRecord::Base.connection.adapter_name
      when 'PostgreSQL', 'Mysql2'
        sql = ActiveRecord::Base.send(:sanitize_sql_array, [
          "SELECT kcu1.TABLE_NAME, kcu1.COLUMN_NAME, kcu2.TABLE_NAME AS primary_table, kcu1.CONSTRAINT_NAME
          FROM INFORMATION_SCHEMA.REFERENTIAL_CONSTRAINTS AS rc
            INNER JOIN INFORMATION_SCHEMA.KEY_COLUMN_USAGE AS kcu1
              ON kcu1.CONSTRAINT_CATALOG = rc.CONSTRAINT_CATALOG
              AND kcu1.CONSTRAINT_SCHEMA = rc.CONSTRAINT_SCHEMA
              AND kcu1.CONSTRAINT_NAME = rc.CONSTRAINT_NAME
            INNER JOIN INFORMATION_SCHEMA.KEY_COLUMN_USAGE AS kcu2
              ON kcu2.CONSTRAINT_CATALOG = rc.UNIQUE_CONSTRAINT_CATALOG
              AND kcu2.CONSTRAINT_SCHEMA = rc.UNIQUE_CONSTRAINT_SCHEMA
              AND kcu2.CONSTRAINT_NAME = rc.UNIQUE_CONSTRAINT_NAME
              AND kcu2.ORDINAL_POSITION = kcu1.ORDINAL_POSITION
          WHERE kcu1.CONSTRAINT_SCHEMA = ? -- COALESCE(current_setting('SEARCH_PATH'), 'public')", schema
          # AND kcu2.TABLE_NAME = ?;", Apartment::Tenant.current, table_name
        ])
      when 'SQLite'
        sql = "SELECT m.name, fkl.\"from\", fkl.\"table\", m.name || '_' || fkl.\"from\" AS constraint_name
        FROM sqlite_master m
          INNER JOIN pragma_foreign_key_list(m.name) fkl ON m.type = 'table'
        ORDER BY m.name, fkl.seq"
      else
      end
      if sql
        ::Brick.db_schemas = ActiveRecord::Base.connection.execute(schema_sql)
        ::Brick.db_schemas = ::Brick.db_schemas.to_a unless ::Brick.db_schemas.is_a?(Array)
        ::Brick.db_schemas.map! { |row| row['table_schema'] } unless ::Brick.db_schemas.empty? || ::Brick.db_schemas.first.is_a?(String)
        ::Brick.db_schemas -= ['information_schema', 'pg_catalog']
        ActiveRecord::Base.connection.execute(sql).each do |fk|
          fk = fk.values unless fk.is_a?(Array)
          ::Brick._add_bt_and_hm(fk, relations)
        end
      end
    end

    puts "\nClasses that can be built from tables:"
    relations.select { |_k, v| !v.key?(:isView) }.keys.each { |k| puts ActiveSupport::Inflector.singularize(k).camelize }
    unless (views = relations.select { |_k, v| v.key?(:isView) }).empty?
      puts "\nClasses that can be built from views:"
      views.keys.each { |k| puts ActiveSupport::Inflector.singularize(k).camelize }
    end
    # pp relations; nil

    # relations.keys.each { |k| ActiveSupport::Inflector.singularize(k).camelize.constantize }
    # Layout table describes permissioned hierarchy throughout
  end
end

# ==========================================

# :nodoc:
module Brick
  # rubocop:disable Style/CommentedKeyword
  module Extensions
    MAX_ID = Arel.sql('MAX(id)')
    IS_AMOEBA = Gem.loaded_specs['amoeba']

    def self.included(base)
      base.send :extend, ClassMethods
    end

    # :nodoc:
    module ClassMethods

    private

    end
  end # module Extensions
  # rubocop:enable Style/CommentedKeyword

  class << self
    def _add_bt_and_hm(fk, relations = nil)
      relations ||= ::Brick.relations
      bt_assoc_name = fk[1].underscore
      bt_assoc_name = bt_assoc_name[0..-4] if bt_assoc_name.end_with?('_id')

      bts = (relation = relations.fetch(fk[0], nil))&.fetch(:fks) { relation[:fks] = {} }
      hms = (relation = relations.fetch(fk[2], nil))&.fetch(:fks) { relation[:fks] = {} }

      unless (cnstr_name = fk[3])
        # For any appended references (those that come from config), arrive upon a definitely unique constraint name
        cnstr_base = cnstr_name = "(brick) #{fk[0]}_#{fk[2]}"
        cnstr_added_num = 1
        cnstr_name = "#{cnstr_base}_#{cnstr_added_num += 1}" while bts&.key?(cnstr_name) || hms&.key?(cnstr_name)
        missing = []
        missing << fk[0] unless relations.key?(fk[0])
        missing << fk[2] unless relations.key?(fk[2])
        unless missing.empty?
          tables = relations.reject { |k, v| v.fetch(:isView, nil) }.keys.sort
          puts "Brick: Additional reference #{fk.inspect} refers to non-existent #{'table'.pluralize(missing.length)} #{missing.join(' and ')}. (Available tables include #{tables.join(', ')}.)"
          return
        end
        unless (cols = relations[fk[0]][:cols]).key?(fk[1])
          columns = cols.map { |k, v| "#{k} (#{v.first.split(' ').first})" }
          puts "Brick: Additional reference #{fk.inspect} refers to non-existent column #{fk[1]}. (Columns present in #{fk[0]} are #{columns.join(', ')}.)"
          return
        end
        if (redundant = bts.find { |k, v| v[:inverse]&.fetch(:inverse_table, nil) == fk[0] && v[:fk] == fk[1] && v[:inverse_table] == fk[2] })
          puts "Brick: Additional reference #{fk.inspect} is redundant and can be removed.  (Already established by #{redundant.first}.)"
          return
        end
      end
      if (assoc_bt = bts[cnstr_name])
        assoc_bt[:fk] = assoc_bt[:fk].is_a?(String) ? [assoc_bt[:fk], fk[1]] : assoc_bt[:fk].concat(fk[1])
        assoc_bt[:assoc_name] = "#{assoc_bt[:assoc_name]}_#{fk[1]}"
      else
        assoc_bt = bts[cnstr_name] = { is_bt: true, fk: fk[1], assoc_name: bt_assoc_name, inverse_table: fk[2] }
      end

      unless ::Brick.config.skip_hms&.any? { |skip| fk[0] == skip[0] && fk[1] == skip[1] && fk[2] == skip[2] }
        cnstr_name = "hm_#{cnstr_name}"
        if (assoc_hm = hms.fetch(cnstr_name, nil))
          assoc_hm[:fk] = assoc_hm[:fk].is_a?(String) ? [assoc_hm[:fk], fk[1]] : assoc_hm[:fk].concat(fk[1])
          assoc_hm[:alternate_name] = "#{assoc_hm[:alternate_name]}_#{bt_assoc_name}" unless assoc_hm[:alternate_name] == bt_assoc_name
          assoc_hm[:inverse] = assoc_bt
        else
          assoc_hm = hms[cnstr_name] = { is_bt: false, fk: fk[1], assoc_name: fk[0], alternate_name: bt_assoc_name, inverse_table: fk[0], inverse: assoc_bt }
          hm_counts = relation.fetch(:hm_counts) { relation[:hm_counts] = {} }
          hm_counts[fk[0]] = hm_counts.fetch(fk[0]) { 0 } + 1
        end
        assoc_bt[:inverse] = assoc_hm
      end
      # hms[cnstr_name] << { is_bt: false, fk: fk[1], assoc_name: fk[0], alternate_name: bt_assoc_name, inverse_table: fk[0] }
    end

    # Rails < 4.0 doesn't have ActiveRecord::RecordNotUnique, so use the more generic ActiveRecord::ActiveRecordError instead
    ar_not_unique_error = ActiveRecord.const_defined?('RecordNotUnique') ? ActiveRecord::RecordNotUnique : ActiveRecord::ActiveRecordError
    class NoUniqueColumnError < ar_not_unique_error
    end

    # Rails < 4.2 doesn't have ActiveRecord::RecordInvalid, so use the more generic ActiveRecord::ActiveRecordError instead
    ar_invalid_error = ActiveRecord.const_defined?('RecordInvalid') ? ActiveRecord::RecordInvalid : ActiveRecord::ActiveRecordError
    class LessThanHalfAreMatchingColumnsError < ar_invalid_error
    end
  end
end
