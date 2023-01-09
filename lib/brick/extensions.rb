# frozen_string_literal: true

# Some future enhancement ideas:

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
# Eventually some indication about if it should be a paginated table / unpaginated / a list of just some fields / columns shown in a different sequence / etc

# Grid where each cell is one field and then when you mouse over then it shows a popup other table of detail inside

# DSL that describes the rows / columns and then what each cell can have, which could be nested related data, the specifics of X and Y driving things in the cell definition like a formula

# colour coded origins

# Drag something like HierModel#name onto the rows and have it automatically add five columns -- where type=zone / where type = section / etc

# Support for Postgres / MySQL enums (add enum to model, use model enums to make a drop-down in the UI)

# Currently quadrupling up routes

# Modal pop-up things for editing large text / date ranges / hierarchies of data

# For recognised self-references, have the show page display all related objects up to the parent (or the start of a circular reference)

# ==========================================================
# Dynamically create model or controller classes when needed
# ==========================================================

module ActiveRecord
  class Base
    def self.is_brick?
      instance_variables.include?(:@_brick_built) && instance_variable_get(:@_brick_built)
    end

    def self._assoc_names
      @_assoc_names ||= {}
    end

    def self.is_view?
      false
    end

    def self._brick_primary_key(relation = nil)
      return @_brick_primary_key if instance_variable_defined?(:@_brick_primary_key)

      pk = begin
             primary_key.is_a?(String) ? [primary_key] : primary_key || []
           rescue
             []
           end
      pk.map! { |pk_part| pk_part =~ /^[A-Z0-9_]+$/ ? pk_part.downcase : pk_part } unless connection.adapter_name == 'MySQL2'
      # Just return [] if we're missing any part of the primary key.  (PK is usually just "id")
      if relation && pk.present?
        @_brick_primary_key ||= pk.any? { |pk_part| !relation[:cols].key?(pk_part) } ? [] : pk
      else # No definitive key yet, so return what we can without setting the instance variable
        pk
      end
    end

    # Used to show a little prettier name for an object
    def self.brick_get_dsl
      # If there's no DSL yet specified, just try to find the first usable column on this model
      unless (dsl = ::Brick.config.model_descrips[name])
        skip_columns = _brick_get_fks + (::Brick.config.metadata_columns || []) + [primary_key]
        dsl = if (descrip_col = columns.find { |c| [:boolean, :binary, :xml].exclude?(c.type) && skip_columns.exclude?(c.name) })
                "[#{descrip_col.name}]"
              elsif (pk_parts = self.primary_key.is_a?(Array) ? self.primary_key : [self.primary_key])
                "#{name} ##{pk_parts.map { |pk_part| "[#{pk_part}]" }.join(', ')}"
              end
        ::Brick.config.model_descrips[name] = dsl
      end
      dsl
    end

    def self.brick_parse_dsl(build_array = nil, prefix = [], translations = {}, is_polymorphic = false, dsl = nil, emit_dsl = false)
      unless build_array.is_a?(::Brick::JoinArray)
        build_array = ::Brick::JoinArray.new.tap { |ary| ary.replace([build_array]) } if build_array.is_a?(::Brick::JoinHash)
        build_array = ::Brick::JoinArray.new unless build_array.nil? || build_array.is_a?(Array)
      end
      prefix = [prefix] unless prefix.is_a?(Array)
      members = []
      unless dsl || (dsl = ::Brick.config.model_descrips[name] || brick_get_dsl)
        # With no DSL available, still put this prefix into the JoinArray so we can get primary key (ID) info from this table
        x = prefix.each_with_object(build_array) { |v, s| s[v.to_sym] }
        x[prefix.last] = nil unless prefix.empty? # Using []= will "hydrate" any missing part(s) in our whole series
        return members
      end

      # Do the actual dirty work of recursing through nested DSL
      bracket_name = nil
      dsl2 = +'' # To replace our own DSL definition in case it needs to be expanded
      dsl3 = +'' # To return expanded DSL that is nested from another model
      klass = nil
      dsl.each_char do |ch|
        if bracket_name
          if ch == ']' # Time to process a bracketed thing?
            parts = bracket_name.split('.')
            first_parts = parts[0..-2].each_with_object([]) do |part, s|
              unless (klass = (orig_class = klass).reflect_on_association(part_sym = part.to_sym)&.klass)
                puts "Couldn't reference #{orig_class.name}##{part} that's part of the DSL \"#{dsl}\"."
                break
              end
              s << part_sym
            end
            if first_parts
              if (parts = prefix + first_parts + [parts[-1]]).length > 1 && klass
                unless is_polymorphic
                  s = build_array
                  parts[0..-3].each { |v| s = s[v.to_sym] }
                  s[parts[-2]] = nil # unless parts[-2].empty? # Using []= will "hydrate" any missing part(s) in our whole series
                end
                translations[parts[0..-2].join('.')] = klass
              end
              if klass&.column_names.exclude?(parts.last) &&
                 (klass = (orig_class = klass).reflect_on_association(possible_dsl = parts.pop.to_sym)&.klass)
                if prefix.empty? # Custom columns start with an empty prefix
                  prefix << parts.shift until parts.empty?
                end
                # Expand this entry which refers to an association name
                members2, dsl2a = klass.brick_parse_dsl(build_array, prefix + [possible_dsl], translations, is_polymorphic, nil, true)
                members += members2
                dsl2 << dsl2a
                dsl3 << dsl2a
              else
                dsl2 << "[#{bracket_name}]"
                if emit_dsl
                  dsl3 << "[#{prefix[1..-1].map { |p| "#{p.to_s}." }.join if prefix.length > 1}#{bracket_name}]"
                end
                members << parts
              end
            end
            bracket_name = nil
          else
            bracket_name << ch
          end
        elsif ch == '['
          bracket_name = +''
          klass = self
        else
          dsl2 << ch
          dsl3 << ch
        end
      end
      # Rewrite the DSL in case it's now different from having to expand it
      # if ::Brick.config.model_descrips[name] != dsl2
      #   puts ::Brick.config.model_descrips[name]
      #   puts dsl2.inspect
      #   puts dsl3.inspect
      #   binding.pry
      # end
      if emit_dsl
        # Had been:  [members, dsl2, dsl3]
        [members, dsl3]
      else
        ::Brick.config.model_descrips[name] = dsl2
        members
      end
    end

    # If available, parse simple DSL attached to a model in order to provide a friendlier name.
    # Object property names can be referenced in square brackets like this:
    # { 'User' => '[profile.firstname] [profile.lastname]' }
    def brick_descrip(data = nil, pk_alias = nil)
      self.class.brick_descrip(self, data, pk_alias)
    end

    def self.brick_descrip(obj, data = nil, pk_alias = nil)
      dsl = obj if obj.is_a?(String)
      if (dsl ||= ::Brick.config.model_descrips[(klass = self).name] || klass.brick_get_dsl)
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
                          this_obj = begin
                                       caches.fetch(obj_name) { caches[obj_name] = this_obj&.send(part.to_sym) }
                                     rescue
                                       clsnm = part.camelize
                                       if (possible = this_obj.class.reflect_on_all_associations.select { |a| a.class_name == clsnm || a.klass.base_class.name == clsnm }.first)
                                         caches[obj_name] = this_obj&.send(possible.name)
                                       end
                                     end
                          break if this_obj.nil?
                        end
                        if this_obj.is_a?(ActiveRecord::Base) && (obj_descrip = this_obj.class.brick_descrip(this_obj))
                          this_obj = obj_descrip
                        end
                        this_obj&.to_s || ''
                      end
              is_brackets_have_content = true unless datum.blank?
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
      elsif (pk_alias ||= primary_key)
        pk_alias = [pk_alias] unless pk_alias.is_a?(Array)
        id = []
        pk_alias.each do |pk_alias_part|
          if (pk_part = obj.respond_to?(pk_alias_part) ? obj.send(pk_alias_part) : nil)
            id << pk_part
          end
        end
        if id.present?
          "#{klass.name} ##{id.join(', ')}"
        end
      else
        obj.to_s
      end
    end

    def self.bt_link(assoc_name)
      assoc_html_name = unless (assoc_name = assoc_name.to_s).camelize == name
                          CGI.escapeHTML(assoc_name)
                        end
      model_path = ::Rails.application.routes.url_helpers.send("#{_brick_index}_path".to_sym)
      model_path << "?#{self.inheritance_column}=#{self.name}" if self != base_class
      av_class = Class.new.extend(ActionView::Helpers::UrlHelper)
      av_class.extend(ActionView::Helpers::TagHelper) if ActionView.version < ::Gem::Version.new('7')
      link = av_class.link_to(assoc_html_name ? name : assoc_name, model_path)
      assoc_html_name ? "#{assoc_name}-#{link}".html_safe : link
    end

    def self._brick_index(mode = nil, separator = '_')
      tbl_parts = ((mode == :singular) ? table_name.singularize : table_name).split('.')
      tbl_parts.shift if ::Brick.apartment_multitenant && tbl_parts.length > 1 && tbl_parts.first == ::Brick.apartment_default_tenant
      tbl_parts.unshift(::Brick.config.path_prefix) if ::Brick.config.path_prefix
      index = tbl_parts.map(&:underscore).join(separator)
      # Rails applies an _index suffix to that route when the resource name is singular
      index << '_index' if mode != :singular && index == index.singularize
      index
    end

    def self.brick_import_template
      template = constants.include?(:IMPORT_TEMPLATE) ? self::IMPORT_TEMPLATE : suggest_template(false, false, 0)
      # Add the primary key to the template as being unique (unless it's already there)
      template[:uniques] = [pk = primary_key.to_sym]
      template[:all].unshift(pk) unless template[:all].include?(pk)
      template
    end

    class << self
      # belongs_to DSL descriptions
      def _br_bt_descrip
        @_br_bt_descrip ||= {}
      end
      # has_many count definitions
      def _br_hm_counts
        @_br_hm_counts ||= {}
      end
      # has_many :through associative tables
      def _br_associatives
        @_br_associatives ||= {}
      end
      # Custom columns
      def _br_cust_cols
        @_br_cust_cols ||= {}
      end
    end

    # Search for custom column, BT, HM, and HMT DSL stuff
    def self._brick_calculate_bts_hms(translations, join_array)
      # Add any custom columns
      ::Brick.config.custom_columns&.fetch(table_name, nil)&.each do |k, cc|
        if cc.is_a?(Array)
          fk_col = cc.last unless cc.last.blank?
          cc = cc.first
        else
          fk_col = true
        end
        # false = not polymorphic, and true = yes -- please emit_dsl
        pieces, my_dsl = brick_parse_dsl(join_array, [], translations, false, cc, true)
        _br_cust_cols[k] = [pieces, my_dsl, fk_col]
      end
      bts, hms, associatives = ::Brick.get_bts_and_hms(self)
      bts.each do |_k, bt|
        next if bt[2] # Polymorphic?

        # join_array will receive this relation name when calling #brick_parse_dsl
        _br_bt_descrip[bt.first] = if bt[1].is_a?(Array)
                                     # Last params here:  "true" is for yes, we are polymorphic
                                     bt[1].each_with_object({}) { |bt_class, s| s[bt_class] = bt_class.brick_parse_dsl(join_array, bt.first, translations, true) }
                                   else
                                     { bt.last => bt[1].brick_parse_dsl(join_array, bt.first, translations) }
                                   end
      end
      skip_klass_hms = ::Brick.config.skip_index_hms[self.name] || {}
      hms.each do |k, hm|
        next if skip_klass_hms.key?(k)

        if hm.macro == :has_one
          # For our purposes a :has_one is similar enough to a :belongs_to that we can just join forces
          _br_bt_descrip[k] = { hm.klass => hm.klass.brick_parse_dsl(join_array, k, translations) }
        else # Standard :has_many
          _br_hm_counts[k] = hm unless hm.options[:through] && !_br_associatives.fetch(hm.name, nil)
        end
      end
    end

    def self._brick_calculate_ordering(ordering, is_do_txt = true)
      quoted_table_name = table_name.split('.').map { |x| "\"#{x}\"" }.join('.')
      order_by_txt = [] if is_do_txt
      ordering = [ordering] if ordering && !ordering.is_a?(Array)
      order_by = ordering&.each_with_object([]) do |ord_part, s| # %%% If a term is also used as an eqi-condition in the WHERE clause, it can be omitted from ORDER BY
                   case ord_part
                   when String
                     ord_expr = ord_part.gsub('^^^', quoted_table_name)
                     order_by_txt&.<<("Arel.sql(#{ord_expr})")
                     s << Arel.sql(ord_expr)
                   else # Expecting only Symbol
                     if _br_hm_counts.key?(ord_part)
                       ord_part = "\"b_r_#{ord_part}_ct\""
                     elsif !_br_bt_descrip.key?(ord_part) && !_br_cust_cols.key?(ord_part) && !column_names.include?(ord_part.to_s)
                       # Disallow ordering by a bogus column
                       # %%% Note this bogus entry so that Javascript can remove any bogus _brick_order
                       # parameter from the querystring, pushing it into the browser history.
                       ord_part = nil
                     end
                     if ord_part
                       # Retain any reference to a bt_descrip as being a symbol
                       # Was:  "#{quoted_table_name}.\"#{ord_part}\""
                       order_by_txt&.<<(_br_bt_descrip.key?(ord_part) ? ord_part : ord_part.inspect)
                       s << ord_part
                     end
                   end
                 end
      [order_by, order_by_txt]
    end

    def self.brick_select(params = {}, selects = [], *args)
      (relation = all).brick_select(params, selects, *args)
      relation.select(selects)
    end

  private

    def self._brick_get_fks
      @_brick_get_fks ||= reflect_on_all_associations.select { |a2| a2.macro == :belongs_to }.each_with_object([]) do |bt, s|
        s << bt.foreign_key
        s << bt.foreign_type if bt.polymorphic?
      end
    end
  end

  module AttributeMethods
    module ClassMethods
      alias _brick_dangerous_attribute_method? dangerous_attribute_method?
      # Bypass the error "ActiveRecord::DangerousAttributeError" if this object comes from a view.
      # (Allows for column names such as 'attribute', 'delete', and 'update' to still work.)
      def dangerous_attribute_method?(name)
        if (is_dangerous = _brick_dangerous_attribute_method?(name)) && is_view?
          if column_names.include?(name.to_s)
            puts "WARNING:  Column \"#{name}\" in view #{table_name} conflicts with a reserved ActiveRecord method name."
          end
          return false
        end
        is_dangerous
      end
    end
  end

  class Relation
    # Links from ActiveRecord association pathing names over to real table correlation names
    # that get chosen when the AREL AST tree is walked.
    def brick_links
      @brick_links ||= { '' => table_name }
    end

    def brick_select(params, selects = [], order_by = nil, translations = {}, join_array = ::Brick::JoinArray.new)
      is_add_bts = is_add_hms = true

      # Build out cust_cols, bt_descrip and hm_counts now so that they are available on the
      # model early in case the user wants to do an ORDER BY based on any of that.
      model._brick_calculate_bts_hms(translations, join_array) if is_add_bts || is_add_hms

      is_postgres = ActiveRecord::Base.connection.adapter_name == 'PostgreSQL'
      is_mysql = ['Mysql2', 'Trilogy'].include?(ActiveRecord::Base.connection.adapter_name)
      is_mssql = ActiveRecord::Base.connection.adapter_name == 'SQLServer'
      is_distinct = nil
      wheres = {}
      params.each do |k, v|
        next if ['_brick_schema', '_brick_order', 'controller', 'action'].include?(k)

        if (where_col = (ks = k.split('.')).last)[-1] == '!'
          where_col = where_col[0..-2]
        end
        case ks.length
        when 1
          next unless klass.column_names.any?(where_col) || klass._brick_get_fks.include?(where_col)
        when 2
          assoc_name = ks.first.to_sym
          # Make sure it's a good association name and that the model has that column name
          next unless klass.reflect_on_association(assoc_name)&.klass&.column_names&.any?(where_col)

          join_array[assoc_name] = nil # Store this relation name in our special collection for .joins()
          is_distinct = true
          distinct!
        end
        wheres[k] = v.split(',')
      end

      # %%% Skip the metadata columns
      if selects.empty? # Default to all columns
        id_parts = (id_col = klass.primary_key).is_a?(Array) ? id_col : [id_col]
        tbl_no_schema = table.name.split('.').last
        # %%% Have once gotten this error with MSSQL referring to http://localhost:3000/warehouse/cold_room_temperatures__archive
        #     ActiveRecord::StatementInvalid (TinyTds::Error: DBPROCESS is dead or not enabled)
        #     Relevant info here:  https://github.com/rails-sqlserver/activerecord-sqlserver-adapter/issues/402
        columns.each do |col|
          col_alias = " AS #{col.name}_" if (col_name = col.name) == 'class'
          selects << if is_mysql
                       "`#{tbl_no_schema}`.`#{col_name}`#{col_alias}"
                     elsif is_postgres || is_mssql
                       if is_distinct # Postgres can not use DISTINCT with any columns that are XML or JSON
                         cast_as_text = if Brick.relations[klass.table_name]&.[](:cols)&.[](col_name)&.first == 'json'
                                          '::jsonb' # Convert JSON to JSONB
                                        elsif Brick.relations[klass.table_name]&.[](:cols)&.[](col_name)&.first&.start_with?('xml')
                                          '::text' # Convert XML to text
                                        end
                       end
                       "\"#{tbl_no_schema}\".\"#{col_name}\"#{cast_as_text}#{col_alias}"
                     elsif col.type # Could be Sqlite or Oracle
                       if col_alias || !(/^[a-z0-9_]+$/ =~ col_name)
                         "#{tbl_no_schema}.\"#{col_name}\"#{col_alias}"
                       else
                         "#{tbl_no_schema}.#{col_name}"
                       end
                     else # Oracle with a custom data type
                       typ = col.sql_type
                       "'<#{typ.end_with?('_TYP') ? typ[0..-5] : typ}>' AS #{col.name}"
                     end
        end
      end

      if join_array.present?
        left_outer_joins!(join_array)
        # Touching AREL AST walks the JoinDependency tree, and in that process uses our
        # "brick_links" patch to find how every AR chain of association names relates to exact
        # table correlation names chosen by AREL.  We use a duplicate relation object for this
        # because an important side-effect of referencing the AST is that the @arel instance
        # variable gets set, and this is a signal to ActiveRecord that a relation has now
        # become immutable.  (We aren't quite ready for our "real deal" relation object to be
        # set in stone ... still need to add .select(), and possibly .where() and .order()
        # things ... also if there are any HM counts then an OUTER JOIN for each of them out
        # to a derived table to do that counting.  All of these things need to know proper
        # table correlation names, which will now become available in brick_links on the
        # rel_dupe object.)
        (rel_dupe = dup).arel.ast

        core_selects = selects.dup
        id_for_tables = Hash.new { |h, k| h[k] = [] }
        field_tbl_names = Hash.new { |h, k| h[k] = {} }
        used_col_aliases = {} # Used to make sure there is not a name clash

        # CUSTOM COLUMNS
        # ==============
        klass._br_cust_cols.each do |k, cc|
          if rel_dupe.respond_to?(k) # Name already taken?
            # %%% Use ensure_unique here in this kind of fashion:
            # cnstr_name = ensure_unique(+"(brick) #{for_tbl}_#{pri_tbl}", bts, hms)
            # binding.pry
            next
          end

          key_klass = nil
          key_tbl_name = nil
          dest_pk = nil
          key_alias = nil
          cc.first.each do |cc_part|
            dest_klass = cc_part[0..-2].inject(klass) do |kl, cc_part_term|
              # %%% Clear column info properly so we can do multiple subsequent requests
              # binding.pry unless kl.reflect_on_association(cc_part_term)
              kl.reflect_on_association(cc_part_term)&.klass || klass
            end
            tbl_name = rel_dupe.brick_links[cc_part[0..-2].map(&:to_s).join('.')]
            # Deal with the conflict if there are two parts in the custom column named the same,
            # "category.name" and "product.name" for instance will end up with aliases of "name"
            # and "product__name".
            if (cc_part_idx = cc_part.length - 1).zero?
              col_alias = "br_cc_#{k}__#{table_name.tr('.', '_')}"
            else
              while cc_part_idx > 0 &&
                    (col_alias = "br_cc_#{k}__#{cc_part[cc_part_idx..-1].map(&:to_s).join('__').tr('.', '_')}") &&
                    used_col_aliases.key?(col_alias)
                cc_part_idx -= 1
              end
            end
            used_col_aliases[col_alias] = nil
            # Set up custom column links by preparing key_klass and key_alias
            # (If there are multiple different tables referenced in the DSL, we end up creating a link to the last one)
            if cc[2] && (dest_pk = dest_klass.primary_key)
              key_klass = dest_klass
              key_tbl_name = tbl_name
              cc_part_idx = cc_part.length - 1
              while cc_part_idx > 0 &&
                    (key_alias = "br_cc_#{k}__#{(cc_part[cc_part_idx..-2] + [dest_pk]).map(&:to_s).join('__')}") &&
                    key_alias != col_alias && # We break out if this key alias does exactly match the col_alias
                    used_col_aliases.key?(key_alias)
                cc_part_idx -= 1
              end
            end
            selects << "#{tbl_name}.#{cc_part.last} AS #{col_alias}"
            cc_part << col_alias
          end
          # Add a key column unless we've already got it
          if key_alias && !used_col_aliases.key?(key_alias)
            selects << "#{key_tbl_name}.#{dest_pk} AS #{key_alias}"
            used_col_aliases[key_alias] = nil
          end
          cc[2] = key_alias ? [key_klass, key_alias] : nil
        end

        klass._br_bt_descrip.each do |v|
          v.last.each do |k1, v1| # k1 is class, v1 is array of columns to snag
            next unless (tbl_name = rel_dupe.brick_links[v.first.to_s]&.split('.')&.last)

            # If it's Oracle, quote any AREL aliases that had been applied
            tbl_name = "\"#{tbl_name}\"" if ::Brick.is_oracle && rel_dupe.brick_links.values.include?(tbl_name)
            field_tbl_name = nil
            v1.map { |x| [x[0..-2].map(&:to_s).join('.'), x.last] }.each_with_index do |sel_col, idx|
              # %%% Strangely in Rails 7.1 on a slower system then very rarely brick_link comes back nil...
              brick_link = rel_dupe.brick_links[sel_col.first]
              field_tbl_name = brick_link&.split('.')&.last ||
                # ... so here's a best-effort guess for what the table name might be.
                rel_dupe.klass.reflect_on_association(sel_col.first)&.klass&.table_name
              # If it's Oracle, quote any AREL aliases that had been applied
              field_tbl_name = "\"#{field_tbl_name}\"" if ::Brick.is_oracle && rel_dupe.brick_links.values.include?(field_tbl_name)

              # Postgres can not use DISTINCT with any columns that are XML, so for any of those just convert to text
              is_xml = is_distinct && Brick.relations[k1.table_name]&.[](:cols)&.[](sel_col.last)&.first&.start_with?('xml')
              # If it's not unique then also include the belongs_to association name before the column name
              if used_col_aliases.key?(col_alias = "br_fk_#{v.first}__#{sel_col.last}")
                col_alias = "br_fk_#{v.first}__#{v1[idx][-2..-1].map(&:to_s).join('__')}"
              end
              selects << if is_mysql
                           "`#{field_tbl_name}`.`#{sel_col.last}` AS `#{col_alias}`"
                         elsif is_postgres
                           "\"#{field_tbl_name}\".\"#{sel_col.last}\"#{'::text' if is_xml} AS \"#{col_alias}\""
                         elsif is_mssql
                           "\"#{field_tbl_name}\".\"#{sel_col.last}\" AS \"#{col_alias}\""
                         else
                           "#{field_tbl_name}.#{sel_col.last} AS \"#{col_alias}\""
                         end
              used_col_aliases[col_alias] = nil
              v1[idx] << col_alias
            end

            unless id_for_tables.key?(v.first)
              # Accommodate composite primary key by allowing id_col to come in as an array
              ((id_col = k1.primary_key).is_a?(Array) ? id_col : [id_col]).each do |id_part|
                id_for_tables[v.first] << if id_part
                                            selects << if is_mysql
                                                         "#{"`#{tbl_name}`.`#{id_part}`"} AS `#{(id_alias = "br_fk_#{v.first}__#{id_part}")}`"
                                                       elsif is_postgres || is_mssql
                                                         "#{"\"#{tbl_name}\".\"#{id_part}\""} AS \"#{(id_alias = "br_fk_#{v.first}__#{id_part}")}\""
                                                       else
                                                         "#{"#{tbl_name}.#{id_part}"} AS \"#{(id_alias = "br_fk_#{v.first}__#{id_part}")}\""
                                                       end
                                            id_alias
                                          end
              end
              v1 << id_for_tables[v.first].compact
            end
          end
        end
        join_array.each do |assoc_name|
          next unless assoc_name.is_a?(Symbol)

          table_alias = rel_dupe.brick_links[assoc_name.to_s]
          _assoc_names[assoc_name] = [table_alias, klass]
        end
      end
      # Add derived table JOIN for the has_many counts
      nix = []
      klass._br_hm_counts.each do |k, hm|
        count_column = if hm.options[:through]
                         # Build the chain of JOINs going to the final destination HMT table
                         # (Usually just one JOIN, but could be many.)
                         hmt_assoc = hm
                         through_sources = []
                         # %%% Inverse path back to the original object -- not yet used, but soon
                         # will be leveraged in order to build links with multi-table-hop filters.
                         link_back = []
                         # Track polymorphic type field if necessary
                         if hm.source_reflection.options[:as]
                           poly_ft = [hm.source_reflection.inverse_of.foreign_type, hmt_assoc.source_reflection.class_name]
                         end
                         # link_back << hm.source_reflection.inverse_of.name
                         while hmt_assoc.options[:through] && (hmt_assoc = klass.reflect_on_association(hmt_assoc.options[:through]))
                           through_sources.unshift(hmt_assoc)
                         end
                         # Turn the last member of link_back into a foreign key
                         link_back << hmt_assoc.source_reflection.foreign_key
                         # If it's a HMT based on a HM -> HM, must JOIN the last table into the mix at the end
                         through_sources.push(hm.source_reflection) unless hm.source_reflection.belongs_to?
                         from_clause = +"#{through_sources.first.table_name} br_t0"
                         fk_col = through_sources.shift.foreign_key

                         idx = 0
                         bail_out = nil
                         through_sources.map do |a|
                           from_clause << "\n LEFT OUTER JOIN #{a.table_name} br_t#{idx += 1} "
                           from_clause << if (src_ref = a.source_reflection).macro == :belongs_to
                                            nm = hmt_assoc.source_reflection.inverse_of&.name
                                            link_back << nm
                                            "ON br_t#{idx}.id = br_t#{idx - 1}.#{a.foreign_key}"
                                          elsif src_ref.options[:as]
                                            "ON br_t#{idx}.#{src_ref.type} = '#{src_ref.active_record.name}'" + # "polymorphable_type"
                                            " AND br_t#{idx}.#{src_ref.foreign_key} = br_t#{idx - 1}.id"
                                          elsif src_ref.options[:source_type]
                                            if a == hm.source_reflection
                                              print "Skipping #{hm.name} --HMT-> #{hm.source_reflection.name} as it uses source_type in a way which is not yet supported"
                                              nix << k
                                              bail_out = true
                                              break
                                              # "ON br_t#{idx}.#{a.foreign_type} = '#{src_ref.options[:source_type]}' AND " \
                                              #   "br_t#{idx}.#{a.foreign_key} = br_t#{idx - 1}.id"
                                            else # Works for HMT through a polymorphic HO
                                              link_back << hmt_assoc.source_reflection.inverse_of&.name # Some polymorphic "_able" thing
                                              "ON br_t#{idx - 1}.#{a.foreign_type} = '#{src_ref.options[:source_type]}' AND " \
                                                "br_t#{idx - 1}.#{a.foreign_key} = br_t#{idx}.id"
                                            end
                                          else # Standard has_many or has_one
                                            # binding.pry unless (
                                            nm = hmt_assoc.source_reflection.inverse_of&.name
                                            # )
                                            link_back << nm # if nm
                                            "ON br_t#{idx}.#{a.foreign_key} = br_t#{idx - 1}.id"
                                          end
                           link_back.unshift(a.source_reflection.name)
                           [a.table_name, a.foreign_key, a.source_reflection.macro]
                         end
                         next if bail_out

                         # puts "LINK BACK! #{k} : #{hm.table_name} #{link_back.map(&:to_s).join('.')}"
                         # count_column is determined from the originating HMT member
                         if (src_ref = hm.source_reflection).nil?
                           puts "*** Warning:  Could not determine destination model for this HMT association in model #{klass.name}:\n  has_many :#{hm.name}, through: :#{hm.options[:through]}"
                           puts
                           nix << k
                           next
                         elsif src_ref.macro == :belongs_to # Traditional HMT using an associative table
                           # binding.pry if link_back.length > 2
                           "br_t#{idx}.#{hm.foreign_key}"
                         else # A HMT that goes HM -> HM, something like Categories -> Products -> LineItems
                           # binding.pry if link_back.length > 2
                           "br_t#{idx}.#{src_ref.active_record.primary_key}"
                         end
                       else
                         fk_col = (inv = hm.inverse_of)&.foreign_key || hm.foreign_key
                         poly_type = inv.foreign_type if hm.options.key?(:as)
                         pk = hm.klass.primary_key
                         (pk.is_a?(Array) ? pk.first : pk) || '*'
                       end
        next unless count_column # %%% Would be able to remove this when multiple foreign keys to same destination becomes bulletproof

        tbl_alias = if is_mysql
                      "`b_r_#{hm.name}`"
                    elsif is_postgres
                      "\"b_r_#{hm.name}\""
                    else
                      "b_r_#{hm.name}"
                    end
        pri_tbl = hm.active_record
        pri_tbl_name = is_mysql ? "`#{pri_tbl.table_name}`" : "\"#{pri_tbl.table_name.gsub('.', '"."')}\""
        pri_tbl_name = if is_mysql
                         "`#{pri_tbl.table_name}`"
                       elsif is_postgres || is_mssql
                         "\"#{pri_tbl.table_name.gsub('.', '"."')}\""
                       else
                         pri_tbl.table_name
                       end
        on_clause = []
        hm_selects = if fk_col.is_a?(Array) # Composite key?
                       fk_col.each_with_index { |fk_col_part, idx| on_clause << "#{tbl_alias}.#{fk_col_part} = #{pri_tbl_name}.#{pri_tbl.primary_key[idx]}" }
                       fk_col.dup
                     else
                       on_clause << "#{tbl_alias}.#{fk_col} = #{pri_tbl_name}.#{pri_tbl.primary_key}"
                       [fk_col]
                     end
        if poly_type
          hm_selects << poly_type
          on_clause << "#{tbl_alias}.#{poly_type} = '#{name}'"
        end
        unless from_clause
          tbl_nm = hm.macro == :has_and_belongs_to_many ? hm.join_table : hm.table_name
          hm_table_name = if is_mysql
                            "`#{tbl_nm}`"
                          elsif is_postgres || is_mssql
                            "\"#{(tbl_nm).gsub('.', '"."')}\""
                          else
                            tbl_nm
                          end
        end
        group_bys = ::Brick.is_oracle || is_mssql ? hm_selects : (1..hm_selects.length).to_a
        join_clause = "LEFT OUTER
JOIN (SELECT #{hm_selects.map { |s| "#{'br_t0.' if from_clause}#{s}" }.join(', ')}, COUNT(#{'DISTINCT ' if hm.options[:through]}#{count_column
          }) AS c_t_ FROM #{from_clause || hm_table_name} GROUP BY #{group_bys.join(', ')}) #{tbl_alias}"
        self.joins_values |= ["#{join_clause} ON #{on_clause.join(' AND ')}"] # Same as:  joins!(...)
      end
      while (n = nix.pop)
        klass._br_hm_counts.delete(n)
      end

      unless wheres.empty?
        # Rewrite the wheres to reference table and correlation names built out by AREL
        where_nots = {}
        wheres2 = wheres.each_with_object({}) do |v, s|
          is_not = if v.first[-1] == '!'
                     v[0] = v[0][0..-2] # Take off ending ! from column name
                   end
          if (v_parts = v.first.split('.')).length == 1
            (is_not ? where_nots : s)[v.first] = v.last
          else
            tbl_name = rel_dupe.brick_links[v_parts.first].split('.').last
            (is_not ? where_nots : s)["#{tbl_name}.#{v_parts.last}"] = v.last
          end
        end
        if respond_to?(:where!)
          where!(wheres2) if wheres2.present?
          if where_nots.present?
            self.where_clause += WhereClause.new(predicate_builder.build_from_hash(where_nots)).invert
          end
        else # AR < 4.0
          self.where_values << build_where(wheres2)
        end
      end
      # Must parse the order_by and see if there are any symbols which refer to BT associations
      # or custom columns as they must be expanded to find the corresponding b_r_model__column
      # or br_cc_column naming for each.
      if order_by.present?
        final_order_by = *order_by.each_with_object([]) do |v, s|
          if v.is_a?(Symbol)
            # Add the ordered series of columns derived from the BT based on its DSL
            if (bt_cols = klass._br_bt_descrip[v])
              bt_cols.values.each do |v1|
                v1.each { |v2| s << "\"#{v2.last}\"" if v2.length > 1 }
              end
            elsif (cc_cols = klass._br_cust_cols[v])
              cc_cols.first.each { |v1| s << "\"#{v1.last}\"" if v1.length > 1 }
            else
              s << v
            end
          else # String stuff (which defines a custom ORDER BY) just comes straight through
            s << v
            # Avoid "PG::InvalidColumnReference: ERROR: for SELECT DISTINCT, ORDER BY expressions must appear in select list" in Postgres
            selects << v if is_distinct
          end
        end
        self.order_values |= final_order_by # Same as:  order!(*final_order_by)
      end
      # Don't want to get too carried away just yet
      self.limit_value = 1000 # Same as:  limit!(1000)
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
        if ::Brick.sti_models.key?(type_name ||= name)
          # Used to be:  ::Brick.sti_models[type_name].fetch(:base, nil) || _brick_find_sti_class(type_name)
          _brick_find_sti_class(type_name)
        else
          # This auto-STI is more of a brute-force approach, building modules where needed
          # The more graceful alternative is the overload of ActiveSupport::Dependencies#autoload_module! found below
          ::Brick.sti_models[type_name] = { base: self } unless type_name.blank?
          module_prefixes = type_name.split('::')
          module_prefixes.unshift('') unless module_prefixes.first.blank?
          module_name = module_prefixes[0..-2].join('::')
          if (snp = ::Brick.config.sti_namespace_prefixes)&.key?("::#{module_name}::") || snp&.key?("#{module_name}::") ||
             File.exist?(candidate_file = ::Rails.root.join('app/models' + module_prefixes.map(&:underscore).join('/') + '.rb'))
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
            begin
              if this_module.const_defined?(class_name = module_prefixes.last.to_sym)
                this_module.const_get(class_name)
              else
                # Build STI subclass and place it into the namespace module
                this_module.const_set(class_name, klass = Class.new(self))
                klass
              end
            rescue NameError => err
              if column_names.include?(inheritance_column)
                puts "Table #{table_name} has column #{inheritance_column} which ActiveRecord expects to use as its special inheritance column."
                puts "Unfortunately the value \"#{type_name}\" does not seem to refer to a valid type name, greatly confusing matters.  If that column is intended to be used for data and not STI, consider putting this line into your Brick initializer so that only for this table that column will not clash with ActiveRecord:"
                puts "  Brick.sti_type_column = { 'rails_#{inheritance_column}' => ['#{table_name}'] }"
                self
              else
                raise
              end
            end
          end
        end
      end
    end
  end
end

if Object.const_defined?('ActionView')
  require 'brick/frameworks/rails/form_tags'
  module ActionView::Helpers::FormTagHelper
    include ::Brick::Rails::FormTags
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
        if (base_class_name = ::Brick.config.sti_namespace_prefixes&.fetch("::#{into.name}::", nil))
          base_class_name = "::#{base_class_name}" unless base_class_name.start_with?('::')
        end
        if (base_class = base_class_name&.constantize)
          ::Brick.sti_models[qualified_name] = { base: base_class }
          # Build subclass and place it into the specially STI-namespaced module
          into.const_set(const_name.to_sym, klass = Class.new(base_class))
          # %%% used to also have:  autoload_once_paths.include?(base_path) ||
          autoloaded_constants << qualified_name unless autoloaded_constants.include?(qualified_name)
          klass
        elsif (base_class = ::Brick.config.sti_namespace_prefixes&.fetch("::#{const_name}", nil)&.constantize)
          begin
            # Attempt to find an existing implementation for this subclass
            base_class.module_parent.const_get(const_name)
          rescue
            # Build subclass and place it in the same module as its parent
            base_class.module_parent.const_set(const_name.to_sym, klass = Class.new(base_class))
          end
        else
          _brick_autoload_module!(*args)
        end
      end
    end
  end
end

Module.class_exec do
  alias _brick_const_missing const_missing
  def const_missing(*args)
    requested = args.first.to_s
    is_controller = requested.end_with?('Controller')
    # self.name is nil when a model name is requested in an .erb file
    if self.name && ::Brick.config.path_prefix
      camelize_prefix = ::Brick.config.path_prefix.camelize
      # Asking for the prefix module?
      if self == Object && requested == camelize_prefix
        Object.const_set(args.first, (built_module = Module.new))
        puts "module #{camelize_prefix}; end\n"
        return built_module
      end
      split_self_name.shift if (split_self_name = self.name.split('::')).first.blank?
      if split_self_name.first == camelize_prefix
        split_self_name.shift # Remove the identified path prefix from the split name
        if is_controller
          brick_root = split_self_name.empty? ? self : camelize_prefix.constantize
        end
      end
    end
    base_module = if self < ActiveRecord::Migration || !self.name
                    brick_root || Object
                  elsif (split_self_name || self.name.split('::')).length > 1 # Classic mode
                    begin
                      return self._brick_const_missing(*args)

                    rescue NameError # %%% Avoid the error "____ cannot be autoloaded from an anonymous class or module"
                      return self.const_get(args.first) if self.const_defined?(args.first)

                      # unless self == (prnt = (respond_to?(:parent) ? parent : module_parent))
                      unless self == Object
                        begin
                          return Object._brick_const_missing(*args)

                        rescue NameError
                          return Object.const_get(args.first) if Object.const_defined?(args.first)

                        end
                      end
                    end
                    Object
                  else
                    self
                  end
    # puts "#{self.name} - #{args.first}"
    desired_classname = (self == Object || !name) ? requested : "#{name}::#{requested}"
    if ((is_defined = self.const_defined?(args.first)) && (possible = self.const_get(args.first)) && possible.name == desired_classname) ||
       # Try to require the respective Ruby file
       ((filename = ActiveSupport::Dependencies.search_for_file(desired_classname.underscore) ||
                    (self != Object && ActiveSupport::Dependencies.search_for_file((desired_classname = requested).underscore))
        ) && (require_dependency(filename) || true) &&
        ((possible = self.const_get(args.first)) && possible.name == desired_classname)
       ) ||
       # If any class has turned up so far (and we're not in the middle of eager loading)
       # then return what we've found.
       (is_defined && !::Brick.is_eager_loading) # Used to also have:   && possible != self
      if (!brick_root && (filename || possible.instance_of?(Class))) ||
         (possible.instance_of?(Module) && possible.module_parent == self) ||
         (possible.instance_of?(Class) && possible == self) # Are we simply searching for ourselves?
        return possible
      end
    end
    class_name = ::Brick.namify(requested)
    relations = ::Brick.relations
    #        CONTROLLER
    result = if ::Brick.enable_controllers? &&
                is_controller && (plural_class_name = class_name[0..-11]).length.positive?
               # Otherwise now it's up to us to fill in the gaps
               full_class_name = +''
               full_class_name << "::#{(split_self_name&.first && split_self_name.join('::')) || self.name}" unless self == Object
               # (Go over to underscores for a moment so that if we have something come in like VABCsController then the model name ends up as
               # Vabc instead of VABC)
               singular_class_name = ::Brick.namify(plural_class_name, :underscore).singularize.camelize
               full_class_name << "::#{singular_class_name}"
               if plural_class_name == 'BrickOpenapi' ||
                  (
                    (::Brick.config.add_status || ::Brick.config.add_orphans) &&
                    plural_class_name == 'BrickGem'
                  ) ||
                  model = self.const_get(full_class_name)
                 # if it's a controller and no match or a model doesn't really use the same table name, eager load all models and try to find a model class of the right name.
                 Object.send(:build_controller, self, class_name, plural_class_name, model, relations)
               end

             # MODULE
             elsif (::Brick.enable_models? || ::Brick.enable_controllers?) && # Schema match?
                   base_module == Object && # %%% This works for Person::Person -- but also limits us to not being able to allow more than one level of namespacing
                   (schema_name = [(singular_table_name = class_name.underscore),
                                   (table_name = singular_table_name.pluralize),
                                   ::Brick.is_oracle ? class_name.upcase : class_name,
                                   (plural_class_name = class_name.pluralize)].find { |s| Brick.db_schemas&.include?(s) }&.camelize ||
                                  (::Brick.config.sti_namespace_prefixes&.key?("::#{class_name}::") && class_name) ||
                                  (::Brick.config.table_name_prefixes.values.include?(class_name) && class_name))
               return self.const_get(schema_name) if self.const_defined?(schema_name)

               # Build out a module for the schema if it's namespaced
               # schema_name = schema_name.camelize
               base_module.const_set(schema_name.to_sym, (built_module = Module.new))

               [built_module, "module #{schema_name}; end\n"]
               #  # %%% Perhaps an option to use the first module just as schema, and additional modules as namespace with a table name prefix applied

             # AVO Resource
             elsif base_module == Object && Object.const_defined?('Avo') && requested.end_with?('Resource') &&
                   ['MotorResource'].exclude?(requested) # Expect that anything called MotorResource could be from that administrative gem
               if (model = Object.const_get(requested[0..-9]))
                 require 'generators/avo/resource_generator'
                 field_generator = Generators::Avo::ResourceGenerator.new([''])
                 field_generator.instance_variable_set(:@model, model)
                 fields = field_generator.send(:generate_fields).split("\n")
                                         .each_with_object([]) do |f, s|
                                           if (f = f.strip).start_with?('field ')
                                             f = f[6..-1].split(',')
                                             s << [f.first[1..-1].to_sym, [f[1][1..-1].split(': :').map(&:to_sym)].to_h]
                                           end
                                         end
                 built_resource = Class.new(Avo::BaseResource) do |new_resource_class|
                   self.model_class = model
                   self.title = :brick_descrip
                   self.includes = []
                   if (!model.is_view? && mod_pk = model.primary_key)
                     field((mod_pk.is_a?(Array) ? mod_pk.first : mod_pk).to_sym, { as: :id })
                   end
                   # Create a call such as:  field :name, as: :text
                   fields.each do |f|
                     # Add proper types if this is a polymorphic belongs_to
                     if f.last == { as: :belongs_to } &&
                        (fk = ::Brick.relations[model.table_name][:fks].find { |k, v| v[:assoc_name] == f.first.to_s }) &&
                        fk.last.fetch(:polymorphic, nil)
                       poly_types = fk.last.fetch(:inverse_table, nil)&.each_with_object([]) do |poly_table, s|
                         s << Object.const_get(::Brick.relations[poly_table][:class_name])
                       end
                       if poly_types.present?
                         f.last[:polymorphic_as] = f.first
                         f.last[:types] = poly_types
                       end
                     end
                     self.send(:field, *f)
                   end
                 end
                 Object.const_set(requested.to_sym, built_resource)
                 [built_resource, nil]
               end

             # MODEL
             elsif ::Brick.enable_models?
               # Custom inheritable Brick base model?
               class_name = (inheritable_name = class_name)[5..-1] if class_name.start_with?('Brick')
               Object.send(:build_model, relations, base_module, name, class_name, inheritable_name)
             end
    if result
      built_class, code = result
      puts "\n#{code}\n"
      built_class
    elsif ::Brick.config.sti_namespace_prefixes&.key?("::#{class_name}") && !schema_name
#         module_prefixes = type_name.split('::')
#         path = base_module.name.split('::')[0..-2] + []
#         module_prefixes.unshift('') unless module_prefixes.first.blank?
#         candidate_file = ::Rails.root.join('app/models' + module_prefixes.map(&:underscore).join('/') + '.rb')
      base_module._brick_const_missing(*args)
    # elsif base_module != Object
    #   module_parent.const_missing(*args)
    elsif Rails.respond_to?(:autoloaders) && # After finding nothing else, if Zeitwerk is enabled ...
          (Rails::Autoloaders.respond_to?(:zeitwerk_enabled?) ? Rails::Autoloaders.zeitwerk_enabled? : true)
      self._brick_const_missing(*args) # ... rely solely on Zeitwerk.
    else # Classic mode
      unless (found = base_module._brick_const_missing(*args))
        puts "MISSING! #{base_module.name} #{args.inspect} #{table_name}"
      end
      found
    end
  end

  # Support Rails < 6.0 which adds #parent instead of #module_parent
  unless respond_to?(:module_parent)
    def module_parent # Weirdly for Grape::API does NOT come in with the proper class, but some anonymous Class thing
      parent
    end
  end
end

class Object
  class << self

  private

    def build_model(relations, base_module, base_name, class_name, inheritable_name = nil)
      tnp = ::Brick.config.table_name_prefixes&.find { |p| p.last == base_module.name }&.first
      if (base_model = ::Brick.config.sti_namespace_prefixes&.fetch("::#{base_module.name}::", nil)&.constantize) || # Are we part of an auto-STI namespace? ...
         base_module != Object # ... or otherwise already in some namespace?
        schema_name = [(singular_schema_name = base_name.underscore),
                       (schema_name = singular_schema_name.pluralize),
                       base_name,
                       base_name.pluralize].find { |s| Brick.db_schemas&.include?(s) }
      end
      plural_class_name = ActiveSupport::Inflector.pluralize(model_name = class_name)
      # If it's namespaced then we turn the first part into what would be a schema name
      singular_table_name = ActiveSupport::Inflector.underscore(model_name).gsub('/', '.')

      if base_model
        schema_name = base_name.underscore # For the auto-STI namespace models
        table_name = base_model.table_name
        build_model_worker(base_module, inheritable_name, model_name, singular_table_name, table_name, relations, table_name)
      else
        # Adjust for STI if we know of a base model for the requested model name
        # %%% Does not yet work with namespaced model names.  Perhaps prefix with plural_class_name when doing the lookups here.
        table_name = if (base_model = ::Brick.sti_models[model_name]&.fetch(:base, nil) || ::Brick.existing_stis[model_name]&.constantize)
                       base_model.table_name
                     else
                       "#{tnp}#{ActiveSupport::Inflector.pluralize(singular_table_name)}"
                     end
        if ::Brick.apartment_multitenant &&
           Apartment.excluded_models.include?(table_name.singularize.camelize)
          schema_name = ::Brick.apartment_default_tenant
        end
        # Maybe, just maybe there's a database table that will satisfy this need
        if (matching = [table_name, singular_table_name, plural_class_name, model_name, table_name.titleize].find { |m| relations.key?(schema_name ? "#{schema_name}.#{m}" : m) })
          build_model_worker(schema_name, inheritable_name, model_name, singular_table_name, table_name, relations, matching)
        end
      end
    end

    def build_model_worker(schema_name, inheritable_name, model_name, singular_table_name, table_name, relations, matching)
      if ::Brick.apartment_multitenant &&
         schema_name == ::Brick.apartment_default_tenant
        relation = relations["#{schema_name}.#{matching}"]
      end
      full_name = if relation || schema_name.blank?
                    inheritable_name || model_name
                  else # Prefix the schema to the table name + prefix the schema namespace to the class name
                    schema_module = if schema_name.instance_of?(Module) # from an auto-STI namespace?
                                      schema_name
                                    else
                                      matching = "#{schema_name}.#{matching}"
                                      (::Brick.db_schemas[schema_name] || {})[:class] ||= self.const_get(schema_name.camelize.to_sym)
                                    end
                    "#{schema_module&.name}::#{inheritable_name || model_name}"
                  end

      return if ((is_view = (relation ||= relations[matching]).key?(:isView)) && ::Brick.config.skip_database_views) ||
                ::Brick.config.exclude_tables.include?(matching)

      # Are they trying to use a pluralised class name such as "Employees" instead of "Employee"?
      if table_name == singular_table_name && !ActiveSupport::Inflector.inflections.uncountable.include?(table_name)
        # unless ::Brick.config.sti_namespace_prefixes&.key?("::#{singular_table_name.camelize}::")
        #   puts "Warning: Class name for a model that references table \"#{matching
        #        }\" should be \"#{ActiveSupport::Inflector.singularize(inheritable_name || model_name)}\"."
        # end
        return unless singular_table_name.singularize.blank?
      end

      full_model_name = full_name.split('::').tap { |fn| fn[-1] = model_name }.join('::')
      if (base_model = ::Brick.sti_models[full_model_name]&.fetch(:base, nil) || ::Brick.existing_stis[full_model_name]&.constantize)
        is_sti = true
      else
        base_model = ::Brick.config.models_inherit_from
      end
      hmts = nil
      code = +"class #{full_name} < #{base_model.name}\n"
      built_model = Class.new(base_model) do |new_model_class|
        (schema_module || Object).const_set((inheritable_name || model_name).to_sym, new_model_class)
        if inheritable_name
          new_model_class.define_singleton_method :inherited do |subclass|
            super(subclass)
            if subclass.name == model_name
              puts "#{full_model_name} properly extends from #{full_name}"
            else
              puts "should be \"class #{model_name} < #{inheritable_name}\"\n           (not \"#{subclass.name} < #{inheritable_name}\")"
            end
          end
          self.abstract_class = true
          code << "  self.abstract_class = true\n"
        end
        # Accommodate singular or camel-cased table names such as "order_detail" or "OrderDetails"
        code << "  self.table_name = '#{self.table_name = matching}'\n" if inheritable_name || table_name != matching

        # Override models backed by a view so they return true for #is_view?
        # (Dynamically-created controllers and view templates for such models will then act in a read-only way)
        if is_view
          new_model_class.define_singleton_method :'is_view?' do
            true
          end
          code << "  def self.is_view?; true; end\n"

          new_model_class.primary_key = nil
          code << "  self.primary_key = nil\n"

          new_model_class.define_method :'readonly?' do
            true
          end
          code << "  def readonly?; true; end\n"
        else
          db_pks = relation[:cols]&.map(&:first)
          has_pk = (bpk = _brick_primary_key(relation)).present? && (db_pks & bpk).sort == bpk.sort
          our_pks = relation[:pkey].values.first
          # No primary key, but is there anything UNIQUE?
          # (Sort so that if there are multiple UNIQUE constraints we'll pick one that uses the least number of columns.)
          our_pks = relation[:ukeys].values.sort { |a, b| a.length <=> b.length }.first unless our_pks&.present?
          if has_pk
            code << "  # Primary key: #{_brick_primary_key.join(', ')}\n" unless _brick_primary_key == ['id']
          elsif our_pks&.present?
            if our_pks.length > 1 && respond_to?(:'primary_keys=') # Using the composite_primary_keys gem?
              new_model_class.primary_keys = our_pks
              code << "  self.primary_keys = #{our_pks.map(&:to_sym).inspect}\n"
            else
              new_model_class.primary_key = (pk_sym = our_pks.first.to_sym)
              code << "  self.primary_key = #{pk_sym.inspect}\n"
            end
            _brick_primary_key(relation) # Set the newly-found PK in the instance variable
          elsif (possible_pk = ActiveRecord::Base.get_primary_key(base_class.name)) && relation[:cols][possible_pk]
            new_model_class.primary_key = (possible_pk = possible_pk.to_sym)
            code << "  self.primary_key = #{possible_pk.inspect}\n"
          else
            code << "  # Could not identify any column(s) to use as a primary key\n"
          end
        end

        if (sti_col = relation.fetch(:sti_col, nil))
          new_model_class.send(:'inheritance_column=', sti_col)
          code << "  self.inheritance_column = #{sti_col.inspect}\n"
        end

        unless is_sti
          fks = relation[:fks] || {}
          # Do the bulk of the has_many / belongs_to processing, and store details about HMT so they can be done at the very last
          hmts = fks.each_with_object(Hash.new { |h, k| h[k] = [] }) do |fk, hmts|
            # The key in each hash entry (fk.first) is the constraint name
            inverse_assoc_name = (assoc = fk.last)[:inverse]&.fetch(:assoc_name, nil)
            if (invs = assoc[:inverse_table]).is_a?(Array)
              if assoc[:is_bt]
                invs = invs.first # Just do the first one of what would be multiple identical polymorphic belongs_to
              else
                invs.each { |inv| build_bt_or_hm(full_name, relations, relation, hmts, assoc, inverse_assoc_name, inv, code) }
              end
            end
            build_bt_or_hm(full_name, relations, relation, hmts, assoc, inverse_assoc_name, invs, code) unless invs.is_a?(Array)
            hmts
          end
          # # Not NULLables
          # # %%% For the minute we've had to pull this out because it's been troublesome implementing the NotNull validator
          # relation[:cols].each do |col, datatype|
          #   if (datatype[3] && _brick_primary_key.exclude?(col) && ::Brick.config.metadata_columns.exclude?(col)) ||
          #      ::Brick.config.not_nullables.include?("#{matching}.#{col}")
          #     code << "  validates :#{col}, not_null: true\n"
          #     self.send(:validates, col.to_sym, { not_null: true })
          #   end
          # end
        end
      end # class definition
      # Having this separate -- will this now work out better?
        built_model.class_exec do
          @_brick_built = true
          hmts&.each do |hmt_fk, hms|
            hmt_fk = hmt_fk.tr('.', '_')
            hms.each do |hm|
              # %%% Need to confirm that HMTs work when they are built from has_manys with custom names
              through = ::Brick.config.schema_behavior[:multitenant] ? hm.first[:assoc_name] : hm.first[:inverse_table].tr('.', '_').pluralize
              options = {}
              hmt_name = if hms.length > 1
                           if hms[0].first[:inverse][:assoc_name] == hms[1].first[:inverse][:assoc_name] # Same BT names pointing back to us? (Most common scenario)
                             "#{hmt_fk}_through_#{hm.first[:assoc_name]}"
                           else # Use BT names to provide uniqueness
                             if self.name.underscore.singularize == hm.first[:alternate_name]
                               #  Has previously been:
                               # # If it folds back on itself then look at the other side
                               # # (At this point just infer the source be the inverse of the first has_many that
                               # # we find that is not ourselves.  If there are more than two then uh oh, can't
                               # # yet handle that rare circumstance!)
                               # other = hms.find { |hm1| hm1 != hm } # .first[:fk]
                               # options[:source] = other.first[:inverse][:assoc_name].to_sym
                               #  And also has been:
                               # hm.first[:inverse][:assoc_name].to_sym
                               options[:source] = hm.last.to_sym
                             else
                               through = hm.first.fetch(:alternate_chosen_name, hm.first[:alternate_name])
                             end
                             singular_assoc_name = hm.first[:inverse][:assoc_name].singularize
                             "#{singular_assoc_name}_#{hmt_fk}"
                           end
                         else
                           hmt_fk
                         end
              options[:through] = through.to_sym
              if relation[:fks].any? { |k, v| v[:assoc_name] == hmt_name }
                hmt_name = "#{hmt_name.singularize}_#{hm.first[:assoc_name]}"
                # Was:
                # options[:class_name] = hm.first[:inverse_table].singularize.camelize
                # options[:foreign_key] = hm.first[:fk].to_sym
                far_assoc = relations[hm.first[:inverse_table]][:fks].find { |_k, v| v[:assoc_name] == hm.last }
                options[:class_name] = far_assoc.last[:inverse_table].singularize.camelize
                options[:foreign_key] = far_assoc.last[:fk].to_sym
              end
              options[:source] ||= hm.last.to_sym unless hmt_name.singularize == hm.last
              code << "  has_many :#{hmt_name}#{options.map { |opt| ", #{opt.first}: #{opt.last.inspect}" }.join}\n"
              self.send(:has_many, hmt_name.to_sym, **options)
            end
          end
        end
        code << "end # model #{full_name}\n"
      [built_model, code]
    end

    def build_bt_or_hm(full_name, relations, relation, hmts, assoc, inverse_assoc_name, inverse_table, code)
      singular_table_name = inverse_table&.singularize
      options = {}
      macro = if assoc[:is_bt]
                # Try to take care of screwy names if this is a belongs_to going to an STI subclass
                assoc_name = if (primary_class = assoc.fetch(:primary_class, nil)) &&
                               sti_inverse_assoc = primary_class.reflect_on_all_associations.find do |a|
                                 a.macro == :has_many && a.options[:class_name] == self.name && assoc[:fk] == a.foreign_key
                               end
                               sti_inverse_assoc.options[:inverse_of]&.to_s || assoc_name
                             else
                               assoc[:assoc_name]
                             end
                options[:optional] = true if assoc.key?(:optional)
                if assoc.key?(:polymorphic)
                  options[:polymorphic] = true
                else
                  need_class_name = singular_table_name.underscore != assoc_name
                  need_fk = "#{assoc_name}_id" != assoc[:fk]
                end
                if (inverse = assoc[:inverse])
                  # If it's multitenant with something like:  public.____ ...
                  if (it_parts = inverse_table.split('.')).length > 1 &&
                     ::Brick.apartment_multitenant &&
                     it_parts.first == ::Brick.apartment_default_tenant
                    it_parts.shift # ... then ditch the generic schema name
                  end
                  inverse_assoc_name, _x = _brick_get_hm_assoc_name(relations[inverse_table], inverse, it_parts.join('_').singularize)
                  has_ones = ::Brick.config.has_ones&.fetch(it_parts.join('/').singularize.camelize, nil)
                  if has_ones&.key?(singular_inv_assoc_name = ActiveSupport::Inflector.singularize(inverse_assoc_name.tr('.', '_')))
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
                # Are there multiple foreign keys out to the same table?
                assoc_name, need_class_name = _brick_get_hm_assoc_name(relation, assoc)
                if assoc.key?(:polymorphic)
                  options[:as] = assoc[:fk].to_sym
                else
                  need_fk = "#{ActiveSupport::Inflector.singularize(assoc[:inverse][:inverse_table].split('.').last)}_id" != assoc[:fk]
                end
                has_ones = ::Brick.config.has_ones&.fetch(full_name, nil)
                if has_ones&.key?(singular_assoc_name = ActiveSupport::Inflector.singularize(assoc_name.tr('.', '_')))
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
      if (singular_table_parts = singular_table_name.split('.')).length > 1 &&
         ::Brick.config.schema_behavior[:multitenant] && singular_table_parts.first == 'public'
        singular_table_parts.shift
      end
      options[:class_name] = "::#{assoc[:primary_class]&.name || singular_table_parts.map(&:camelize).join('::')}" if need_class_name
      # Work around a bug in CPK where self-referencing belongs_to associations double up their foreign keys
      if need_fk # Funky foreign key?
        options[:foreign_key] = if assoc[:fk].is_a?(Array)
                                  assoc_fk = assoc[:fk].uniq
                                  assoc_fk.length < 2 ? assoc_fk.first : assoc_fk
                                else
                                  assoc[:fk].to_sym
                                end
      end
      options[:inverse_of] = inverse_assoc_name.tr('.', '_').to_sym if inverse_assoc_name && (need_class_name || need_fk || need_inverse_of)

      # Prepare a list of entries for "has_many :through"
      if macro == :has_many
        relations[inverse_table][:hmt_fks].each do |k, hmt_fk|
          next if k == assoc[:fk]

          hmts[ActiveSupport::Inflector.pluralize(hmt_fk.last)] << [assoc, hmt_fk.first]
        end
      end
      # And finally create a has_one, has_many, or belongs_to for this association
      assoc_name = assoc_name.tr('.', '_').to_sym
      code << "  #{macro} #{assoc_name.inspect}#{options.map { |k, v| ", #{k}: #{v.inspect}" }.join}\n"
      self.send(macro, assoc_name, **options)
    end

    def default_ordering(table_name, pk)
      case (order_tbl = ::Brick.config.order[table_name]) && (order_default = order_tbl[:_brick_default])
      when Array
        order_default.map { |od_part| order_tbl[od_part] || od_part }
      when Symbol
        order_tbl[order_default] || order_default
      else
        pk.map { |part| "#{table_name}.#{part}"}.join(', ') # If it's not a custom ORDER BY, just use the key
      end
    end

    def build_controller(namespace, class_name, plural_class_name, model, relations)
      if (is_avo = (namespace.name == 'Avo' && Object.const_defined?('Avo')))
        # Basic Avo functionality is available via its own generic controller.
        # (More information on https://docs.avohq.io/2.0/controllers.html)
        controller_base = Avo::ResourcesController
      end
      table_name = model&.table_name || ActiveSupport::Inflector.underscore(plural_class_name)
      singular_table_name = ActiveSupport::Inflector.singularize(ActiveSupport::Inflector.underscore(plural_class_name))
      pk = model&._brick_primary_key(relations.fetch(table_name, nil))
      is_postgres = ActiveRecord::Base.connection.adapter_name == 'PostgreSQL'
      is_mysql = ['Mysql2', 'Trilogy'].include?(ActiveRecord::Base.connection.adapter_name)

      code = +"class #{class_name} < #{controller_base&.name || 'ApplicationController'}\n"
      built_controller = Class.new(controller_base || ActionController::Base) do |new_controller_class|
        (namespace || Object).const_set(class_name.to_sym, new_controller_class)

        # Brick-specific pages
        case plural_class_name
        when 'BrickGem'
          self.define_method :status do
            instance_variable_set(:@resources, ::Brick.get_status_of_resources)
          end
          self.define_method :orphans do
            instance_variable_set(:@orphans, ::Brick.find_orphans(::Brick.set_db_schema(params).first))
          end
          self.define_method :crosstab do
            @relations = ::Brick.relations.each_with_object({}) do |r, s|
              cols = r.last[:cols].each_with_object([]) do |c, s2|
                s2 << [c.first] + c.last
              end
              s[r.first] = { cols: cols } if r.last.key?(:cols)
            end
          end

          self.define_method :crosstab_data do
            # Bring in column names and use this to create an appropriate SELECT statement
            is_grouped = nil
            fields_in_sequence = params['fields'].split(',')
            relations = {}
            first_relation = nil
            fields = fields_in_sequence.each_with_object(Hash.new { |h, k| h[k] = {} }) do |f, s|
              relation, col = if (paren_index = f.index('(')) # Aggregate?
                                aggregate = f[0..paren_index - 1]
                                f_parts = f[(paren_index + 1)..-2].split(',')
                                aggregate_options = f_parts[1..-1] # Options about aggregation
                                f_parts.first.split('/') # Column being aggregated
                              else
                                f.split('/')
                              end
              first_relation ||= relation
              # relation = if dts[(relation = relation.downcase)]
              #   relation # Generally a common JOIN point, but who knows, maybe we'll add more
              # else
              #   relation
              # end
              if col
                relations[relation] = nil
                s[f] = if aggregate
                         is_grouped = true
                         [aggregate, relation, col, aggregate_options]
                       else
                         [relation, col]
                       end
              end
              s
            end
            # ver = params['ver']
            if fields.empty?
              render json: { data: [] } # [ver, []]
              return
            end

            # Apartment::Tenant.switch!(params['schema'])
            # result = ActiveRecord::Base.connection.query("SELECT #{cols.join(', ')} FROM #{view}")
            col_num = 0
            grouping = []
            cols = fields_in_sequence.each_with_object([]) do |f, s|
              c = fields[f]
              col_num += 1
              col_def = if c.length > 2 # Aggregate?
                          case c.first
                          when 'COMMA_SEP'
                            "STRING_AGG(DISTINCT #{c[1].downcase}.\"#{c[2]}\"::varchar, ',')" # Like STRING_AGG(DISTINCT v_tacos."price"::varchar, ',')
                          when 'COUNT_DISTINCT'
                            "COUNT(DISTINCT #{c[1].downcase}.\"#{c[2]}\")" # Like COUNT(DISTINCT v_tacos."price")
                          when 'MODE'
                            "MODE() WITHIN GROUP(ORDER BY #{c[1].downcase}.\"#{c[2]}\")" # Like MODE() WITHIN GROUP(ORDER BY v_tacos."price")
                          when 'NUM_DAYS'
                            "EXTRACT(DAYS FROM (MAX(#{c[1].downcase}.\"#{c[2]}\")::timestamp - MIN(#{c[1].downcase}.\"#{c[2]}\")::timestamp))" # Like EXTRACT(DAYS FROM (MAX(order."order_date") - MIN(order."order_date"))
                          else
                            "#{c.first}(#{c[1].downcase}.\"#{c[2]}\")" # Something like AVG(v_tacos."price")
                          end
                        else # Normal column, represented in an array having:  [relation, column_name]
                          grouping << col_num
                          "#{c.first.downcase}.\"#{c.last}\"" # Like v_tacos."price"
                        end
              s << "#{col_def} AS c#{col_num}"
            end
            sql = "SELECT #{cols.join(', ')} FROM #{first_relation.downcase}"
            sql << "\nGROUP BY #{grouping.map(&:to_s).join(',')}" if is_grouped && grouping.present?
            result = ActiveRecord::Base.connection.query(sql)
            render json: { data: result } # [ver, result]
          end

          return [new_controller_class, code + "end # BrickGem controller\n"]
        when 'BrickOpenapi'
          is_openapi = true
        end

        self.protect_from_forgery unless: -> { self.request.format.js? }
        unless is_avo
          self.define_method :index do
            if (is_openapi || request.env['REQUEST_PATH'].start_with?(::Brick.api_root)) &&
               !params&.key?('_brick_schema') &&
               (referrer_params = request.env['HTTP_REFERER']&.split('?')&.last&.split('&')&.map { |x| x.split('=') }).present?
              if params
                referrer_params.each { |k, v| params.send(:parameters)[k] = v }
              else
                api_params = referrer_params&.to_h
              end
            end
            _schema, @_is_show_schema_list = ::Brick.set_db_schema(params || api_params)

            if is_openapi
              json = { 'openapi': '3.0.1', 'info': { 'title': Rswag::Ui.config.config_object[:urls].last&.fetch(:name, 'API documentation'), 'version': ::Brick.config.api_version },
                       'servers': [
                         { 'url': '{scheme}://{defaultHost}', 'variables': {
                           'scheme': { 'default': request.env['rack.url_scheme'] },
                           'defaultHost': { 'default': request.env['HTTP_HOST'] }
                         } }
                       ]
                     }
              json['paths'] = relations.inject({}) do |s, relation|
                unless ::Brick.config.enable_api == false
                  table_description = relation.last[:description]
                  s["#{::Brick.config.api_root}#{relation.first.tr('.', '/')}"] = {
                    'get': {
                      'summary': "list #{relation.first}",
                      'description': table_description,
                      'parameters': relation.last[:cols].map do |k, v|
                                      param = { 'name' => k, 'schema': { 'type': v.first } }
                                      if (col_descrip = relation.last.fetch(:col_descrips, nil)&.fetch(k, nil))
                                        param['description'] = col_descrip
                                      end
                                      param
                                    end,
                      'responses': { '200': { 'description': 'successful' } }
                    }
                  }

                  s["#{::Brick.config.api_root}#{relation.first.tr('.', '/')}/{id}"] = {
                    'patch': {
                      'summary': "update a #{relation.first.singularize}",
                      'description': table_description,
                      'parameters': relation.last[:cols].reject { |k, v| Brick.config.metadata_columns.include?(k) }.map do |k, v|
                        param = { 'name' => k, 'schema': { 'type': v.first } }
                        if (col_descrip = relation.last.fetch(:col_descrips, nil)&.fetch(k, nil))
                          param['description'] = col_descrip
                        end
                        param
                      end,
                      'responses': { '200': { 'description': 'successful' } }
                    }
                  } unless relation.last.fetch(:isView, nil)
                  s
                end
              end
              render inline: json.to_json, content_type: request.format
              return
            end

            if request.format == :csv # Asking for a template?
              require 'csv'
              exported_csv = CSV.generate(force_quotes: false) do |csv_out|
                model.df_export(model.brick_import_template).each { |row| csv_out << row }
              end
              render inline: exported_csv, content_type: request.format
              return
            elsif request.format == :js || request.path.start_with?('/api/') # Asking for JSON?
              data = (model.is_view? || !Object.const_defined?('DutyFree')) ? model.limit(1000) : model.df_export(model.brick_import_template)
              render inline: data.to_json, content_type: request.format == '*/*' ? 'application/json' : request.format
              return
            end

            # Normal (not swagger or CSV) request

            # %%% Allow params to define which columns to use for order_by
            # Overriding the default by providing a querystring param?
            ordering = params['_brick_order']&.split(',')&.map(&:to_sym) || Object.send(:default_ordering, table_name, pk)
            order_by, _ = model._brick_calculate_ordering(ordering, true) # Don't do the txt part

            ar_relation = ActiveRecord.version < Gem::Version.new('4') ? model.preload : model.all
            @_brick_params = ar_relation.brick_select(params, (selects ||= []), order_by,
                                                               translations = {},
                                                               join_array = ::Brick::JoinArray.new)
            # %%% Add custom HM count columns
            # %%% What happens when the PK is composite?
            counts = model._br_hm_counts.each_with_object([]) do |v, s|
              s << if is_mysql
                     "`b_r_#{v.first}`.c_t_ AS \"b_r_#{v.first}_ct\""
                   elsif is_postgres
                     "\"b_r_#{v.first}\".c_t_ AS \"b_r_#{v.first}_ct\""
                   else
                     "b_r_#{v.first}.c_t_ AS \"b_r_#{v.first}_ct\""
                   end
            end
            ar_select = ar_relation.respond_to?(:_select!) ? ar_relation.dup._select!(*selects, *counts) : ar_relation.select(selects + counts)
            instance_variable_set("@#{table_name.split('.').last}".to_sym, ar_select)
            table_name_no_schema = singular_table_name.pluralize
            if namespace && (idx = lookup_context.prefixes.index(table_name_no_schema))
              lookup_context.prefixes[idx] = "#{namespace.name.underscore}/#{lookup_context.prefixes[idx]}"
            end
            @_brick_excl = session[:_brick_exclude]&.split(',')&.each_with_object([]) do |excl, s|
                             if (excl_parts = excl.split('.')).first == table_name_no_schema
                               s << excl_parts.last
                             end
                           end
            @_brick_bt_descrip = model._br_bt_descrip
            @_brick_hm_counts = model._br_hm_counts
            @_brick_join_array = join_array
            @_brick_erd = params['_brick_erd']&.to_i
          end
        end

        unless is_openapi || is_avo
          # Skip showing Bullet gem optimisation messages
          if Object.const_defined?('Bullet') && Bullet.respond_to?(:enable?)
            around_action :skip_bullet
            def skip_bullet
              bullet_enabled = Bullet.enable?
              Bullet.enable = false
              yield
            ensure
              Bullet.enable = bullet_enabled
            end
          end

          _, order_by_txt = model._brick_calculate_ordering(default_ordering(table_name, pk)) if pk
          code << "  def index\n"
          code << "    @#{table_name.pluralize} = #{model.name}#{pk&.present? ? ".order(#{order_by_txt.join(', ')})" : '.all'}\n"
          code << "    @#{table_name.pluralize}.brick_select(params)\n"
          code << "  end\n"

          is_pk_string = nil
          if pk.present?
            code << "  def show\n"
            code << "    #{find_by_name = "find_#{singular_table_name}"}\n"
            code << "  end\n"
            self.define_method :show do
              _schema, @_is_show_schema_list = ::Brick.set_db_schema(params)
              instance_variable_set("@#{singular_table_name}".to_sym, find_obj)
            end
          end

          # By default, views get marked as read-only
          # unless model.readonly # (relation = relations[model.table_name]).key?(:isView)
          code << "  def new\n"
          code << "    @#{singular_table_name} = #{model.name}.new\n"
          code << "  end\n"
          self.define_method :new do
            _schema, @_is_show_schema_list = ::Brick.set_db_schema(params)
            instance_variable_set("@#{singular_table_name}".to_sym, model.new)
          end

          params_name_sym = (params_name = "#{singular_table_name}_params").to_sym

          code << "  def create\n"
          code << "    @#{singular_table_name} = #{model.name}.create(#{params_name})\n"
          code << "  end\n"
          self.define_method :create do
            ::Brick.set_db_schema(params)
            if (is_json = request.content_type == 'application/json') && (col = params['_brick_exclude'])
              session[:_brick_exclude] = ((session[:_brick_exclude]&.split(',') || []) + ["#{table_name}.#{col}"]).join(',')
              render json: { result: ::Brick.exclude_column(table_name, col) }
            elsif is_json && (col = params['_brick_unexclude'])
              if (excls = ((session[:_brick_exclude]&.split(',') || []) - ["#{table_name}.#{col}"]).join(',')).empty?
                session.delete(:_brick_exclude)
              else
                session[:_brick_exclude] = excls
              end
              render json: { result: ::Brick.unexclude_column(table_name, col) }
            else
              instance_variable_set("@#{singular_table_name}".to_sym,
                                    model.send(:create, send(params_name_sym)))
              index
              render :index
            end
          end

          if pk.present?
            # if (schema = ::Brick.config.schema_behavior[:multitenant]&.fetch(:schema_to_analyse, nil)) && ::Brick.db_schemas&.key?(schema)
            #   ActiveRecord::Base.execute_sql("SET SEARCH_PATH = ?;", schema)
            # end

            is_need_params = true
            code << "  def edit\n"
            code << "    #{find_by_name}\n"
            code << "  end\n"
            self.define_method :edit do
              _schema, @_is_show_schema_list = ::Brick.set_db_schema(params)
              instance_variable_set("@#{singular_table_name}".to_sym, find_obj)
            end

            code << "  def update\n"
            code << "    #{find_by_name}.update(#{params_name})\n"
            code << "  end\n"
            self.define_method :update do
              ::Brick.set_db_schema(params)
              if request.format == :csv # Importing CSV?
                require 'csv'
                # See if internally it's likely a TSV file (tab-separated)
                tab_counts = []
                5.times { tab_counts << request.body.readline.count("\t") unless request.body.eof? }
                request.body.rewind
                separator = "\t" if tab_counts.length > 0 && tab_counts.uniq.length == 1 && tab_counts.first > 0
                result = model.df_import(CSV.parse(request.body, { col_sep: separator || :auto }), model.brick_import_template)
                # render inline: exported_csv, content_type: request.format
                return
              # elsif request.format == :js # Asking for JSON?
              #   render inline: model.df_export(true).to_json, content_type: request.format
              #   return
              end

              instance_variable_set("@#{singular_table_name}".to_sym, (obj = find_obj))
              obj.send(:update, send(params_name_sym))
            end

            code << "  def destroy\n"
            code << "    #{find_by_name}.destroy\n"
            code << "  end\n"
            self.define_method :destroy do
              ::Brick.set_db_schema(params)
              if (obj = find_obj).send(:destroy)
                redirect_to send("#{model._brick_index}_path".to_sym)
              else
                redirect_to send("#{model._brick_index(:singular)}_path".to_sym, obj)
              end
            end
          end

          code << "private\n" if pk.present? || is_need_params

          if pk.present?
            code << "  def find_#{singular_table_name}
    id = params[:id]&.split(/[\\/,_]/)
    @#{singular_table_name} = #{model.name}.find(id.is_a?(Array) && id.length == 1 ? id.first : id)
  end\n"
            self.define_method :find_obj do
              id = if model.columns_hash[pk.first]&.type == :string
                     is_pk_string = true
                     params[:id].gsub('^^sl^^', '/')
                   else
                     params[:id]&.split(/[\/,_]/).map do |val_part|
                       val_part.gsub('^^sl^^', '/')
                     end
                   end
              # Support friendly_id gem
              if Object.const_defined?('FriendlyId') && model.instance_variable_get(:@friendly_id_config)
                model.friendly.find(id.is_a?(Array) && id.length == 1 ? id.first : id)
              else
                model.find(id.is_a?(Array) && id.length == 1 ? id.first : id)
              end
            end
          end

          if is_need_params
            code << "  def #{params_name}\n"
            permits = model.columns_hash.keys.map(&:to_sym)
            permits_txt = permits.map(&:inspect) +
                          model.reflect_on_all_associations.select { |assoc| assoc.macro == :has_many && assoc.options[:through] }.map do |assoc|
                            permits << { "#{assoc.name.to_s.singularize}_ids".to_sym => [] }
                            "#{assoc.name.to_s.singularize}_ids: []"
                          end
            code << "    params.require(:#{require_name = model.name.underscore.tr('/', '_')
                             }).permit(#{permits_txt.join(', ')})\n"
            code << "  end\n"
            self.define_method(params_name) do
              params.require(require_name.to_sym).permit(permits)
            end
            private params_name
            # Get column names for params from relations[model.table_name][:cols].keys
          end
        end # unless is_openapi
        code << "end # #{class_name}\n"
      end # class definition
      [built_controller, code]
    end

    def _brick_get_hm_assoc_name(relation, hm_assoc, source = nil)
      assoc_name, needs_class = if (relation[:hm_counts][hm_assoc[:inverse_table]]&.> 1) &&
                                   hm_assoc[:alternate_name] != (source || name.underscore)
                                  plural = "#{hm_assoc[:assoc_name]}_#{ActiveSupport::Inflector.pluralize(hm_assoc[:alternate_name])}"
                                  new_alt_name = (hm_assoc[:alternate_name] == name.underscore) ? "#{hm_assoc[:assoc_name].singularize}_#{plural}" : plural
                                  # %%% In rare cases might even need to add a number at the end for uniqueness
                                  # uniq = 1
                                  # while same_name = relation[:fks].find { |x| x.last[:assoc_name] == hm_assoc[:assoc_name] && x.last != hm_assoc }
                                  #   hm_assoc[:assoc_name] = "#{hm_assoc_name}_#{uniq += 1}"
                                  # end
                                  # puts new_alt_name
                                  hm_assoc[:alternate_chosen_name] = new_alt_name
                                  [new_alt_name, true]
                                else
                                  assoc_name = ::Brick.namify(hm_assoc[:inverse_table]).pluralize
                                  if (needs_class = assoc_name.include?('.')) # If there is a schema name present, use a downcased version for the :has_many
                                    assoc_parts = assoc_name.split('.')
                                    assoc_parts[0].downcase! if assoc_parts[0] =~ /^[A-Z0-9_]+$/
                                    assoc_name = assoc_parts.join('.')
                                  end
                                  # hm_assoc[:assoc_name] = assoc_name
                                  [assoc_name, needs_class]
                                end
      # Already have the HM class around?
      begin
        if (hm_class = Object._brick_const_missing(hm_class_name = relation[:class_name].to_sym))
          existing_hm_assocs = hm_class.reflect_on_all_associations.select do |assoc|
            assoc.macro != :belongs_to && assoc.klass == self && assoc.foreign_key == hm_assoc[:fk]
          end
          # Missing a has_many in an existing class?
          if existing_hm_assocs.empty?
            options = { inverse_of: hm_assoc[:inverse][:assoc_name].to_sym }
            # Add class_name and foreign_key where necessary
            unless hm_assoc[:alternate_name] == (source || name.underscore)
              options[:class_name] = self.name
              options[:foreign_key] = hm_assoc[:fk].to_sym
            end
            hm_class.send(:has_many, assoc_name.to_sym, options)
            puts "# ** Adding a missing has_many to #{hm_class.name}:\nclass #{hm_class.name} < #{hm_class.superclass.name}"
            puts "  has_many :#{assoc_name}, #{options.inspect}\nend\n"
          end
        end
      rescue NameError
      end
      [assoc_name, needs_class]
    end
  end
end

# ==========================================================
# Get info on all relations during first database connection
# ==========================================================

if ActiveRecord.const_defined?('ConnectionHandling')
  ActiveRecord::ConnectionHandling
else
  ActiveRecord::ConnectionAdapters::ConnectionHandler
end.class_exec do
  alias _brick_establish_connection establish_connection
  def establish_connection(*args)
    conn = _brick_establish_connection(*args)
    return conn unless ::Brick.config.mode == :on

    begin
      # Overwrite SQLite's #begin_db_transaction so it opens in IMMEDIATE mode instead of
      # the default DEFERRED mode.
      #   https://discuss.rubyonrails.org/t/failed-write-transaction-upgrades-in-sqlite3/81480/2
      if ActiveRecord::Base.connection.adapter_name == 'SQLite'
        arca = ::ActiveRecord::ConnectionAdapters
        db_statements = arca::SQLite3::DatabaseStatements
        # Rails 7.1 and later
        if arca::AbstractAdapter.private_instance_methods.include?(:with_raw_connection)
          db_statements.define_method(:begin_db_transaction) do
            log("begin immediate transaction", "TRANSACTION") do
              with_raw_connection(allow_retry: true, uses_transaction: false) do |conn|
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
      # ::Brick.is_db_present = true
      _brick_reflect_tables
    rescue ActiveRecord::NoDatabaseError
      # ::Brick.is_db_present = false
    end
    conn
  end

  # This is done separately so that during testing it can be called right after a migration
  # in order to make sure everything is good.
  def _brick_reflect_tables
    return unless ::Brick.config.mode == :on

    # return if ActiveRecord::Base.connection.current_database == 'postgres'

    initializer_loaded = false
    orig_schema = nil
    if (relations = ::Brick.relations).empty?
      # Very first thing, load inflections since we'll be using .pluralize and .singularize on table and model names
      if File.exist?(inflections = ::Rails.root.join('config/initializers/inflections.rb'))
        load inflections
      end
      # Now the Brick initializer since there may be important schema things configured
      if File.exist?(brick_initializer = ::Rails.root.join('config/initializers/brick.rb'))
        initializer_loaded = load brick_initializer
      end
      # Load the initializer for the Apartment gem a little early so that if .excluded_models and
      # .default_schema are specified then we can work with non-tenanted models more appropriately
      if (apartment = Object.const_defined?('Apartment')) &&
         File.exist?(apartment_initializer = ::Rails.root.join('config/initializers/apartment.rb'))
        unless @_apartment_loaded
          load apartment_initializer
          @_apartment_loaded = true
        end
        apartment_excluded = Apartment.excluded_models
      end
      # Only for Postgres  (Doesn't work in sqlite3 or MySQL)
      # puts ActiveRecord::Base.execute_sql("SELECT current_setting('SEARCH_PATH')").to_a.inspect

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
        if (possible_schemas = (multitenancy = ::Brick.config.schema_behavior&.[](:multitenant)) &&
                               multitenancy&.[](:schema_to_analyse))
          possible_schemas = [possible_schemas] unless possible_schemas.is_a?(Array)
          if (possible_schema = possible_schemas.find { |ps| ::Brick.db_schemas.key?(ps) })
            ::Brick.default_schema = ::Brick.apartment_default_tenant
            schema = possible_schema
            orig_schema = ActiveRecord::Base.execute_sql('SELECT current_schemas(true)').first['current_schemas'][1..-2].split(',')
            ActiveRecord::Base.execute_sql("SET SEARCH_PATH = ?", schema)
          elsif Rails.env == 'test' # When testing, just find the most recently-created schema
            ::Brick.default_schema = schema = ::Brick.db_schemas.to_a.sort { |a, b| b.last[:dt] <=> a.last[:dt] }.first.first
            puts "While running tests, had noticed in the brick.rb initializer that the line \"::Brick.schema_behavior = ...\" refers to a schema called \"#{possible_schema}\" which does not exist.  Reading table structure from the most recently-created schema, #{schema}."
            orig_schema = ActiveRecord::Base.execute_sql('SELECT current_schemas(true)').first['current_schemas'][1..-2].split(',')
            ActiveRecord::Base.execute_sql("SET SEARCH_PATH = ?", schema)
          else
            puts "*** In the brick.rb initializer the line \"::Brick.schema_behavior = ...\" refers to schema(s) called #{possible_schemas.map { |s| "\"#{s}\"" }.join(', ')}.  No mentioned schema exists. ***"
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
                          ::Brick.apartment_default_tenant if apartment_excluded&.include?(r['relation_name'].singularize.camelize)
                        elsif ![schema, 'public'].include?(r['schema'])
                          r['schema']
                        end
          relation_name = schema_name ? "#{schema_name}.#{r['relation_name']}" : r['relation_name']
          # Both uppers and lowers as well as underscores?
          apply_double_underscore_patch if relation_name =~ /[A-Z]/ && relation_name =~ /[a-z]/ && relation_name.index('_')
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
                end
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
            apply_double_underscore_patch
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
      case ActiveRecord::Base.connection.adapter_name
      when 'PostgreSQL', 'Mysql2', 'Trilogy', 'SQLServer'
        sql = "SELECT kcu1.CONSTRAINT_SCHEMA, kcu1.TABLE_NAME, kcu1.COLUMN_NAME,
            kcu2.CONSTRAINT_SCHEMA AS primary_schema, kcu2.TABLE_NAME AS primary_table, kcu1.CONSTRAINT_NAME AS CONSTRAINT_SCHEMA_FK
          FROM INFORMATION_SCHEMA.REFERENTIAL_CONSTRAINTS AS rc
            INNER JOIN INFORMATION_SCHEMA.KEY_COLUMN_USAGE AS kcu1
              ON kcu1.CONSTRAINT_CATALOG = rc.CONSTRAINT_CATALOG
              AND kcu1.CONSTRAINT_SCHEMA = rc.CONSTRAINT_SCHEMA
              AND kcu1.CONSTRAINT_NAME = rc.CONSTRAINT_NAME
            INNER JOIN INFORMATION_SCHEMA.KEY_COLUMN_USAGE AS kcu2
              ON kcu2.CONSTRAINT_CATALOG = rc.UNIQUE_CONSTRAINT_CATALOG
              AND kcu2.CONSTRAINT_SCHEMA = rc.UNIQUE_CONSTRAINT_SCHEMA
              AND kcu2.CONSTRAINT_NAME = rc.UNIQUE_CONSTRAINT_NAME#{"
              AND kcu2.TABLE_NAME = kcu1.REFERENCED_TABLE_NAME
              AND kcu2.COLUMN_NAME = kcu1.REFERENCED_COLUMN_NAME" unless is_postgres || is_mssql }
              AND kcu2.ORDINAL_POSITION = kcu1.ORDINAL_POSITION#{"
          WHERE kcu1.CONSTRAINT_SCHEMA = COALESCE(current_setting('SEARCH_PATH'), 'public')" if is_postgres && schema }"
          # AND kcu2.TABLE_NAME = ?;", Apartment::Tenant.current, table_name
        fk_references = ActiveRecord::Base.execute_sql(sql)
      when 'SQLite'
        sql = "SELECT m.name, fkl.\"from\", fkl.\"table\", m.name || '_' || fkl.\"from\" AS constraint_name
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
      ::Brick.default_schema ||= 'public' if ActiveRecord::Base.connection.adapter_name == 'PostgreSQL'
      fk_references&.each do |fk|
        fk = fk.values unless fk.is_a?(Array)
        # Multitenancy makes things a little more general overall, except for non-tenanted tables
        if apartment_excluded&.include?(::Brick.namify(fk[1]).singularize.camelize)
          fk[0] = ::Brick.apartment_default_tenant
        elsif (is_postgres && (fk[0] == 'public' || (multitenancy && fk[0] == schema))) ||
              (::Brick.is_oracle && fk[0] == schema) ||
              (is_mssql && fk[0] == 'dbo') ||
              (!is_postgres && !::Brick.is_oracle && !is_mssql && ['mysql', 'performance_schema', 'sys'].exclude?(fk[0]))
          fk[0] = nil
        end
        if apartment_excluded&.include?(fk[4].singularize.camelize)
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
        ::Brick._add_bt_and_hm(fk, relations)
      end
    end

    relations.each do |k, v|
      rel_name = k.split('.').map { |rel_part| ::Brick.namify(rel_part, :underscore) }
      schema_names = rel_name[0..-2]
      schema_names.shift if ::Brick.apartment_multitenant && schema_names.first == ::Brick.apartment_default_tenant
      v[:schema] = schema_names.join('.') unless schema_names.empty?
      # %%% If more than one schema has the same table name, will need to add a schema name prefix to have uniqueness
      v[:resource] = rel_name.last
      if (singular = rel_name.last.singularize).blank?
        singular = rel_name.last
      end
      v[:class_name] = (schema_names + [singular]).map(&:camelize).join('::')
    end
    ::Brick.load_additional_references if initializer_loaded

    if orig_schema && (orig_schema = (orig_schema - ['pg_catalog', 'pg_toast', 'heroku_ext']).first)
      puts "Now switching back to \"#{orig_schema}\" schema."
      ActiveRecord::Base.execute_sql("SET SEARCH_PATH = ?", orig_schema)
    end
  end

  def retrieve_schema_and_tables(sql = nil, is_postgres = nil, is_mssql = nil, schema = nil)
    is_mssql = ActiveRecord::Base.connection.adapter_name == 'SQLServer' if is_mssql.nil?
    sql ||= "SELECT t.table_schema AS \"schema\", t.table_name AS relation_name, t.table_type,#{"
      pg_catalog.obj_description(
        ('\"' || t.table_schema || '\".\"' || t.table_name || '\"')::regclass::oid, 'pg_class'
      ) AS table_description,
      pg_catalog.col_description(
        ('\"' || t.table_schema || '\".\"' || t.table_name || '\"')::regclass::oid, c.ordinal_position
      ) AS column_description," if is_postgres}
      c.column_name, c.data_type,
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
    --    AND kcu.position_in_unique_constraint IS NULL" unless is_mssql}
    WHERE t.table_schema #{is_postgres || is_mssql ?
        "NOT IN ('information_schema', 'pg_catalog', 'pg_toast', 'heroku_ext',
                 'INFORMATION_SCHEMA', 'sys')"
        :
        "= '#{ActiveRecord::Base.connection.current_database.tr("'", "''")}'"}#{"
      AND t.table_schema = COALESCE(current_setting('SEARCH_PATH'), 'public')" if is_postgres && schema }
  --          AND t.table_type IN ('VIEW') -- 'BASE TABLE', 'FOREIGN TABLE'
      AND t.table_name NOT IN ('pg_stat_statements', ?, ?)
    ORDER BY 1, t.table_type DESC, 2, kcu.ordinal_position"
    ActiveRecord::Base.execute_sql(sql, *ar_tables)
  end

  def ar_tables
    ar_smtn = if ActiveRecord::Base.respond_to?(:schema_migrations_table_name)
                ActiveRecord::Base.schema_migrations_table_name
              else
                'schema_migrations'
              end
    ar_imtn = ActiveRecord.version >= ::Gem::Version.new('5.0') ? ActiveRecord::Base.internal_metadata_table_name : 'ar_internal_metadata'
    [ar_smtn, ar_imtn]
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
          camel_cased_word.to_s.gsub("::", "/").split('_').map do |word|
            word.gsub!(inflections.acronyms_underscore_regex) { "#{$1 && '_' }#{$2.downcase}" }
            word.gsub!(/([A-Z]+)(?=[A-Z][a-z])|([a-z\d])(?=[A-Z])/) { ($1 || $2) << "_" }
            word.tr!("-", "_")
            word.downcase!
            word
          end.join('__')
        end
      end
      @double_underscore_applied = true
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
    def _add_bt_and_hm(fk, relations, is_polymorphic = false, is_optional = false)
      bt_assoc_name = ::Brick.namify(fk[2], :downcase)
      unless is_polymorphic
        bt_assoc_name = if bt_assoc_name.underscore.end_with?('_id')
                          bt_assoc_name[-3] == '_' ? bt_assoc_name[0..-4] : bt_assoc_name[0..-3]
                        elsif bt_assoc_name.downcase.end_with?('id') && bt_assoc_name.exclude?('_')
                          bt_assoc_name[0..-3] # Make the bold assumption that we can just peel off any final ID part
                        else
                          "#{bt_assoc_name}_bt"
                        end
      end
      bt_assoc_name = "#{bt_assoc_name}_" if bt_assoc_name == 'attribute'

      # %%% Temporary schema patch
      for_tbl = fk[1]
      fk_namified = ::Brick.namify(fk[1])
      apartment = Object.const_defined?('Apartment') && Apartment
      fk[0] = ::Brick.apartment_default_tenant if apartment && apartment.excluded_models.include?(fk_namified.singularize.camelize)
      fk[1] = "#{fk[0]}.#{fk[1]}" if fk[0] # && fk[0] != ::Brick.default_schema
      bts = (relation = relations.fetch(fk[1], nil))&.fetch(:fks) { relation[:fks] = {} }

      # %%% Do we miss out on has_many :through or even HM based on constantizing this model early?
      # Maybe it's already gotten this info because we got as far as to say there was a unique class
      primary_table = if (is_class = fk[4].is_a?(Hash) && fk[4].key?(:class))
                        pri_tbl = (primary_class = fk[4][:class].constantize).table_name
                        if (pri_tbl_parts = pri_tbl.split('.')).length > 1
                          fk[3] = pri_tbl_parts.first
                        end
                      else
                        is_schema = if ::Brick.config.schema_behavior[:multitenant]
                                      # If Apartment gem lists the primary table as being associated with a non-tenanted model
                                      # then use 'public' schema for the primary table
                                      if apartment && apartment&.excluded_models.include?(fk[4].singularize.camelize)
                                        fk[3] = ::Brick.apartment_default_tenant
                                        true
                                      end
                                    else
                                      fk[3] && fk[3] != ::Brick.default_schema && fk[3] != 'public'
                                    end
                        pri_tbl = fk[4]
                        is_schema ? "#{fk[3]}.#{pri_tbl}" : pri_tbl
                      end
      hms = (relation = relations.fetch(primary_table, nil))&.fetch(:fks) { relation[:fks] = {} } unless is_class

      unless (cnstr_name = fk[5])
        # For any appended references (those that come from config), arrive upon a definitely unique constraint name
        pri_tbl = is_class ? fk[4][:class].underscore : pri_tbl
        pri_tbl = "#{bt_assoc_name}_#{pri_tbl}" if pri_tbl&.singularize != bt_assoc_name
        cnstr_name = ensure_unique(+"(brick) #{for_tbl}_#{pri_tbl}", bts, hms)
        missing = []
        missing << fk[1] unless relations.key?(fk[1])
        missing << primary_table unless is_class || relations.key?(primary_table)
        unless missing.empty?
          tables = relations.reject { |_k, v| v.fetch(:isView, nil) }.keys.sort
          puts "Brick: Additional reference #{fk.inspect} refers to non-existent #{'table'.pluralize(missing.length)} #{missing.join(' and ')}. (Available tables include #{tables.join(', ')}.)"
          return
        end
        unless (cols = relations[fk[1]][:cols]).key?(fk[2]) || (is_polymorphic && cols.key?("#{fk[2]}_id") && cols.key?("#{fk[2]}_type"))
          columns = cols.map { |k, v| "#{k} (#{v.first.split(' ').first})" }
          puts "Brick: Additional reference #{fk.inspect} refers to non-existent column #{fk[2]}. (Columns present in #{fk[1]} are #{columns.join(', ')}.)"
          return
        end
        if (redundant = bts.find { |_k, v| v[:inverse]&.fetch(:inverse_table, nil) == fk[1] && v[:fk] == fk[2] && v[:inverse_table] == primary_table })
          if is_class && !redundant.last.key?(:class)
            redundant.last[:primary_class] = primary_class # Round out this BT so it can find the proper :source for a HMT association that references an STI subclass
          else
            puts "Brick: Additional reference #{fk.inspect} is redundant and can be removed.  (Already established by #{redundant.first}.)"
          end
          return
        end
      end
      return unless bts # Rails 5.0 and older can have bts end up being nil

      if (assoc_bt = bts[cnstr_name])
        if is_polymorphic
          # Assuming same fk (don't yet support composite keys for polymorphics)
          assoc_bt[:inverse_table] << fk[4]
        else # Expect we could have a composite key going
          if assoc_bt[:fk].is_a?(String)
            assoc_bt[:fk] = [assoc_bt[:fk], fk[2]] unless fk[2] == assoc_bt[:fk]
          elsif assoc_bt[:fk].exclude?(fk[2])
            assoc_bt[:fk] << fk[2]
          end
          assoc_bt[:assoc_name] = "#{assoc_bt[:assoc_name]}_#{fk[2]}"
        end
      else
        inverse_table = [primary_table] if is_polymorphic
        assoc_bt = bts[cnstr_name] = { is_bt: true, fk: fk[2], assoc_name: bt_assoc_name, inverse_table: inverse_table || primary_table }
        assoc_bt[:optional] = true if is_optional
        assoc_bt[:polymorphic] = true if is_polymorphic
      end
      if is_class
        # For use in finding the proper :source for a HMT association that references an STI subclass
        assoc_bt[:primary_class] = primary_class
        # For use in finding the proper :inverse_of for a BT association that references an STI subclass
        # assoc_bt[:inverse_of] = primary_class.reflect_on_all_associations.find { |a| a.foreign_key == bt[1] }
      end

      return if is_class || ::Brick.config.exclude_hms&.any? { |exclusion| fk[1] == exclusion[0] && fk[2] == exclusion[1] && primary_table == exclusion[2] } || hms.nil?

      if (assoc_hm = hms.fetch((hm_cnstr_name = "hm_#{cnstr_name}"), nil))
        if assoc_hm[:fk].is_a?(String)
          assoc_hm[:fk] = [assoc_hm[:fk], fk[2]] unless fk[2] == assoc_hm[:fk]
        elsif assoc_hm[:fk].exclude?(fk[2])
          assoc_hm[:fk] << fk[2]
        end
        assoc_hm[:alternate_name] = "#{assoc_hm[:alternate_name]}_#{bt_assoc_name}" unless assoc_hm[:alternate_name] == bt_assoc_name
      else
        inv_tbl = if ::Brick.config.schema_behavior[:multitenant] && apartment && fk[0] == ::Brick.apartment_default_tenant
                    for_tbl
                  else
                    fk[1]
                  end
        assoc_hm = hms[hm_cnstr_name] = { is_bt: false, fk: fk[2], assoc_name: fk_namified.pluralize, alternate_name: bt_assoc_name,
                                          inverse_table: inv_tbl, inverse: assoc_bt }
        assoc_hm[:polymorphic] = true if is_polymorphic
        hm_counts = relation.fetch(:hm_counts) { relation[:hm_counts] = {} }
        this_hm_count = hm_counts[fk[1]] = hm_counts.fetch(fk[1]) { 0 } + 1
      end
      assoc_bt[:inverse] = assoc_hm
    end

    # Identify built out routes, migrations, models,
    # (and also soon controllers and views!)
    # for each resource
    def get_status_of_resources
      rails_root = ::Rails.root.to_s
      migrations = if Dir.exist?(mig_path = ActiveRecord::Migrator.migrations_paths.first || "#{rails_root}/db/migrate")
                     Dir["#{mig_path}/**/*.rb"].each_with_object(Hash.new { |h, k| h[k] = [] }) do |v, s|
                       File.read(v).split("\n").each_with_index do |line, line_idx|
                         # For all non-commented lines, look for any that have "create_table", "alter_table", or "drop_table"
                         if !line.lstrip.start_with?('#') &&
                            (idx = (line.index('create_table ') || line.index('create_table('))&.+(13)) ||
                            (idx = (line.index('alter_table ') || line.index('alter_table('))&.+(12)) ||
                            (idx = (line.index('drop_table ') || line.index('drop_table('))&.+(11))
                           tbl = line[idx..-1].match(/([:'"\w\.]+)/)&.captures&.first
                           if tbl
                             v = v[(rails_root.length)..-1] if v.start_with?(rails_root)
                             v = v[1..-1] if v.start_with?('/')
                             s[tbl.tr(':\'"', '').pluralize] << [v, line_idx + 1]
                           end
                         end
                       end
                     end
                   end
      abstract_activerecord_bases = ::Brick.eager_load_classes(true)
      models = if Dir.exist?(model_path = "#{rails_root}/app/models")
                 Dir["#{model_path}/**/*.rb"].each_with_object({}) do |v, s|
                   File.read(v).split("\n").each do |line|
                     # For all non-commented lines, look for any that start with "class " and also "< ApplicationRecord"
                     if line.lstrip.start_with?('class') && (idx = line.index('class'))
                       model = line[idx + 5..-1].match(/[\s:]+([\w:]+)/)&.captures&.first
                       if model && abstract_activerecord_bases.exclude?(model)
                         klass = begin
                                   model.constantize
                                 rescue
                                 end
                         s[model.underscore.tr('/', '.').pluralize] = [
                           v.start_with?(rails_root) ? v[rails_root.length + 1..-1] : v,
                           klass
                         ]
                       end
                     end
                   end
                 end
               end
      ::Brick.relations.keys.map do |v|
        tbl_parts = v.split('.')
        tbl_parts.shift if ::Brick.apartment_multitenant && tbl_parts.length > 1 && tbl_parts.first == ::Brick.apartment_default_tenant
        res = tbl_parts.join('.')
        [v, (model = models[res])&.last&.table_name, migrations&.fetch(res, nil), model&.first]
      end
    end

    def ensure_unique(name, *sources)
      base = name
      if (added_num = name.slice!(/_(\d+)$/))
        added_num = added_num[1..-1].to_i
      else
        added_num = 1
      end
      while (
        name = "#{base}_#{added_num += 1}"
        sources.each_with_object(nil) do |v, s|
          s || case v
               when Hash
                 v.key?(name)
               when Array
                 v.include?(name)
               end
        end
      )
      end
      name
    end

    # Locate orphaned records
    def find_orphans(multi_schema)
      is_default_schema = multi_schema&.==(::Brick.apartment_default_tenant)
      relations.each_with_object([]) do |v, s|
        frn_tbl = v.first
        next if (relation = v.last).key?(:isView) || config.exclude_tables.include?(frn_tbl) ||
                !(for_pk = (relation[:pkey].values.first&.first))

        is_default_frn_schema = !is_default_schema && multi_schema &&
                                ((frn_parts = frn_tbl.split('.')).length > 1 && frn_parts.first)&.==(::Brick.apartment_default_tenant)
        relation[:fks].select { |_k, assoc| assoc[:is_bt] }.each do |_k, bt|
          begin
            if bt.key?(:polymorphic)
              pri_pk = for_pk
              pri_tables = Brick.config.polymorphics["#{frn_tbl}.#{bt[:fk]}"]
                                .each_with_object(Hash.new { |h, k| h[k] = [] }) do |pri_class, s|
                s[Object.const_get(pri_class).table_name] << pri_class
              end
              fk_id_col = "#{bt[:fk]}_id"
              fk_type_col = "#{bt[:fk]}_type"
              selects = []
              pri_tables.each do |pri_tbl, pri_types|
                # Skip if database is multitenant, we're not focused on "public", and the foreign and primary tables
                # are both in the "public" schema
                next if is_default_frn_schema &&
                        ((pri_parts = pri_tbl&.split('.'))&.length > 1 && pri_parts.first)&.==(::Brick.apartment_default_tenant)

                selects << "SELECT '#{pri_tbl}' AS pri_tbl, frn.#{fk_type_col} AS pri_type, frn.#{fk_id_col} AS pri_id, frn.#{for_pk} AS frn_id
                FROM #{frn_tbl} AS frn
                  LEFT OUTER JOIN #{pri_tbl} AS pri ON pri.#{pri_pk} = frn.#{fk_id_col}
                WHERE frn.#{fk_type_col} IN (#{
                  pri_types.map { |pri_type| "'#{pri_type}'" }.join(', ')
                }) AND frn.#{bt[:fk]}_id IS NOT NULL AND pri.#{pri_pk} IS NULL\n"
              end
              ActiveRecord::Base.execute_sql(selects.join("UNION ALL\n")).each do |o|
                entry = [frn_tbl, o['frn_id'], o['pri_type'], o['pri_id'], fk_id_col]
                entry << o['pri_tbl'] if (pri_class = Object.const_get(o['pri_type'])) != pri_class.base_class
                s << entry
              end
            else
              # Skip if database is multitenant, we're not focused on "public", and the foreign and primary tables
              # are both in the "public" schema
              pri_tbl = bt.key?(:inverse_table) && bt[:inverse_table]
              next if is_default_frn_schema &&
                      ((pri_parts = pri_tbl&.split('.'))&.length > 1 && pri_parts.first)&.==(::Brick.apartment_default_tenant)

              pri_pk = relations[pri_tbl].fetch(:pkey, nil)&.values&.first&.first ||
                       _class_pk(pri_tbl, multi_schema)
              ActiveRecord::Base.execute_sql(
                "SELECT frn.#{bt[:fk]} AS pri_id, frn.#{for_pk} AS frn_id
                FROM #{frn_tbl} AS frn
                  LEFT OUTER JOIN #{pri_tbl} AS pri ON pri.#{pri_pk} = frn.#{bt[:fk]}
                WHERE frn.#{bt[:fk]} IS NOT NULL AND pri.#{pri_pk} IS NULL
                ORDER BY 1, 2"
              ).each { |o| s << [frn_tbl, o['frn_id'], pri_tbl, o['pri_id'], bt[:fk]] }
            end
          rescue StandardError => err
            puts "Strange -- #{err.inspect}"
          end
        end
      end
    end

    def _class_pk(dotted_name, multitenant)
      Object.const_get((multitenant ? [dotted_name.split('.').last] : dotted_name.split('.')).map { |nm| "::#{nm.singularize.camelize}" }.join).primary_key
    end
  end
end
