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

# Drag TmfModel#name onto the rows and have it automatically add five columns -- where type=zone / where type = sectionn / etc

# ==========================================================
# Dynamically create model or controller classes when needed
# ==========================================================

# By default all models indicate that they are not views
class ActiveRecord::Base
  def self.is_view?
    false
  end
end

# Object.class_exec do
class Object
  class << self
    alias _brick_const_missing const_missing
    def const_missing(*args)
      return Object.const_get(args.first) if Object.const_defined?(args.first)

      class_name = args.first.to_s
      # See if a file is there in the same way that ActiveSupport::Dependencies#load_missing_constant
      # checks for it in ~/.rvm/gems/ruby-2.7.5/gems/activesupport-5.2.6.2/lib/active_support/dependencies.rb
      # that is, checking #qualified_name_for with:  from_mod, const_name
      # If we want to support namespacing in the future, might have to utilise something like this:
      # path_suffix = ActiveSupport::Dependencies.qualified_name_for(Object, args.first).underscore
      # return Object._brick_const_missing(*args) if ActiveSupport::Dependencies.search_for_file(path_suffix)
      # If the file really exists, go and snag it:
      return Object._brick_const_missing(*args) if ActiveSupport::Dependencies.search_for_file(class_name.underscore)

      relations = ::Brick.instance_variable_get(:@relations)[ActiveRecord::Base.connection_pool.object_id] || {}
      result = if ::Brick.enable_controllers? && class_name.end_with?('Controller') && (plural_class_name = class_name[0..-11]).length.positive?
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
        table_name = ActiveSupport::Inflector.pluralize(singular_table_name)

        # Maybe, just maybe there's a database table that will satisfy this need
        if (matching = [table_name, singular_table_name, plural_class_name, model_name].find { |m| relations.key?(m) })
          build_model(model_name, singular_table_name, table_name, relations, matching)
        end
      end
      if result
        built_class, code = result
        puts "\n#{code}"
        built_class
      else
        puts "MISSING! #{args.inspect} #{table_name}"
        Object._brick_const_missing(*args)
      end
    end

  private

    def build_model(model_name, singular_table_name, table_name, relations, matching)
      # Are they trying to use a pluralised class name such as "Employees" instead of "Employee"?
      if table_name == singular_table_name && !ActiveSupport::Inflector.inflections.uncountable.include?(table_name)
        raise NameError.new("Class name for a model that references table \"#{matching}\" should be \"#{ActiveSupport::Inflector.singularize(model_name)}\".")
      end
      code = +"class #{model_name} < ActiveRecord::Base\n"
      built_model = Class.new(ActiveRecord::Base) do |new_model_class|
        Object.const_set(model_name.to_sym, new_model_class)
        # Accommodate singular or camel-cased table names such as "order_detail" or "OrderDetails"
        code << "  self.table_name = '#{self.table_name = matching}'\n" unless table_name == matching

        # Override models backed by a view so they return true for #is_view?
        # (Dynamically-created controllers and view templates for such models will then act in a read-only way)
        if (is_view = (relation = relations[matching]).key?(:isView))
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

        # if relation[:cols].key?('last_update')
        #   define_method :updated_at do
        #     last_update
        #   end
        #   define_method :'updated_at=' do |val|
        #     last_update=(val)
        #   end
        # end

        fks = relation[:fks] || {}
        fks.each do |_constraint_name, assoc|
          assoc_name = assoc[:assoc_name]
          inverse_assoc_name = assoc[:inverse][:assoc_name]
          options = {}
          singular_table_name = ActiveSupport::Inflector.singularize(assoc[:inverse_table])
          macro = if assoc[:is_bt]
                    need_class_name = singular_table_name.underscore != assoc_name
                    need_fk = "#{assoc_name}_id" != assoc[:fk]
                    inverse_assoc_name, _x = _brick_get_hm_assoc_name(relations[assoc[:inverse_table]], assoc[:inverse])
                    :belongs_to
                  else
                    # need_class_name = ActiveSupport::Inflector.singularize(assoc_name) == ActiveSupport::Inflector.singularize(table_name.underscore)
                    # Are there multiple foreign keys out to the same table?
                    assoc_name, need_class_name = _brick_get_hm_assoc_name(relation, assoc)
                    need_fk = "#{singular_table_name}_id" != assoc[:fk]
                    # fks[table_name].find { |other_assoc| other_assoc.object_id != assoc.object_id && other_assoc[:assoc_name] == assoc[assoc_name] }
                    :has_many
                  end
          options[:class_name] = singular_table_name.camelize if need_class_name
          # Figure out if we need to specially call out the foreign key
          if need_fk # Funky foreign key?
            options[:foreign_key] = assoc[:fk].to_sym
          end
          options[:inverse_of] = inverse_assoc_name.to_sym if need_class_name || need_fk
          assoc_name = assoc_name.to_sym
          code << "  #{macro} #{assoc_name.inspect}#{options.map { |k, v| ", #{k}: #{v.inspect}" }.join}\n"
          self.send(macro, assoc_name, **options)

          # Look for any valid "has_many :through"
          if macro == :has_many
            relations[assoc[:inverse_table]][:hmt_fks].each do |k, hmt_fk|
              next if k == assoc[:fk]

              hmt_fk = ActiveSupport::Inflector.pluralize(hmt_fk)
              code << "  has_many :#{hmt_fk}, through: #{assoc_name.inspect}\n"
              self.send(:has_many, hmt_fk.to_sym, **{ through: assoc_name })
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
        code << "    @#{table_name} = #{model.name}#{model.primary_key ? ".order(#{model.primary_key.inspect}" : '.all'})\n"
        code << "  end\n"
        self.define_method :index do
          ar_relation = model.primary_key ? model.order(model.primary_key) : model.all
          instance_variable_set("@#{table_name}".to_sym, ar_relation)
        end

        if model.primary_key
          code << "  def show\n"
          code << "    @#{singular_table_name} = #{model.name}.find(params[:id].split(','))\n"
          code << "  end\n"
          self.define_method :show do
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
      if relation[:hm_counts][hm_assoc[:assoc_name]] > 1
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
  alias old_establish_connection establish_connection
  def establish_connection(*args)
    # puts connections.inspect
    x = old_establish_connection(*args)

    if (relations = ::Brick.relations).empty?
      schema = 'public'
      puts ActiveRecord::Base.connection.execute("SELECT current_setting('SEARCH_PATH')").to_a.inspect
      sql = ActiveRecord::Base.send(:sanitize_sql_array, [
        "SELECT t.table_name AS relation_name, t.table_type,
          c.column_name, c.data_type,
          COALESCE(c.character_maximum_length, c.numeric_precision) AS max_length,
          tc.constraint_type AS const, kcu.constraint_name AS key
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
            AND kcu.CONSTRAINT_NAME = tc.constraint_name
        WHERE t.table_schema = ? -- COALESCE(current_setting('SEARCH_PATH'), 'public')
  --          AND t.table_type IN ('VIEW') -- 'BASE TABLE', 'FOREIGN TABLE'
          AND t.table_name NOT IN ('pg_stat_statements', 'ar_internal_metadata', 'schema_migrations')
        ORDER BY 1, t.table_type DESC, c.ordinal_position", schema
      ])
      ActiveRecord::Base.connection.execute(sql).each do |r|
        # next if internal_views.include?(r['relation_name']) # Skip internal views such as v_all_assessments

        relation = relations[r['relation_name']]
        relation[:index] = r['relation_name'].underscore
        relation[:show] = relation[:index].singularize
        relation[:index] = relation[:index].pluralize
        relation[:isView] = true if r['table_type'] == 'VIEW'
        col_name = r['column_name']
        cols = relation[:cols] # relation.fetch(:cols) { relation[:cols] = [] }
        key = case r['const']
              when 'PRIMARY KEY'
                relation[:pkey][r['key']] ||= []
              when 'UNIQUE'
                relation[:ukeys][r['key']] ||= []
                # key = (relation[:ukeys] = Hash.new { |h, k| h[k] = [] }) if key.is_a?(Array)
                # key[r['key']]
              end
        key << col_name if key
        cols[col_name] = [r['data_type'], r['max_length'], r['measures']&.include?(col_name)]
        # puts "KEY! #{r['relation_name']}.#{col_name} #{r['key']} #{r['const']}" if r['key']
      end

      sql = ActiveRecord::Base.send(:sanitize_sql_array, [
        "SELECT kcu1.TABLE_NAME, kcu1.COLUMN_NAME, kcu2.TABLE_NAME, kcu1.CONSTRAINT_NAME
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
      ActiveRecord::Base.connection.execute(sql).values.each { |fk| ::Brick._add_bt_and_hm(fk, relations) }

      # Find associative tables that can be set up for has_many :through
      relations.each do |_key, tbl|
        tbl_cols = tbl[:cols].keys
        fks = tbl[:fks].each_with_object({}) { |fk, s| s[fk.last[:fk]] = fk.last[:inverse_table] if fk.last[:is_bt]; s }
        # Aside from the primary key and created_at, updated_at,This table has only foreign keys?
        if fks.length > 1 && (tbl_cols - fks.keys - ['created_at', 'updated_at', 'deleted_at', 'last_update'] - tbl[:pkey].values.first).length.zero?
          fks.each { |fk| tbl[:hmt_fks][fk.first] = fk.last }
        end
      end
    end

    puts "Classes built from tables:"
    relations.select { |_k, v| !v.key?(:isView) }.keys.each { |k| puts ActiveSupport::Inflector.singularize(k).camelize }
    puts "Classes built from views:"
    relations.select { |_k, v| v.key?(:isView) }.keys.each { |k| puts ActiveSupport::Inflector.singularize(k).camelize }
    # pp relations; nil

    # relations.keys.each { |k| ActiveSupport::Inflector.singularize(k).camelize.constantize }
    # Layout table describes permissioned hierarchy throughout
    x
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

  def self._add_bt_and_hm(fk, relations = nil)
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
      if (redundant = bts.find{|k, v| v[:inverse][:inverse_table] == fk[0] && v[:fk] == fk[1] && v[:inverse_table] == fk[2] })
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

    if (assoc_hm = hms[cnstr_name])
      assoc_hm[:fk] = assoc_hm[:fk].is_a?(String) ? [assoc_hm[:fk], fk[1]] : assoc_hm[:fk].concat(fk[1])
      assoc_hm[:alternate_name] = "#{assoc_hm[:alternate_name]}_#{bt_assoc_name}" unless assoc_hm[:alternate_name] == bt_assoc_name
      assoc_hm[:inverse] = assoc_bt
    else
      assoc_hm = hms[cnstr_name] = { is_bt: false, fk: fk[1], assoc_name: fk[0], alternate_name: bt_assoc_name, inverse_table: fk[0], inverse: assoc_bt }
      hm_counts = relation.fetch(:hm_counts) { relation[:hm_counts] = {} }
      hm_counts[fk[0]] = hm_counts.fetch(fk[0]) { 0 } + 1
    end
    assoc_bt[:inverse] = assoc_hm
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
