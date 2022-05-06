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


# From the North app:
# undefined method `built_in_role_path' when referencing show on a subclassed STI:
#  http://localhost:3000/roles/3?_brick_schema=cust1


# ==========================================================
# Dynamically create model or controller classes when needed
# ==========================================================

# By default all models indicate that they are not views
module Arel
  class Table
    def _arel_table_type
      # AR < 4.2 doesn't have type_caster at all, so rely on an instance variable getting set
      # AR 4.2 - 5.1 have buggy type_caster entries for the root node
      instance_variable_get(:@_arel_table_type) ||
      # 5.2-7.0 does type_caster just fine, no bugs there, but the property with the type differs:
      # 5.2 has "types" as public, 6.0 "types" as private, and >= 6.1 "klass" as private.
      ((tc = send(:type_caster)) && tc.instance_variable_get(:@types)) ||
      tc.send(:klass)
    end
  end
end

module ActiveRecord
  class Base
    def self._assoc_names
      @_assoc_names ||= {}
    end

    def self.is_view?
      false
    end

    # Used to show a little prettier name for an object
    def self.brick_get_dsl
      # If there's no DSL yet specified, just try to find the first usable column on this model
      unless (dsl = ::Brick.config.model_descrips[name])
        descrip_col = (columns.map(&:name) - _brick_get_fks -
                      (::Brick.config.metadata_columns || []) -
                      [primary_key]).first
        dsl = ::Brick.config.model_descrips[name] = "[#{descrip_col}]" if descrip_col
      end
      dsl
    end

    # Pass in true or a JoinArray
    def self.brick_parse_dsl(build_array = nil, prefix = [], translations = {})
      build_array = ::Brick::JoinArray.new.tap { |ary| ary.replace([build_array]) } if build_array.is_a?(::Brick::JoinHash)
      build_array = ::Brick::JoinArray.new unless build_array.nil? || build_array.is_a?(Array)
      members = []
      bracket_name = nil
      prefix = [prefix] unless prefix.is_a?(Array)
      if (dsl = ::Brick.config.model_descrips[name] || brick_get_dsl)
        klass = nil
        dsl.each_char do |ch|
          if bracket_name
            if ch == ']' # Time to process a bracketed thing?
              parts = bracket_name.split('.')
              first_parts = parts[0..-2].map { |part| klass = klass.reflect_on_association(part_sym = part.to_sym).klass; part_sym }
              parts = prefix + first_parts + [parts[-1]]
              if parts.length > 1
                s = build_array
                parts[0..-3].each { |v| s = s[v.to_sym] }
                s[parts[-2]] = nil # unless parts[-2].empty? # Using []= will "hydrate" any missing part(s) in our whole series
                translations[parts[0..-2].join('.')] = klass
              end
              members << parts
              bracket_name = nil
            else
              bracket_name << ch
            end
          elsif ch == '['
            bracket_name = +''
            klass = self
          end
        end
      else # With no DSL available, still put this prefix into the JoinArray so we can get primary key (ID) info from this table
        x = prefix.each_with_object(build_array) { |v, s| s[v.to_sym] }
        x[prefix[-1]] = nil unless prefix.empty? # Using []= will "hydrate" any missing part(s) in our whole series
      end
      members
    end

    # If available, parse simple DSL attached to a model in order to provide a friendlier name.
    # Object property names can be referenced in square brackets like this:
    # { 'User' => '[profile.firstname] [profile.lastname]' }
    def brick_descrip
      self.class.brick_descrip(self)
    end

    def self.brick_descrip(obj, data = nil, pk_alias = nil)
      if (dsl = ::Brick.config.model_descrips[(klass = self).name] || klass.brick_get_dsl)
        idx = -1
        caches = {}
        output = +''
        is_brackets_have_content = false
        bracket_name = nil
        dsl.each_char do |ch|
          if bracket_name
            if ch == ']' # Time to process a bracketed thing?
              datum = if data
                        data[idx += 1].to_s
                      else
                        obj_name = +''
                        this_obj = obj
                        bracket_name.split('.').each do |part|
                          obj_name += ".#{part}"
                          this_obj = if caches.key?(obj_name)
                                       caches[obj_name]
                                     else
                                       (caches[obj_name] = this_obj&.send(part.to_sym))
                                     end
                        end
                        this_obj&.to_s || ''
                      end
              is_brackets_have_content = true unless (datum).blank?
              output << (datum || '')
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
      elsif pk_alias
        if (id = obj.send(pk_alias))
          "#{klass.name} ##{id}"
        end
      # elsif klass.primary_key
      #   "#{klass.name} ##{obj.send(klass.primary_key)}"
      else
        obj.to_s
      end
    end

    def self.bt_link(assoc_name)
      model_underscore = name.underscore
      assoc_name = CGI.escapeHTML(assoc_name.to_s)
      model_path = Rails.application.routes.url_helpers.send("#{model_underscore.pluralize}_path".to_sym)
      link = Class.new.extend(ActionView::Helpers::UrlHelper).link_to(name, model_path)
      model_underscore == assoc_name ? link : "#{assoc_name}-#{link}".html_safe
    end

  private

    def self._brick_get_fks
      @_brick_get_fks ||= reflect_on_all_associations.select { |a2| a2.macro == :belongs_to }.map(&:foreign_key)
    end
  end

  class Relation
    attr_reader :_brick_chains

    # CLASS STUFF
    def _recurse_arel(piece, prefix = '')
      names = []
      # Our JOINs mashup of nested arrays and hashes
      # binding.pry if defined?(@arel)
      case piece
      when Array
        names += piece.inject([]) { |s, v| s + _recurse_arel(v, prefix) }
      when Hash
        names += piece.inject([]) do |s, v|
          new_prefix = "#{prefix}#{v.first}_"
          s << [v.last.shift, new_prefix]
          s + _recurse_arel(v.last, new_prefix)
        end

      # ActiveRecord AREL objects
      when Arel::Nodes::Join # INNER or OUTER JOIN
        # rubocop:disable Style/IdenticalConditionalBranches
        if piece.right.is_a?(Arel::Table) # Came in from AR < 3.2?
          # Arel 2.x and older is a little curious because these JOINs work "back to front".
          # The left side here is either another earlier JOIN, or at the end of the whole tree, it is
          # the first table.
          names += _recurse_arel(piece.left)
          # The right side here at the top is the very last table, and anywhere else down the tree it is
          # the later "JOIN" table of this pair.  (The table that comes after all the rest of the JOINs
          # from the left side.)
          names << [piece.right._arel_table_type, (piece.right.table_alias || piece.right.name)]
        else # "Normal" setup, fed from a JoinSource which has an array of JOINs
          # The left side is the "JOIN" table
          names += _recurse_arel(piece.left)
          # The expression on the right side is the "ON" clause
          # on = piece.right.expr
          # # Find the table which is not ourselves, and thus must be the "path" that led us here
          # parent = piece.left == on.left.relation ? on.right.relation : on.left.relation
          # binding.pry if piece.left.is_a?(Arel::Nodes::TableAlias)
          table = piece.left
          if table.is_a?(Arel::Nodes::TableAlias)
            alias_name = table.right
            table = table.left
          end
          (_brick_chains[table._arel_table_type] ||= []) << (alias_name || table.table_alias || table.name)
          # puts "YES! #{self.object_id}"
        end
        # rubocop:enable Style/IdenticalConditionalBranches
      when Arel::Table # Table
        names << [piece._arel_table_type, (piece.table_alias || piece.name)]
      when Arel::Nodes::TableAlias # Alias
        # Can get the real table name from:  self._recurse_arel(piece.left)
        names << [piece.left._arel_table_type, piece.right.to_s] # This is simply a string; the alias name itself
      when Arel::Nodes::JoinSource # Leaving this until the end because AR < 3.2 doesn't know at all about JoinSource!
        # Spin up an empty set of Brick alias name chains at the start
        @_brick_chains = {}
        # The left side is the "FROM" table
        # names += _recurse_arel(piece.left)
        names << [piece.left._arel_table_type, (piece.left.table_alias || piece.left.name)]
        # The right side is an array of all JOINs
        piece.right.each { |join| names << _recurse_arel(join) }
      end
      names
    end

    # INSTANCE STUFF
    def _arel_alias_names
      # %%% If with Rails 3.1 and older you get "NoMethodError: undefined method `eq' for nil:NilClass"
      # when trying to call relation.arel, then somewhere along the line while navigating a has_many
      # relationship it can't find the proper foreign key.
      core = arel.ast.cores.first
      # Accommodate AR < 3.2
      if core.froms.is_a?(Arel::Table)
        # All recent versions of AR have #source which brings up an Arel::Nodes::JoinSource
        _recurse_arel(core.source)
      else
        # With AR < 3.2, "froms" brings up the top node, an Arel::Nodes::InnerJoin
        _recurse_arel(core.froms)
      end
    end

    def brick_select(params, selects = nil, bt_descrip = {}, hm_counts = {}, join_array = ::Brick::JoinArray.new
      # , is_add_bts, is_add_hms
    )
      is_add_bts = is_add_hms = true

      # %%% Skip the metadata columns
      if selects&.empty? # Default to all columns
        columns.each do |col|
          selects << "#{table.name}.#{col.name}"
        end
      end

      # Search for BT, HM, and HMT DSL stuff
      translations = {}
      if is_add_bts || is_add_hms
        bts, hms, associatives = ::Brick.get_bts_and_hms(klass)
        bts.each do |_k, bt|
          # join_array will receive this relation name when calling #brick_parse_dsl
          bt_descrip[bt.first] = [bt.last, bt.last.brick_parse_dsl(join_array, bt.first, translations)]
        end
        skip_klass_hms = ::Brick.config.skip_index_hms[klass.name] || {}
        hms.each do |k, hm|
          next if skip_klass_hms.key?(k)

          hm_counts[k] = hm
        end
      end

      wheres = {}
      params.each do |k, v|
        case (ks = k.split('.')).length
        when 1
          next unless klass._brick_get_fks.include?(k)
        when 2
          assoc_name = ks.first.to_sym
          # Make sure it's a good association name and that the model has that column name
          next unless klass.reflect_on_association(assoc_name)&.klass&.column_names&.any?(ks.last)

          join_array[assoc_name] = nil # Store this relation name in our special collection for .joins()
        end
        wheres[k] = v.split(',')
      end

      if join_array.present?
        left_outer_joins!(join_array) # joins!(join_array)
        # Without working from a duplicate, touching the AREL ast tree sets the @arel instance variable, which causes the relation to be immutable.
        (rel_dupe = dup)._arel_alias_names
        core_selects = selects.dup
        chains = rel_dupe._brick_chains
        id_for_tables = {}
        field_tbl_names = Hash.new { |h, k| h[k] = {} }
        bt_columns = bt_descrip.each_with_object([]) do |v, s|
          tbl_name = field_tbl_names[v.first][v.last.first] ||= shift_or_first(chains[v.last.first])
          if (id_col = v.last.first.primary_key) && !id_for_tables.key?(v.first) # was tbl_name
            selects << "#{"#{tbl_name}.#{id_col}"} AS \"#{(id_alias = id_for_tables[v.first] = "_brfk_#{v.first}__#{id_col}")}\""
            v.last << id_alias
          end
          if (col_name = v.last[1].last&.last)
            field_tbl_name = nil
            v.last[1].map { |x| [translations[x[0..-2].map(&:to_s).join('.')], x.last] }.each_with_index do |sel_col, idx|
              field_tbl_name ||= field_tbl_names[v.first][sel_col.first] ||= shift_or_first(chains[sel_col.first])
              # col_name is weak when there are multiple, using sel_col.last instead
              selects << "#{"#{field_tbl_name}.#{sel_col.last}"} AS \"#{(col_alias = "_brfk_#{v.first}__#{sel_col.last}")}\""
              v.last[1][idx] << col_alias
            end
          end
        end
        join_array.each do |assoc_name|
          # %%% Need to support {user: :profile}
          next unless assoc_name.is_a?(Symbol)

          table_alias = shift_or_first(chains[klass = reflect_on_association(assoc_name)&.klass])
          _assoc_names[assoc_name] = [table_alias, klass]
        end
      end
      # Add derived table JOIN for the has_many counts
      hm_counts.each do |k, hm|
        associative = nil
        count_column = if hm.options[:through]
                          fk_col = (associative = associatives[hm.name]).foreign_key
                          hm.foreign_key
                        else
                          fk_col = hm.foreign_key
                          hm.klass.primary_key || '*'
                        end
        joins!("LEFT OUTER
JOIN (SELECT #{fk_col}, COUNT(#{count_column}) AS _ct_ FROM #{associative&.name || hm.klass.table_name} GROUP BY 1) AS #{tbl_alias = "_br_#{hm.name}"}
  ON #{tbl_alias}.#{fk_col} = #{(pri_tbl = hm.active_record).table_name}.#{pri_tbl.primary_key}")
      end
      where!(wheres) unless wheres.empty?
      wheres unless wheres.empty? # Return the specific parameters that we did use
    end

  private

    def shift_or_first(ary)
      ary.length > 1 ? ary.shift : ary.first
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
          if (snp = ::Brick.config.sti_namespace_prefixes)&.key?("::#{module_name}::") || snp&.key?("#{module_name}::") ||
             File.exist?(candidate_file = Rails.root.join('app/models' + module_prefixes.map(&:underscore).join('/') + '.rb'))
            _brick_find_sti_class(type_name) # Find this STI class normally
          else
            # Build missing prefix modules if they don't yet exist
            this_module = Object
            module_prefixes[1..-2].each do |module_name|
              this_module = if this_module.const_defined?(module_name)
                              this_module.const_get(module_name)
                            else
                              this_module.const_set(module_name.to_sym, Module.new)
                            end
            end
            if this_module.const_defined?(class_name = module_prefixes.last.to_sym)
              this_module.const_get(class_name)
            else
              # Build STI subclass and place it into the namespace module
              # %%% Does this ever get used???
              puts [this_module.const_set(class_name, klass = Class.new(self)).name, class_name].inspect
              klass
            end
          end
        end
      end
    end
  end
end

if ActiveSupport::Dependencies.respond_to?(:autoload_module!) # %%% Only works with previous non-zeitwerk auto-loading
  module ActiveSupport::Dependencies
    class << self
      # %%% Probably a little more targeted than other approaches we've taken thusfar
      # This happens before the whole parent check
      alias _brick_autoload_module! autoload_module!
      def autoload_module!(*args)
        into, const_name, qualified_name, path_suffix = args
        if (base_class = ::Brick.config.sti_namespace_prefixes&.fetch("::#{into.name}::", nil)&.constantize)
          ::Brick.sti_models[qualified_name] = { base: base_class }
          # Build subclass and place it into the specially STI-namespaced module
          into.const_set(const_name.to_sym, klass = Class.new(base_class))
          # %%% used to also have:  autoload_once_paths.include?(base_path) || 
          autoloaded_constants << qualified_name unless autoloaded_constants.include?(qualified_name)
          klass
        elsif (base_class = ::Brick.config.sti_namespace_prefixes&.fetch("::#{const_name}", nil)&.constantize)
          # Build subclass and place it into Object
          Object.const_set(const_name.to_sym, klass = Class.new(base_class))
        else
          _brick_autoload_module!(*args)
        end
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
      result = if ::Brick.enable_controllers? && class_name.end_with?('Controller') && (plural_class_name = class_name[0..-11]).length.positive?
                 # Otherwise now it's up to us to fill in the gaps
                 if (model = plural_class_name.singularize.constantize)
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
      elsif ::Brick.config.sti_namespace_prefixes&.key?("::#{class_name}")
#         module_prefixes = type_name.split('::')
#         path = self.name.split('::')[0..-2] + []
#         module_prefixes.unshift('') unless module_prefixes.first.blank?
#         candidate_file = Rails.root.join('app/models' + module_prefixes.map(&:underscore).join('/') + '.rb')
        self._brick_const_missing(*args)
      else
        puts "MISSING! #{self.name} #{args.inspect} #{table_name}"
        self._brick_const_missing(*args)
      end
    end

  private

    def build_model(model_name, singular_table_name, table_name, relations, matching)
      return if ((is_view = (relation = relations[matching]).key?(:isView)) && ::Brick.config.skip_database_views) ||
                ::Brick.config.exclude_tables.include?(matching)

      # Are they trying to use a pluralised class name such as "Employees" instead of "Employee"?
      if table_name == singular_table_name && !ActiveSupport::Inflector.inflections.uncountable.include?(table_name)
        unless ::Brick.config.sti_namespace_prefixes&.key?("::#{singular_table_name.titleize}::")
          puts "Warning: Class name for a model that references table \"#{matching}\" should be \"#{ActiveSupport::Inflector.singularize(model_name)}\"."
        end
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
            inverse_assoc_name = (assoc = fk.last)[:inverse]&.fetch(:assoc_name, nil)
            options = {}
            singular_table_name = ActiveSupport::Inflector.singularize(assoc[:inverse_table])
            macro = if assoc[:is_bt]
                      # Try to take care of screwy names if this is a belongs_to going to an STI subclass
                      assoc_name = if (primary_class = assoc.fetch(:primary_class, nil)) &&
                                      sti_inverse_assoc = primary_class.reflect_on_all_associations.find do |a|
                                        a.macro == :has_many && a.options[:class_name] == self.name && assoc[:fk] = a.foreign_key
                                      end
                                     sti_inverse_assoc.options[:inverse_of]&.to_s || assoc_name
                                   else
                                     assoc[:assoc_name]
                                   end
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
                        assoc_name = if (custom_assoc_name = has_ones[singular_assoc_name])
                                       need_class_name = custom_assoc_name != singular_assoc_name
                                       custom_assoc_name
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
            options[:class_name] = assoc[:primary_class]&.name || singular_table_name.camelize if need_class_name
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
                              singular_assoc_name = fk.first[:inverse][:assoc_name].singularize
                              source = fk.last
                              through = fk.first[:alternate_name].pluralize
                              "#{singular_assoc_name}_#{hmt_fk}"
                            else
                              source = fk.last unless hmt_fk.singularize == fk.last
                              through = fk.first[:assoc_name].pluralize
                              hmt_fk
                            end
              code << "  has_many :#{this_hmt_fk}, through: #{(assoc_name = through.to_sym).to_sym.inspect}#{", source: :#{source}" if source}\n"
              options = { through: assoc_name }
              options[:source] = source.to_sym if source
              self.send(:has_many, this_hmt_fk.to_sym, **options)
            end
          end
          # Not NULLables
          relation[:cols].each do |col, datatype|
            if (datatype[3] && ar_pks.exclude?(col) && ::Brick.config.metadata_columns.exclude?(col)) ||
               ::Brick.config.not_nullables.include?("#{matching}.#{col}")
              code << "  validates :#{col}, presence: true\n"
              self.send(:validates, col.to_sym, { presence: true })
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
        code << "    @#{table_name}.brick_select(params)\n"
        code << "  end\n"
        self.define_method :index do
          ::Brick.set_db_schema(params)
          ar_relation = model.all # model.primary_key ? model.order(model.primary_key) : model.all
          @_brick_params = ar_relation.brick_select(params, (selects = []), (bt_descrip = {}), (hm_counts = {}), (join_array = ::Brick::JoinArray.new))
          # %%% Add custom HM count columns
          # %%% What happens when the PK is composite?
          counts = hm_counts.each_with_object([]) { |v, s| s << "_br_#{v.first}._ct_ AS _br_#{v.first}_ct" }
          # *selects, 
          instance_variable_set("@#{table_name}".to_sym, ar_relation.dup._select!(*selects, *counts))
          # binding.pry
          @_brick_bt_descrip = bt_descrip
          @_brick_hm_counts = hm_counts
          @_brick_join_array = join_array
        end

        if model.primary_key
          code << "  def show\n"
          code << (find_by_id = "    @#{singular_table_name} = #{model.name}.find(params[:id].split(','))\n")
          code << "  end\n"
          self.define_method :show do
            ::Brick.set_db_schema(params)
            instance_variable_set("@#{singular_table_name}".to_sym, model.find(params[:id].split(',')))
          end
        end

        # By default, views get marked as read-only
        unless false # model.readonly # (relation = relations[model.table_name]).key?(:isView)
          code << "  # (Define :new, :create)\n"

          if model.primary_key
            is_need_params = true
            # code << "  # (Define :edit, and :destroy)\n"
            code << "  def update\n"
            code << find_by_id
            params_name = "#{singular_table_name}_params"
            code << "    @#{singular_table_name}.update(#{params_name})\n"
            code << "  end\n"
            self.define_method :update do
              ::Brick.set_db_schema(params)
              instance_variable_set("@#{singular_table_name}".to_sym, (obj = model.find(params[:id].split(','))))
              obj = obj.first if obj.is_a?(Array)
              obj.send(:update, send(params_name = params_name.to_sym))
            end
          end

          if is_need_params
            code << "private\n"
            code << "  def params\n"
            code << "    params.require(:#{singular_table_name}).permit(#{model.columns_hash.keys.map { |c| c.to_sym.inspect }.join(', ')})\n"
            code << "  end\n"
            self.define_method(params_name) do
              params.require(singular_table_name.to_sym).permit(model.columns_hash.keys)
            end
            private params_name
            # Get column names for params from relations[model.table_name][:cols].keys
          end
        end
        code << "end # #{class_name}\n\n"
      end # class definition
      [built_controller, code]
    end

    def _brick_get_hm_assoc_name(relation, hm_assoc)
      if relation[:hm_counts][hm_assoc[:assoc_name]]&.> 1
        plural = ActiveSupport::Inflector.pluralize(hm_assoc[:alternate_name])
        [hm_assoc[:alternate_name] == name.underscore ? "#{hm_assoc[:assoc_name].singularize}_#{plural}" : plural, true]
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
          tc.constraint_type AS const, kcu.constraint_name AS \"key\",
          c.is_nullable
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
          cols[col_name] = [r['data_type'], r['max_length'], measures&.include?(col_name), r['is_nullable'] == 'NO']
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

    # Try to load the initializer pretty danged early
    if File.exist?(brick_initialiser = Rails.root.join('config/initializers/brick.rb'))
      load brick_initialiser
      ::Brick.load_additional_references
    end
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
      primary_table = (is_class = fk[2].is_a?(Hash) && fk[2].key?(:class)) ? (primary_class = fk[2][:class].constantize).table_name : fk[2]
      hms = (relation = relations.fetch(primary_table, nil))&.fetch(:fks) { relation[:fks] = {} } unless is_class

      unless (cnstr_name = fk[3])
        # For any appended references (those that come from config), arrive upon a definitely unique constraint name
        cnstr_base = cnstr_name = "(brick) #{fk[0]}_#{is_class ? fk[2][:class].underscore : fk[2]}"
        cnstr_added_num = 1
        cnstr_name = "#{cnstr_base}_#{cnstr_added_num += 1}" while bts&.key?(cnstr_name) || hms&.key?(cnstr_name)
        missing = []
        missing << fk[0] unless relations.key?(fk[0])
        missing << primary_table unless is_class || relations.key?(primary_table)
        unless missing.empty?
          tables = relations.reject { |_k, v| v.fetch(:isView, nil) }.keys.sort
          puts "Brick: Additional reference #{fk.inspect} refers to non-existent #{'table'.pluralize(missing.length)} #{missing.join(' and ')}. (Available tables include #{tables.join(', ')}.)"
          return
        end
        unless (cols = relations[fk[0]][:cols]).key?(fk[1])
          columns = cols.map { |k, v| "#{k} (#{v.first.split(' ').first})" }
          puts "Brick: Additional reference #{fk.inspect} refers to non-existent column #{fk[1]}. (Columns present in #{fk[0]} are #{columns.join(', ')}.)"
          return
        end
        if (redundant = bts.find { |_k, v| v[:inverse]&.fetch(:inverse_table, nil) == fk[0] && v[:fk] == fk[1] && v[:inverse_table] == primary_table })
          if is_class && !redundant.last.key?(:class)
            redundant.last[:primary_class] = primary_class # Round out this BT so it can find the proper :source for a HMT association that references an STI subclass
          else
            puts "Brick: Additional reference #{fk.inspect} is redundant and can be removed.  (Already established by #{redundant.first}.)"
          end
          return
        end
      end
      if (assoc_bt = bts[cnstr_name])
        assoc_bt[:fk] = assoc_bt[:fk].is_a?(String) ? [assoc_bt[:fk], fk[1]] : assoc_bt[:fk].concat(fk[1])
        assoc_bt[:assoc_name] = "#{assoc_bt[:assoc_name]}_#{fk[1]}"
      else
        assoc_bt = bts[cnstr_name] = { is_bt: true, fk: fk[1], assoc_name: bt_assoc_name, inverse_table: primary_table }
      end
      if is_class
        # For use in finding the proper :source for a HMT association that references an STI subclass
        assoc_bt[:primary_class] = primary_class
        # For use in finding the proper :inverse_of for a BT association that references an STI subclass
        # assoc_bt[:inverse_of] = primary_class.reflect_on_all_associations.find { |a| a.foreign_key == bt[1] }
      end

      return if is_class || ::Brick.config.exclude_hms&.any? { |exclusion| fk[0] == exclusion[0] && fk[1] == exclusion[1] && primary_table == exclusion[2] }

      if (assoc_hm = hms.fetch((hm_cnstr_name = "hm_#{cnstr_name}"), nil))
        assoc_hm[:fk] = assoc_hm[:fk].is_a?(String) ? [assoc_hm[:fk], fk[1]] : assoc_hm[:fk].concat(fk[1])
        assoc_hm[:alternate_name] = "#{assoc_hm[:alternate_name]}_#{bt_assoc_name}" unless assoc_hm[:alternate_name] == bt_assoc_name
        assoc_hm[:inverse] = assoc_bt
      else
        assoc_hm = hms[hm_cnstr_name] = { is_bt: false, fk: fk[1], assoc_name: fk[0], alternate_name: bt_assoc_name, inverse_table: fk[0], inverse: assoc_bt }
        hm_counts = relation.fetch(:hm_counts) { relation[:hm_counts] = {} }
        hm_counts[fk[0]] = hm_counts.fetch(fk[0]) { 0 } + 1
      end
      assoc_bt[:inverse] = assoc_hm
    end
  end
end
