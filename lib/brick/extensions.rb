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

# Modal pop-up things for editing large text / date ranges / hierarchies of data

# For recognised self-references, have the show page display all related objects up to the parent (or the start of a circular reference)

# When creating or updating an object through an auto-generated controller, it always goes to an auto-generated view template even if the user has supplied their own index.html.erb (or similar) view template

# Upon creation of a new object, when going to the index page, highlight this new object and scroll it into view (likely to the very bottom of everything, although might be sorted differently)

# ==========================================================
# Dynamically create model or controller classes when needed
# ==========================================================

module ActiveRecord
  class Base
    @_brick_inheriteds = {}
    class << self
      attr_reader :_brick_relation

      def _brick_inheriteds
        @_brick_inheriteds ||= ::ActiveRecord::Base.instance_variable_get(:@_brick_inheriteds)
      end

      # Track the file(s) in which each model is defined
      def inherited(model)
        (_brick_inheriteds[model] ||= []) << caller.first.split(':')[0..1] unless caller.first.include?('/lib/brick/extensions.rb:')
        super
      end

      def is_brick?
        instance_variables.include?(:@_brick_relation) && instance_variable_get(:@_brick_relation)
      end

      def _assoc_names
        @_assoc_names ||= {}
      end

      def is_view?
        false
      end

      def real_model(params)
        if params && ((sub_name = params.fetch(inheritance_column, nil)).present? ||
                      (sub_name = params[name.underscore]&.fetch(inheritance_column, nil)))
          sub_name = sub_name.first if sub_name.is_a?(Array) # Support the params style that gets returned from #_brick_querying
          # Make sure the chosen model is really the same or a subclass of this model
          return self if sub_name.blank?

          (possible_model = sub_name.constantize) <= self ? possible_model : self
        else
          self
        end
      end

      # Accommodate STI
      def real_singular(params)
        real_model = real_model(params)
        [real_model, real_model.name.underscore.split('/').last]
      end

      def json_column?(col)
        col.type == :json || ::Brick.config.json_columns[table_name]&.include?(col.name) ||
        (
          respond_to?(:attribute_types) && (attr_types = attribute_types[col.name]).respond_to?(:coder) &&
          (attr_types.coder.is_a?(Class) ? attr_types.coder : attr_types.coder&.class)&.name&.end_with?('JSON')
        )
      end

      def brick_foreign_type(assoc)
        reflect_on_association(assoc).foreign_type || "#{assoc}_type"
      end

      def _brick_all_fields(skip_id = nil)
        col_names = columns_hash.keys
        # If it's a composite primary key then allow all the values through
        # TODO: Should disallow any autoincrement / SERIAL columns
        if skip_id && (pk_as_array = _pk_as_array).length == 1
          col_names -= _pk_as_array
        end
        hoa, hma, rtans = _activestorage_actiontext_fields
        col_names.map(&:to_sym) + hoa + hma.map { |as| { as => [] } } + rtans.values
      end

      # Return three lists of fields for this model --
      # has_one_attached, has_many_attached, and has_rich_text
      def _activestorage_actiontext_fields
        fields = [[], [], {}]
        if Object.const_defined?('ActiveStorage') && respond_to?(:generated_association_methods) && !(self <= ::ActiveStorage::Blob) # ActiveStorage
          generated_association_methods.instance_methods.each do |method_sym|
            method_str = method_sym.to_s
            fields[0] << method_str[0..-13].to_sym if method_str.end_with?('_attachment=') # has_one_attached
            fields[1] << method_str[0..-14].to_sym if method_str.end_with?('_attachments=') # has_many_attached
          end
        end
        if respond_to?(:rich_text_association_names) # ActionText
          rich_text_association_names&.each do |rtan| # has_rich_text
            rtan_str = rtan.to_s
            fields[2][rtan] = rtan_str.start_with?('rich_text_') ? rtan_str[10..-1].to_sym : rtan
          end
        end
        fields
      end

      def _active_storage_name(col_name)
        if Object.const_defined?('ActiveStorage') && (self <= ::ActiveStorage::Attachment || self <= ::ActiveStorage::Blob)
          if (col_str = col_name.to_s).end_with?('_attachments')
            col_str[0..-13]
          elsif col_str.end_with?('_blobs')
            col_str[0..-7]
          end
        end
      end

      def _pk_as_array
        self.primary_key.is_a?(Array) ? self.primary_key : [self.primary_key]
      end

      def _br_quoted_name(name)
        name = name.join('.') if name.is_a?(Array)
        if name == '*'
          name
        elsif is_mysql
          "`#{name.gsub('.', '`.`')}`"
        elsif is_postgres || is_mssql
          "\"#{name.gsub('.', '"."')}\""
        else
          name
        end
      end

      def is_postgres
        @is_postgres ||= connection.adapter_name == 'PostgreSQL'
      end
      def is_mysql
        @is_mysql ||= ['Mysql2', 'Trilogy'].include?(connection.adapter_name)
      end
      def is_mssql
        @is_mssql ||= connection.adapter_name == 'SQLServer'
      end

      def _brick_primary_key(relation = nil)
        return @_brick_primary_key if instance_variable_defined?(:@_brick_primary_key)

        pk = begin
               primary_key
             rescue
               superclass.respond_to?(:primary_key) && superclass.primary_key
             end
        pk = pk.is_a?(String) ? [pk] : pk.dup || []
        pk.map! { |pk_part| pk_part =~ /^[A-Z0-9_]+$/ ? pk_part.downcase : pk_part } unless connection.adapter_name == 'MySQL2'
        # Just return [] if we're missing any part of the primary key.  (PK is usually just "id")
        if relation && pk.present?
          @_brick_primary_key ||= pk.any? { |pk_part| !relation[:cols].key?(pk_part) } ? [] : pk
        else # No definitive key yet, so return what we can without setting the instance variable
          pk
        end
      end

      # Used to show a little prettier name for an object
      def brick_get_dsl
        # If there's no DSL yet specified, just try to find the first usable column on this model
        unless (dsl = ::Brick.config.model_descrips[name])
          skip_columns = _brick_get_fks + (::Brick.config.metadata_columns || []) + [primary_key]
          dsl = if (descrip_col = columns.find { |c| [:boolean, :binary, :xml].exclude?(c.type) && skip_columns.exclude?(c.name) })
                  "[#{descrip_col.name}]"
                else
                  "#{name} ##{_pk_as_array.map { |pk_part| "[#{pk_part}]" }.join(', ')}"
                end
          ::Brick.config.model_descrips[name] = dsl
        end
        dsl
      end

      def _brick_monetized_attributes
        @_brick_monetized_attributes ||= respond_to?(:monetized_attributes) ? monetized_attributes.values : {}
      end
    end

    def self.brick_parse_dsl(join_array = nil, prefix = [], translations = {}, is_polymorphic = false, dsl = nil, emit_dsl = false)
      unless join_array.is_a?(::Brick::JoinArray)
        join_array = ::Brick::JoinArray.new.tap { |ary| ary.replace([join_array]) } if join_array.is_a?(::Brick::JoinHash)
        join_array = ::Brick::JoinArray.new unless join_array.nil? || join_array.is_a?(Array)
      end
      prefix = [prefix] unless prefix.is_a?(Array)
      members = []
      unless dsl || (dsl = ::Brick.config.model_descrips[name] || brick_get_dsl)
        # With no DSL available, still put this prefix into the JoinArray so we can get primary key (ID) info from this table
        x = prefix.each_with_object(join_array) { |v, s| s[v.to_sym] }
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
                join_array.add_parts(parts) unless is_polymorphic
                translations[parts[0..-2].join('.')] = klass
              end
              if klass&.column_names.exclude?(parts.last) &&
                 (klass = (orig_class = klass).reflect_on_association(possible_dsl = parts.last&.to_sym)&.klass)
                parts.pop
                if prefix.empty? # Custom columns start with an empty prefix
                  prefix << parts.shift until parts.empty?
                end
                # Expand this entry which refers to an association name
                members2, dsl2a = klass.brick_parse_dsl(join_array, prefix + [possible_dsl], translations, is_polymorphic, nil, true)
                members += members2
                dsl2 << dsl2a
                dsl3 << dsl2a
              else
                dsl2 << "[#{bracket_name}]"
                if emit_dsl
                  dsl3 << "[#{prefix[1..-1].map { |p| "#{p.to_s}." }.join if prefix.length > 1}#{bracket_name}]"
                end
                parts[-1] = column_names.first if parts[-1].nil? # No primary key to be found?  Grab something to display!
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
                                       if (possible = this_obj.class.reflect_on_all_associations.select { |a| !a.polymorphic? && (a.class_name == clsnm || a.klass.base_class.name == clsnm) }.first)
                                         caches[obj_name] = this_obj&.send(possible.name)
                                       end
                                     end
                          break if this_obj.nil?
                        end
                        if this_obj.is_a?(ActiveRecord::Base) && (obj_descrip = this_obj.class.brick_descrip(this_obj))
                          this_obj = obj_descrip
                        end
                        if Object.const_defined?('ActiveStorage') && this_obj.is_a?(::ActiveStorage::Filename) &&
                           this_obj.instance_variable_get(:@filename).nil?
                          this_obj.instance_variable_set(:@filename, '')
                        end
                        this_obj&.to_s || ''
                      end
              begin
                is_brackets_have_content = true unless datum.blank?
              rescue
              end
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
      model_path = ::Rails.application.routes.url_helpers.send("#{_brick_index || table_name}_path".to_sym)
      model_path << "?#{self.inheritance_column}=#{self.name}" if self != base_class
      av_class = Class.new.extend(ActionView::Helpers::UrlHelper)
      av_class.extend(ActionView::Helpers::TagHelper) if ActionView.version < ::Gem::Version.new('7')
      link = av_class.link_to(assoc_html_name ? name : assoc_name, model_path)
      assoc_html_name ? "#{assoc_name}-#{link}".html_safe : link
    end

    # Providing a relation object allows auto-modules built from table name prefixes to work
    def self._brick_index(mode = nil, separator = nil, relation = nil, not_path = nil)
      return if abstract_class?

      ::Brick._brick_index(table_name, mode, separator, relation, not_path)
    end

    def self.brick_import_template
      template = constants.include?(:IMPORT_TEMPLATE) ? self::IMPORT_TEMPLATE : suggest_template(0, false, true)
      # Add the primary key to the template as being unique (unless it's already there)
      if primary_key
        template[:uniques] = [pk = primary_key.to_sym]
        template[:all].unshift(pk) unless template[:all].include?(pk)
      end
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

      def _brick_find_permits(model_or_assoc, current_permits, done_permits = [])
        unless done_permits.include?(model_or_assoc)
          done_permits << model_or_assoc
          self.reflect_on_all_associations.select { |assoc| !assoc.belongs_to? }.each_with_object([]) do |assoc, s|
            if assoc.options[:through]
              current_permits << { "#{assoc.name.to_s.singularize}_ids".to_sym => [] }
              s << "#{assoc.name.to_s.singularize}_ids: []"
            end
            if self.instance_methods.include?(:"#{assoc.name}_attributes=")
              # Support nested attributes which use the friendly_id gem
              assoc.klass._brick_nested_friendly_id if Object.const_defined?('FriendlyId') &&
                                                       assoc.klass.instance_variable_get(:@friendly_id_config)
              new_attrib_text = assoc.klass._brick_find_permits(assoc, (new_permits = assoc.klass._brick_all_fields), done_permits)
              new_permits << :_destroy
              current_permits << { "#{assoc.name}_attributes".to_sym => new_permits }
              s << "#{assoc.name}_attributes: #{new_attrib_text}"
            end
          end
        end
        current_permits
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
      bts, hms, associatives = ::Brick.get_bts_and_hms(self, true)
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
      order_by_txt = [] if is_do_txt
      ordering = [ordering] if ordering && !ordering.is_a?(Array)
      order_by = ordering&.each_with_object([]) do |ord_part, s| # %%% If a term is also used as an eqi-condition in the WHERE clause, it can be omitted from ORDER BY
                   case ord_part
                   when String
                     ord_expr = if ord_part.index('(') # Any kind of SQL function at play here?
                                  ord_part.gsub('^^^', _br_quoted_name(table_name))
                                else
                                  _br_quoted_name(ord_part.gsub('^^^', table_name))
                                end
                     s << Arel.sql(ord_expr)
                     order_by_txt&.<<(ord_expr.index('.') ? "Arel.sql(#{ord_expr.inspect})" : ord_part.inspect)
                   else # Expecting only Symbol
                     ord_part = ord_part.to_s
                     if ord_part[0] == '-' # First char '-' means descending order
                       ord_part.slice!(0)
                       is_desc = true
                     end
                     if ord_part[0] == '~' # Char '~' means order NULLs as highest values instead of lowest
                       ord_part.slice!(0)
                       # (Unfortunately SQLServer does not support NULLS FIRST / NULLS LAST, so leave them out.)
                       is_nulls_switch = if is_mysql
                                           :mysql
                                         else # PostgreSQL, OracleEnhanced, SQLite
                                           :pg
                                         end
                     end
                     if _br_hm_counts.key?(ord_part_sym = ord_part.to_sym)
                       ord_part = _br_quoted_name("b_r_#{ord_part}_ct")
                     elsif _br_bt_descrip.key?(ord_part_sym)
                       ord_part = _br_bt_descrip.fetch(ord_part_sym, nil)&.first&.last&.first&.last&.dup
                     elsif !_br_cust_cols.key?(ord_part_sym) && !column_names.include?(ord_part)
                       # Disallow ordering by a bogus column
                       # %%% Note this bogus entry so that Javascript can remove any bogus _brick_order
                       # parameter from the querystring, pushing it into the browser history.
                       ord_part = nil
                     end

                     if ord_part
                       ord_part << ' DESC' if is_desc
                       ord_part << (is_desc ? ' NULLS LAST' : ' NULLS FIRST') if is_nulls_switch == :pg
                       ord_part.insert(0, '-') if is_nulls_switch == :mysql

                       order_by_txt&.<<("Arel.sql(#{ord_part.inspect})")

                       # # Retain any reference to a bt_descrip as being a symbol
                       # # Was:  "#{quoted_table_name}.\"#{ord_part}\""
                       # order_by_txt&.<<(_br_bt_descrip.key?(ord_part) ? ord_part : ord_part.inspect)
                       s << ord_part
                     end
                   end
                 end
      [order_by, order_by_txt]
    end

    def self.brick_select(*args, **kwargs)
      all.brick_select(*args, **kwargs)
    end

    def self.brick_pluck(*args, withhold_ids: true, **kwargs)
      all.brick_pluck(*args, withhold_ids: withhold_ids, **kwargs)
    end

    def self.brick_where(*args)
      all.brick_where(*args)
    end

    def self.brick_group(*args, withhold_ids: true, **kwargs)
      all.brick_group(*args, withhold_ids: withhold_ids, **kwargs)
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
      if respond_to?(:dangerous_attribute_method?)
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
  end

  class Relation
    attr_accessor :_brick_page_num

    # Links from ActiveRecord association pathing names over to the real table
    # correlation names that get chosen when the AREL AST tree is walked.
    def brick_links(do_dup = true)
      # Touching AREL AST walks the JoinDependency tree, and in that process uses our
      # "brick_links" patch to find how every AR chain of association names relates to exact
      # table correlation names chosen by AREL.  Unless a relation has already had its AST
      # tree built out, we will use a duplicate relation object for this, because an important
      # side-effect of referencing the AST is that the @arel instance variable gets set.  This
      # is a signal to ActiveRecord that a relation has now become immutable.  (When Brick is
      # still in the middle of calculating its query, we aren't quite ready for the relation
      # object to be set in stone ... still need to add .select(), and possibly .where() and
      # .order() things ... also if there are any HM counts then an OUTER JOIN for each of
      # them out to a derived table to do that counting.  All of these things need to know
      # proper table correlation names, which will now become available from brick_links on
      # the rel_dupe object.)
      @_brick_links ||= begin
                          # If it's a CollectionProxy (which inherits from Relation) then need to dig
                          # out the core Relation object which is found in the association scope.
                          brick_rel = is_a?(ActiveRecord::Associations::CollectionProxy) ? scope : self
                          brick_rel = (@_brick_rel_dup ||= brick_rel.dup) if do_dup
                          # Start out with a hash that has only the root table name
                          brick_rel.instance_variable_set(:@_brick_links, bl = { '' => table_name })
                          brick_rel.arel.ast if do_dup # Walk the AST tree in order to capture all the other correlation names
                          bl
                        end
    end

    def brick_select(*args, **kwargs)
      selects = args[0].is_a?(Array) ? args[0] : args
      _brick_querying(selects, **kwargs)
      select(selects)
    end

    def brick_pluck(*args, withhold_ids: true, **kwargs)
      selects = args[0].is_a?(Array) ? args[0] : args
      _brick_querying(selects, withhold_ids: withhold_ids, **kwargs)
      pluck(selects)
    end

    def brick_group(*args, **kwargs)
      grouping = args[0].is_a?(Array) ? args[0] : args
      _brick_querying(select_values.frozen? ? select_values.dup : select_values,
                      grouping: grouping, **kwargs)
      self
    end

    def _brick_querying(*args, grouping: nil, withhold_ids: nil, params: {}, order_by: nil, translations: {},
                        join_array: ::Brick::JoinArray.new,
                        cust_col_override: nil,
                        brick_col_names: nil)
      selects = args[0].is_a?(Array) ? args[0] : args
      unless cust_col_override
        if selects.present? # See if there's any fancy ones in the select list
          idx = 0
          while idx < selects.length
            v = selects[idx]
            if v.is_a?(String) && v.index('.')
              # No prefixes and not polymorphic
              pieces = self.brick_parse_dsl(join_array, [], translations, false, dsl = "[#{v}]")
              (cust_col_override ||= {})[v.tr('.', '_').to_sym] = [pieces, dsl, true]
              selects.delete_at(idx)
            else
              idx += 1
            end
          end
        elsif selects.is_a?(Hash) && params.empty? # Make sense of things if they've passed in only params
          params = selects
          selects = []
        end
      end
      is_add_bts = is_add_hms = !cust_col_override

      # Build out cust_cols, bt_descrip and hm_counts now so that they are available on the
      # model early in case the user wants to do an ORDER BY based on any of that.
      model._brick_calculate_bts_hms(translations, join_array) if is_add_bts || is_add_hms

      is_distinct = nil
      wheres = {}
      params.each do |k, v|
        k = k.to_s # Rails < 4.2 comes in as a symbol
        next unless k.start_with?('__')

        k = k[2..-1] # Take off leading "__"
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
        wheres[k] = v.is_a?(String) ? v.split(',') : v
      end

      # %%% Skip the metadata columns
      if selects.empty? # Default to all columns
        id_parts = (id_col = klass.primary_key).is_a?(Array) ? id_col : [id_col]
        tbl_no_schema = table.name.split('.').last
        # %%% Have once gotten this error with MSSQL referring to http://localhost:3000/warehouse/cold_room_temperatures__archive
        #     ActiveRecord::StatementInvalid (TinyTds::Error: DBPROCESS is dead or not enabled)
        #     Relevant info here:  https://github.com/rails-sqlserver/activerecord-sqlserver-adapter/issues/402
        is_api = params['_brick_is_api']
        columns[0..450].each do |col|
          next if (col.type.nil? || col.type == :binary) && is_api

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
      elsif !withhold_ids # Having some select columns chosen, add any missing always_load_fields for this model ...
        this_model = klass
        loop do
          ::Brick.config.always_load_fields.fetch(this_model.name, nil)&.each do |alf|
            selects << alf unless selects.include?(alf)
          end
          # ... plus ALF fields from any and all STI superclasses it may inherit from
          break if (this_model = this_model.superclass).abstract_class? || this_model == ActiveRecord::Base
        end
      end

      # Establish necessary JOINs for any custom GROUP BY columns
      grouping&.each do |group_item|
        # JOIN in all the same ways as the pathing describes
        if group_item.is_a?(String) && (ref_parts = group_item.split('.')).length > 1
          join_array.add_parts(ref_parts)
        end
      end

      if join_array.present?
        if ActiveRecord.version < Gem::Version.new('4.2')
          self.joins_values += join_array # Same as:  joins!(join_array)
        else
          left_outer_joins!(join_array)
        end
      end

      # core_selects = selects.dup
      id_for_tables = Hash.new { |h, k| h[k] = [] }
      field_tbl_names = Hash.new { |h, k| h[k] = {} }
      used_col_aliases = {} # Used to make sure there is not a name clash

      # CUSTOM COLUMNS
      # ==============
      cust_cols = cust_col_override
      cust_cols ||= klass._br_cust_cols unless withhold_ids
      cust_cols&.each do |k, cc|
        brick_links # Intentionally create a relation duplicate
        if @_brick_rel_dup.respond_to?(k) # Name already taken?
          # %%% Use ensure_unique here in this kind of fashion:
          # cnstr_name = ensure_unique(+"(brick) #{for_tbl}_#{pri_tbl}", nil, bts, hms)
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
          tbl_name = brick_links[cc_part[0..-2].map(&:to_s).join('.')]
          # Deal with the conflict if there are two parts in the custom column named the same,
          # "category.name" and "product.name" for instance will end up with aliases of "name"
          # and "product__name".
          col_prefix = 'br_cc_' if brick_col_names
          if (cc_part_idx = cc_part.length - 1).zero?
            col_alias = "#{col_prefix}#{k}__#{table_name.tr('.', '_')}_#{cc_part.first}"
          elsif brick_col_names ||
                used_col_aliases.key?(col_alias = k.to_s) # This sets a simpler custom column name if possible
            while cc_part_idx >= 0 &&
                  (col_alias = "#{col_prefix}#{k}__#{cc_part[cc_part_idx..-1].map(&:to_s).join('__').tr('.', '_')}") &&
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
                  (key_alias = "#{col_prefix}#{k}__#{(cc_part[cc_part_idx..-2] + [dest_pk]).map(&:to_s).join('__')}") &&
                  key_alias != col_alias && # We break out if this key alias does exactly match the col_alias
                  used_col_aliases.key?(key_alias)
              cc_part_idx -= 1
            end
          end
          selects << "#{_br_quoted_name(tbl_name)}.#{_br_quoted_name(cc_part.last)} AS #{_br_quoted_name(col_alias)}"
          cc_part << col_alias
        end
        unless withhold_ids
          # Add a key column unless we've already got it
          if key_alias && !used_col_aliases.key?(key_alias)
            selects << "#{_br_quoted_name(key_tbl_name)}.#{_br_quoted_name(dest_pk)} AS #{_br_quoted_name(key_alias)}"
            used_col_aliases[key_alias] = nil
          end
          cc[2] = key_alias ? [key_klass, key_alias] : nil
        end
      end

      # LEFT OUTER JOINs
      unless cust_col_override
        klass._br_bt_descrip.each do |v|
          v.last.each do |k1, v1| # k1 is class, v1 is array of columns to snag
            next unless (tbl_name = brick_links[v.first.to_s]&.split('.')&.last)

            # If it's Oracle, quote any AREL aliases that had been applied
            tbl_name = "\"#{tbl_name}\"" if ::Brick.is_oracle && brick_links.values.include?(tbl_name)
            field_tbl_name = nil
            v1.map { |x| [x[0..-2].map(&:to_s).join('.'), x.last] }.each_with_index do |sel_col, idx|
              # %%% Strangely in Rails 7.1 on a slower system then very rarely brick_link comes back nil...
              brick_link = brick_links[sel_col.first]
              field_tbl_name = brick_link&.split('.')&.last ||
                # ... so if it is nil then here's a best-effort guess as to what the table name might be.
                klass.reflect_on_association(sel_col.first)&.klass&.table_name
              # If it's Oracle, quote any AREL aliases that had been applied
              field_tbl_name = "\"#{field_tbl_name}\"" if ::Brick.is_oracle && brick_links.values.include?(field_tbl_name)

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

          table_alias = brick_links[assoc_name.to_s]
          _assoc_names[assoc_name] = [table_alias, klass]
        end
      end

      # Add derived table JOIN for the has_many counts
      nix = []
      previous = []
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
                           # Might be able to simplify as:  hm.source_reflection.type
                           poly_ft = [hm.source_reflection.inverse_of.foreign_type, hmt_assoc.source_reflection.class_name]
                         end
                         # link_back << hm.source_reflection.inverse_of.name
                         while hmt_assoc.options[:through] && (hmt_assoc = klass.reflect_on_association(hmt_assoc.options[:through]))
                           through_sources.unshift(hmt_assoc)
                         end
                         # Turn the last member of link_back into a foreign key
                         link_back << hmt_assoc.source_reflection.foreign_key
                         # If it's a HMT based on a HM -> HM, must JOIN the last table into the mix at the end
                         this_hm = hm
                         while !(src_ref = this_hm.source_reflection).belongs_to? && (thr = src_ref.options[:through])
                           through_sources.push(this_hm = src_ref.active_record.reflect_on_association(thr))
                         end
                         through_sources.push(src_ref) unless src_ref.belongs_to?
                         from_clause = +"#{_br_quoted_name(through_sources.first.table_name)} br_t0"
                         # ActiveStorage will not get the correct count unless we do some extra filtering later
                         tbl_nm = 'br_t0' if Object.const_defined?('ActiveStorage') && through_sources.first.klass <= ::ActiveStorage::Attachment
                         fk_col = through_sources.shift.foreign_key

                         idx = 0
                         bail_out = nil
                         the_chain = through_sources.map do |a|
                           from_clause << "\n LEFT OUTER JOIN #{a.table_name} br_t#{idx += 1} "
                           from_clause << if (src_ref = a.source_reflection).macro == :belongs_to
                                            link_back << (nm = hmt_assoc.source_reflection.inverse_of&.name)
                                            # puts "BT #{a.table_name}"
                                            "ON br_t#{idx}.#{a.active_record.primary_key} = br_t#{idx - 1}.#{a.foreign_key}"
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
                                              #   "br_t#{idx}.#{a.foreign_key} = br_t#{idx - 1}.#{a.active_record.primary_key}"
                                            else # Works for HMT through a polymorphic HO
                                              link_back << hmt_assoc.source_reflection.inverse_of&.name # Some polymorphic "_able" thing
                                              "ON br_t#{idx - 1}.#{a.foreign_type} = '#{src_ref.options[:source_type]}' AND " \
                                                "br_t#{idx - 1}.#{a.foreign_key} = br_t#{idx}.#{a.active_record.primary_key}"
                                            end
                                          else # Standard has_many or has_one
                                            # puts "HM #{a.table_name}"
                                            nm = hmt_assoc.source_reflection.inverse_of&.name
                                            # binding.pry unless nm
                                            link_back << nm # if nm
                                            "ON br_t#{idx}.#{a.foreign_key} = br_t#{idx - 1}.#{a.active_record.primary_key}"
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
                           "br_t#{idx}.#{hm.foreign_key}"
                         else # A HMT that goes HM -> HM, something like Categories -> Products -> LineItems
                           "br_t#{idx}.#{src_ref.active_record.primary_key}"
                         end
                       else
                         fk_col = (inv = hm.inverse_of)&.foreign_key || hm.foreign_key
                         # %%% Might only need hm.type and not the first part :)
                         poly_type = inv&.foreign_type || hm.type if hm.options.key?(:as)
                         pk = hm.klass.primary_key
                         (pk.is_a?(Array) ? pk.first : pk) || '*'
                       end
        next unless count_column # %%% Would be able to remove this when multiple foreign keys to same destination becomes bulletproof

        pri_tbl = hm.active_record
        pri_key = hm.options[:primary_key] || pri_tbl.primary_key
        if hm.active_record.abstract_class || case pri_key
                                              when String
                                                hm.active_record.column_names.exclude?(pri_key)
                                              when Array
                                                (pri_key - hm.active_record.column_names).length > 0
                                              end
          # %%% When this gets hit then if an attempt is made to display the ERD, it might end up being blank
          nix << k
          next
        end

        tbl_alias = unique63("b_r_#{hm.name}", previous)
        on_clause = []
        hm_selects = if !pri_key.is_a?(Array) # Probable standard key?
                       if fk_col.is_a?(Array) # Foreign is composite but not Primary?  OK, or choose the first part of the foreign key if nothing else
                         fk_col = fk_col.find { |col_name| col_name == pri_key } || # Try to associate with the same-named part of the foreign key ...
                                  fk_col.first # ... and if no good match, just choose the first part
                       end
                       on_clause << "#{_br_quoted_name("#{tbl_alias}.#{fk_col}")} = #{_br_quoted_name("#{pri_tbl.table_name}.#{pri_key}")}"
                       [fk_col]
                     else # Composite key
                       fk_col.each_with_index { |fk_col_part, idx| on_clause << "#{_br_quoted_name("#{tbl_alias}.#{fk_col_part}")} = #{_br_quoted_name("#{pri_tbl.table_name}.#{pri_key[idx]}")}" }
                       fk_col.dup
                     end
        if poly_type
          hm_selects << poly_type
          on_clause << "#{_br_quoted_name("#{tbl_alias}.#{poly_type}")} = '#{name}'"
        end
        unless from_clause
          tbl_nm = hm.macro == :has_and_belongs_to_many ? hm.join_table : hm.table_name
          hm_table_name = _br_quoted_name(tbl_nm)
        end
        # ActiveStorage has_many_attached needs a bit more filtering
        if (k_str = hm.klass._active_storage_name(k))
          where_ct_clause = "WHERE #{_br_quoted_name("#{tbl_nm}.name")} = '#{k_str}' "
        end
        group_bys = ::Brick.is_oracle || is_mssql ? hm_selects : (1..hm_selects.length).to_a
        join_clause = "LEFT OUTER
JOIN (SELECT #{hm_selects.map { |s| _br_quoted_name("#{'br_t0.' if from_clause}#{s}") }.join(', ')}, COUNT(#{'DISTINCT ' if hm.options[:through]}#{_br_quoted_name(count_column)
          }) AS c_t_ FROM #{from_clause || hm_table_name} #{where_ct_clause}GROUP BY #{group_bys.join(', ')}) #{_br_quoted_name(tbl_alias)}"
        self.joins_values |= ["#{join_clause} ON #{on_clause.join(' AND ')}"] # Same as:  joins!(...)
      end unless cust_col_override
      while (n = nix.pop)
        klass._br_hm_counts.delete(n)
      end

      # Rewrite the group values to reference table and correlation names built out by AREL
      if grouping
        group2 = (gvgu = (group_values + grouping).uniq).each_with_object([]) do |v, s|
          if v.is_a?(Symbol) || (v_parts = v.split('.')).length == 1
            s << v
          elsif (tbl_name = brick_links[v_parts[0..-2].join('.')]&.split('.')&.last)
            s << "#{tbl_name}.#{v_parts.last}"
          else
            s << v
          end
        end
        group!(*group2)
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
            tbl_name = brick_links[v_parts[0..-2].join('.')].split('.').last
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
        order_by, _ = klass._brick_calculate_ordering(order_by, true) # Don't do the txt part
        final_order_by = order_by.each_with_object([]) do |v, s|
          if v.is_a?(Symbol)
            # Add the ordered series of columns derived from the BT based on its DSL
            if (bt_cols = klass._br_bt_descrip[v])
              bt_cols.values.each do |v1|
                v1.each { |v2| s << _br_quoted_name(v2.last) if v2.length > 1 }
              end
            elsif (cc_cols = klass._br_cust_cols[v])
              cc_cols.first.each { |v1| s << _br_quoted_name(v1.last) if v1.length > 1 }
            else
              s << v
            end
          else # String stuff (which defines a custom ORDER BY) just comes straight through
            # v = v.split('.').map { |x| _br_quoted_name(x) }.join('.')
            s << v
            # Avoid "PG::InvalidColumnReference: ERROR: for SELECT DISTINCT, ORDER BY expressions must appear in select list" in Postgres
            selects << v if is_distinct
          end
        end
        self.order_values |= final_order_by # Same as:  order!(*final_order_by)
      end
      # By default just 1000 rows
      default_row_limit = if columns.length > 300
                            50
                          elsif columns.length > 200
                            100
                          elsif columns.length > 100
                            250
                          else
                            1000
                          end
      row_limit = params['_brick_limit'] || params['_brick_page_size'] || default_row_limit
      offset = if (page = params['_brick_page']&.to_i)
                 page = 1 if page < 1
                 (page - 1) * row_limit.to_i
               else
                 params['_brick_offset']
               end
      if offset.is_a?(Numeric) || offset&.present?
        offset = offset.to_i
        self.offset_value = offset unless offset == 0
        @_brick_page_num = (offset / row_limit.to_i) + 1 if row_limit&.!= 0 && (offset % row_limit.to_i) == 0
      end
      # Setting limit_value= is the same as doing:  limit!(1000)  but this way is compatible with AR <= 4.2
      self.limit_value = row_limit.to_i unless row_limit.is_a?(String) && row_limit.empty?
      wheres unless wheres.empty? # Return the specific parameters that we did use
    end

    # Build out an AR relation that queries for a list of objects, and include all the appropriate JOINs to later apply DSL using #brick_descrip
    def brick_list
      pks = klass.primary_key.is_a?(String) ? [klass.primary_key] : klass.primary_key
      selects = pks.each_with_object([]) { |pk, s| s << pk unless s.include?(pk) }
      # Get foreign keys for anything marked to be auto-preloaded, or a self-referencing JOIN
      klass_cols = klass.column_names
      reflect_on_all_associations.each do |a|
        selects << a.foreign_key if a.belongs_to? &&
                                    (preload_values.include?(a.name) ||
                                     (!a.options[:polymorphic] && a.klass == klass && klass_cols.include?(a.foreign_key))
                                    )
      end

      # ActiveStorage compatibility
      selects << 'service_name' if klass.name == 'ActiveStorage::Blob' && ::ActiveStorage::Blob.columns_hash.key?('service_name')
      selects << 'blob_id' if klass.name == 'ActiveStorage::Attachment' && ::ActiveStorage::Attachment.columns_hash.key?('blob_id')
      # Pay gem compatibility
      selects << 'processor' if klass.name == 'Pay::Customer' && Pay::Customer.columns_hash.key?('processor')
      selects << 'customer_id' if klass.name == 'Pay::Subscription' && Pay::Subscription.columns_hash.key?('customer_id')

      pieces, my_dsl = klass.brick_parse_dsl(join_array = ::Brick::JoinArray.new, [], translations = {}, false, nil, true)
      _brick_querying(
        selects, where_values_hash, nil, translations: translations, join_array: join_array,
        cust_col_override: { '_br' => (descrip_cols = [pieces, my_dsl]) },
        brick_col_names: true
      )
      order_values = "#{_br_quoted_name(klass.table_name)}.#{_br_quoted_name(klass.primary_key)}"
      [self.select(selects), descrip_cols]
    end

    # Smart Brick #where that automatically adds the inner JOINs when you have a query like:
    #   Customer.brick_where('orders.order_details.order_date' => '2005-1-1', 'orders.employee.first_name' => 'Nancy')
    # Way to make it a more intrinsic part of ActiveRecord
    # alias _brick_where! where!
    # def where!(opts, *rest)
    def brick_where(opts)
      if opts.is_a?(Hash)
        # && joins_values.empty? # Make sure we don't step on any toes if they've already specified JOIN things
        ja = nil
        opts.each do |k, v|
          # JOIN in all the same ways as the pathing describes
          if k.is_a?(String) && (ref_parts = k.split('.')).length > 1
            (ja ||= ::Brick::JoinArray.new).add_parts(ref_parts)
          end
        end
        if ja&.present?
          if ActiveRecord.version < Gem::Version.new('4.2')
            self.joins_values += ja # Same as:  joins!(ja)
          else
            self.joins!(ja)
          end
          conditions = opts.each_with_object({}) do |v, s|
            if (ref_parts = v.first.split('.')).length > 1 &&
               (tbl = brick_links[ref_parts[0..-2].join('.')])
              s["#{tbl}.#{ref_parts.last}"] = v.last
            else
              s[v.first] = v.last
            end
          end
        end
      end
      # If you want it to be more intrinsic with ActiveRecord, do this instead:  super(conditions, *rest)
      self.where!(conditions)
    end

    # Accommodate when a relation gets queried for a model, and in that model it has an #after_initialize block
    # which references attributes that were not originally included as part of the select_values.
    def brick_(method, *args, brick_orig_relation: nil, **kwargs, &block)
      begin
        send(method, *args, **kwargs, &block) # method will be something like :uniq or :each
      rescue ActiveModel::MissingAttributeError => e
        if e.message.start_with?('missing attribute: ') &&
           klass.column_names.include?(col_name = e.message[19..-1])
          (dup_rel = dup).select_values << col_name
          ret = dup_rel.brick_(method, *args, brick_orig_relation: (brick_orig_relation ||= self), **kwargs, &block)
          always_loads = (::Brick.config.always_load_fields ||= {})

          # Find the most parent STI superclass for this model, and apply an always_load_fields entry for this missing column
          has_field = false
          this_model = klass
          loop do
            has_field = true if always_loads.key?(this_model.name) && always_loads[this_model.name]&.include?(col_name)
            break if has_field || (next_model = this_model.superclass).abstract_class? || next_model == ActiveRecord::Base
            this_model = next_model
          end
          unless has_field
            (brick_orig_relation || self).instance_variable_set(:@brick_new_alf, ((always_loads[this_model.name] ||= []) << col_name))
          end

          if self.object_id == brick_orig_relation.object_id
            puts "*** WARNING: Missing field#{'s' if @brick_new_alf.length > 1}!
Might want to add this in your brick.rb:
  ::Brick.always_load_fields = { #{klass.name.inspect} => #{@brick_new_alf.inspect} }"
            remove_instance_variable(:@brick_new_alf)
          end
          ret
        else
          []
        end
      end
    end

  private

    def shift_or_first(ary)
      ary.length > 1 ? ary.shift : ary.first
    end

    def unique63(name, previous)
      name = name[0..62] if name.length > 63
      unique_num = 1
      loop do
        break unless previous.include?(name)

        unique_suffix = "_#{unique_num += 1}"
        name = "#{name[0..name.length - unique_suffix.length - 1]}#{unique_suffix}"
      end
      previous << name
      name
    end
  end

  module Inheritance
    module ClassMethods
    private

      if respond_to?(:find_sti_class)
        alias _brick_find_sti_class find_sti_class
        def find_sti_class(type_name)
          return if type_name.is_a?(Numeric)

          if ::Brick.sti_models.key?(type_name ||= name)
            ::Brick.sti_models[type_name].fetch(:base, nil) || _brick_find_sti_class(type_name)
          else
            # This auto-STI is more of a brute-force approach, building modules where needed
            # The more graceful alternative is the overload of ActiveSupport::Dependencies#autoload_module! found below
            ::Brick.sti_models[type_name] = { base: self } unless type_name.blank?
            module_prefixes = type_name.split('::')
            module_prefixes.unshift('') unless module_prefixes.first.blank?
            module_name = module_prefixes[0..-2].join('::')
            if (base_name = ::Brick.config.sti_namespace_prefixes&.fetch("#{module_name}::", nil)) ||
              File.exist?(candidate_file = ::Rails.root.join('app/models' + module_prefixes.map(&:underscore).join('/') + '.rb'))
              if base_name
                base_name == "::#{name}" ? self : base_name.constantize
              else
                _brick_find_sti_class(type_name) # Find this STI class normally
              end
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
end

if Object.const_defined?('ActionView')
  require 'brick/frameworks/rails/form_tags'
  require 'brick/frameworks/rails/form_builder'
  module ::ActionView::Helpers
    module FormTagHelper
      include ::Brick::Rails::FormTags
    end
    FormBuilder.class_exec do
      include ::Brick::Rails::FormBuilder
    end
  end

  # FormBuilder#field_id isn't available in Rails < 7.0.  This is a rudimentary version with no `index`.
  unless ::ActionView::Helpers::FormBuilder.methods.include?(:field_id)
    ::ActionView::Helpers::FormBuilder.class_exec do
      def field_id(method)
        [object_name, method.to_s].join('_')
      end
    end
  end

  module ActionDispatch::Routing
    class Mapper
      module Base
        # Pro-actively assess Brick routes.  Useful when there is a "catch all" wildcard route
        # at the end of an existing `routes.rb` file, which would normally steal the show and
        # not let Brick have any fun.  So just call this right before any wildcard routes, and
        # you'll be in business!
        def mount_brick_routes
          add_brick_routes if !::Brick.routes_done && respond_to?(:add_brick_routes)
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

::Brick::ADD_CONST_MISSING = lambda do
  return if @_brick_const_missing_done

  @_brick_const_missing_done = true
  alias _brick_const_missing const_missing
  def const_missing(*args)
    requested = args.first.to_s
    is_controller = requested.end_with?('Controller')
    # self.name is nil when a model name is requested in an .erb file
    if self.name && ::Brick.config.path_prefix
      split_self_name.shift if (split_self_name = self.name.split('::')).first.blank?
      # Asking for the prefix module?
      camelize_prefix = ::Brick.config.path_prefix.camelize
      if self == Object && requested == camelize_prefix
        Object.const_set(args.first, (built_module = Module.new))
        puts "module #{camelize_prefix}; end\n"
        return built_module
      elsif module_parent == Object && self.name == camelize_prefix ||
            module_parent.name == camelize_prefix && module_parent.module_parent == Object
        split_self_name.shift # Remove the identified path prefix from the split name
        is_brick_prefix = true
        if is_controller
          brick_root = split_self_name.empty? ? self : camelize_prefix.constantize
        end
      end
    end
    base_module = if self < ActiveRecord::Migration || !self.name
                    brick_root || Object
                  # elsif split_self_name&.length&.> 1 # Classic mode
                  #   begin
                  #     base = self
                  #     unless (base_goal = requested.split('::')[0..-2].join('::')).empty?
                  #       base = base.parent while base.name != base_goal && base != Object
                  #     end
                  #     binding.pry
                  #     return base._brick_const_missing(*args)

                  #   rescue NameError # %%% Avoid the error "____ cannot be autoloaded from an anonymous class or module"
                  #     return self.const_get(args.first) if self.const_defined?(args.first)

                  #     # unless self == (prnt = (respond_to?(:parent) ? parent : module_parent))
                  #     unless self == Object
                  #       begin
                  #         return Object._brick_const_missing(*args)

                  #       rescue NameError
                  #         return Object.const_get(args.first) if Object.const_defined?(args.first)

                  #       end
                  #     end
                  #   end
                  #   Object
                  else
                    sti_base = (::Brick.config.sti_namespace_prefixes&.fetch("::#{name}::#{requested}", nil) ||
                                ::Brick.config.sti_namespace_prefixes&.fetch("::#{name}::", nil))&.constantize
                    self
                  end
    # puts "#{self.name} - #{args.first}"
    # Unless it's a Brick prefix looking for a TNP that should create a module ...
    relations = ::Brick.relations
    unless (is_tnp_module = (is_brick_prefix && !is_controller && ::Brick.config.table_name_prefixes.values.include?(requested)))
      # ... first look around for an existing module or class.
      desired_classname = (self == Object || !name) ? requested : "#{name}::#{requested}"
      if (self.const_defined?(args.first) && (possible = self.const_get(args.first)) &&
          # Reset `possible` if it's a controller request that's not a perfect match
          # Was:  (possible = nil)  but changed to #local_variable_set in order to suppress the "= should be ==" warning
          (possible&.name == desired_classname || (is_controller && binding.local_variable_set(:possible, nil)))) ||

         # Try to require the respective Ruby file
         # ((filename = ActiveSupport::Dependencies.search_for_file(desired_classname.underscore)) &&
         #  (require_dependency(filename) || true) &&
         (!anonymous? &&
          (filename = ActiveSupport::Dependencies.search_for_file(desired_classname.underscore) ||
                      (self != Object && ActiveSupport::Dependencies.search_for_file((desired_classname = requested).underscore))
          ) && (require_dependency(filename) || true) &&
          (filename != Module.instance_variable_get(:@_brick_last_filename) || # Avoid trying the same exact file twice in a row
           Module.instance_variable_set(:@_brick_last_filename, nil)) &&
           Module.instance_variable_set(:@_brick_last_filename, filename) &&

          (possible = self.const_get(args.first)) && possible.name == desired_classname
         ) ||

         # If any class has turned up so far (and we're not in the middle of eager loading)
         # then return what we've found.
         (possible&.module_parent == base_module && !::Brick.is_eager_loading) # Used to also have:   && possible != self
        if ((!brick_root && (filename || possible.instance_of?(Class))) ||
            (possible.instance_of?(Module) && possible&.module_parent == self) ||
            (possible.instance_of?(Class) && possible == self)) && # Are we simply searching for ourselves?
           # Skip when what we found as `possible` is not related to the base class of an STI model
           (!sti_base || possible.is_a?(sti_base))
          # if possible.is_a?(ActiveRecord::Base) && !possible.abstract_class? && (pk = possible.primary_key) &&
          #    !(relation = relations.fetch(possible.table_name, nil))&.fetch(:pks, nil)
          #   binding.pry
          #   x = 5
          # end
          return possible
        end
      end
      Module.instance_variable_set(:@_brick_last_filename, nil) # Clear out the check for trying the same exact file twice in a row
    end
    class_name = ::Brick.namify(requested)
    is_avo_present = Object.const_defined?('Avo') && ::Avo.respond_to?(:railtie_namespace)
    #        CONTROLLER
    result = if ::Brick.enable_controllers? &&
                is_controller && (plural_class_name = class_name[0..-11]).length.positive?
               # Otherwise now it's up to us to fill in the gaps
               controller_class_name = +''
               full_class_name = +''
               unless self == Object || (is_avo_present && self.name == 'Avo')
                 controller_class_name << ((split_self_name&.first && split_self_name.join('::')) || self.name)
                 full_class_name << "::#{controller_class_name}"
                 controller_class_name << '::'
               end
               # (Go over to underscores for a moment so that if we have something come in like VABCsController then the model name ends up as
               # Vabc instead of VABC)
               singular_class_name = ::Brick.namify(plural_class_name, :underscore).singularize.camelize
               full_class_name << "::#{singular_class_name}"
               skip_controller = nil
               begin
                 if plural_class_name == 'BrickOpenapi' ||
                    (
                      (::Brick.config.add_search || ::Brick.config.add_status || ::Brick.config.add_orphans) &&
                      plural_class_name == 'BrickGem'
                    # Was:  ) || (model = self.const_get(full_class_name))
                    ) || (model = Object.const_get(full_class_name))
                   # puts "#{self.name} - #{full_class_name}"

                   # In the very rare case that we've picked up a MODULE which has the same name as what would be the
                   # resource's MODEL name, just build out an appropriate auto-model on-the-fly. (RailsDevs code has this in PayCustomer.)
                   # %%% We don't yet display the code for this new model
                   if model && !model.is_a?(Class)
                     model, _code = Object.send(:build_model, relations, model.module_parent, model.module_parent.name, singular_class_name)
                   end
                 end
               rescue NameError # If the const_get for the model has failed...
                 skip_controller = true
                 # ... then just fall through and allow it to fail when trying to load the ____Controller class normally.
               end
               unless skip_controller
                 Object.send(:build_controller, self, class_name, plural_class_name, model, relations)
               end

             # MODULE
             elsif (::Brick.enable_models? || ::Brick.enable_controllers?) && # Schema match?
                   # %%% This works for Person::Person -- but also limits us to not being able to allow more than one level of namespacing
                   (base_module == Object || (camelize_prefix && base_module == Object.const_get(camelize_prefix))) &&
                   (schema_name = [(singular_table_name = class_name.underscore),
                                   (table_name = singular_table_name.pluralize),
                                   ::Brick.is_oracle ? class_name.upcase : class_name,
                                   (plural_class_name = class_name.pluralize)].find { |s| Brick.db_schemas&.include?(s) }&.camelize ||
                                  (::Brick.config.sti_namespace_prefixes&.key?("::#{class_name}::") && class_name) ||
                                  (::Brick.config.table_name_prefixes&.values&.include?(class_name) && class_name))
               return self.const_get(schema_name) if self.const_defined?(schema_name) &&
                                                     (!is_tnp_module || self.const_get(schema_name).is_a?(Class))

               # Build out a module for the schema if it's namespaced
               # schema_name = schema_name.camelize
               base_module.const_set(schema_name.to_sym, (built_module = Module.new))
               [built_module, "module #{schema_name}; end\n"]
               # %%% Perhaps an option to use the first module just as schema, and additional modules as namespace with a table name prefix applied

             # MODULE (overrides from "treat_as_module")
             elsif (::Brick.enable_models? || ::Brick.enable_controllers?) &&
                   (possible_module = (base_module == Object ? '' : "#{base_module.name}::") + class_name) &&
                   ::Brick.config.treat_as_module.include?(possible_module)
               base_module.const_set(class_name.to_sym, (built_module = Module.new))
               [built_module, "module #{possible_module}; end\n"]

             # AVO 2.x Resource
             elsif base_module == Object && is_avo_present && requested.end_with?('Resource') &&
                   # Expect that anything called MotorResource or SpinaResource could be from those administrative gems
                   requested.length > 8 && ['MotorResource', 'SpinaResource'].exclude?(requested) &&
                   (model = Object.const_get(requested[0..-9])) && model < ActiveRecord::Base
               built_resource = Class.new(Avo::BaseResource) do
                 self.model_class = model
                 self.title = :brick_descrip
                 self.includes = []
                 ::Brick::ADD_AVO_FIELDS.call(self, model)
               end
               base_module.const_set(requested.to_sym, built_resource)
               [built_resource, nil]

             # AVO 3.x Resource
             elsif is_avo_present && self.name == 'Avo::Resources' &&
                   (model = begin
                              (model = Object.const_get(requested)) && model < ActiveRecord::Base
                              model
                            rescue
                            end)
               [::Brick.avo_3x_resource(model, requested), nil]

             # MODEL
             elsif ::Brick.enable_models?
               # Avo sometimes tries to find a model class inside of the Avo namespace
               if is_avo_present && self.name == 'Avo'
                 name = (base_module = Object).name
               end
               name ||= base_module.name
               # Custom inheritable Brick base model?
               class_name = (inheritable_name = class_name)[5..-1] if class_name.start_with?('Brick')
               Object.send(:build_model, relations, base_module, name, class_name, inheritable_name)
             end
    if result
      built_class, code = result
      puts "\n#{code}\n" if code
      built_class
    elsif !schema_name && ::Brick.config.sti_namespace_prefixes&.key?("::#{class_name}")
#         module_prefixes = type_name.split('::')
#         path = base_module.name.split('::')[0..-2] + []
#         module_prefixes.unshift('') unless module_prefixes.first.blank?
#         candidate_file = ::Rails.root.join('app/models' + module_prefixes.map(&:underscore).join('/') + '.rb')
      base_module._brick_const_missing(*args)
    # elsif base_module != Object
    #   module_parent.const_missing(*args)
    elsif Object.const_defined?('Rails') && ::Rails.respond_to?(:autoloaders) && # After finding nothing else, if Zeitwerk is enabled ...
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

module Brick
  def self.avo_3x_resource(model, requested)
    built_resource = Class.new(Avo::BaseResource) do
      self.model_class = model
      self.title = :brick_descrip
      self.includes = []
      define_method :fields do # Have to be inside of a fields method
        ::Brick::ADD_AVO_FIELDS.call(self, model)
      end
    end
    ::Avo::Resources.const_set(requested.to_sym, built_resource)
    built_resource
  end
end

::Brick::ADD_AVO_FIELDS = lambda do |obj, model|
  require 'generators/avo/resource_generator'
  field_generator = Generators::Avo::ResourceGenerator.new([''])
  field_generator.instance_variable_set(:@model, model)
  flds = field_generator.send(:generate_fields)&.split("\n")
                        &.each_with_object([]) do |f, s|
                          if (f = f.strip).start_with?('field ')
                            f = f[6..-1].split(',')
                            s << [f.first[1..-1].to_sym, [f[1][1..-1].split(': :').map(&:to_sym)].to_h]
                          end
                        end || []
  if (!model.is_view? && mod_pk = model.primary_key)
    obj.field((mod_pk.is_a?(Array) ? mod_pk.first : mod_pk).to_sym, **{ as: :id })
  end
  # Create a call such as:  field :name, as: :text
  flds.each do |f|
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
    kwargs = f.last.is_a?(Hash) ? f.pop : {}
    obj.send(:field, *f, **kwargs)
  end
end

class Object
  class << self

  private

    def build_model(relations, base_module, base_name, class_name, inheritable_name = nil, is_generator = nil)
      tnp = ::Brick.config.table_name_prefixes&.find { |p| p.last == base_module.name }
      # return [base_module, ''] if !base_module.is_a?(Class) && base_name == tnp&.last

      if (base_model = (::Brick.config.sti_namespace_prefixes&.fetch("::#{base_module.name}::#{class_name}", nil) || # Are we part of an auto-STI namespace? ...
                        ::Brick.config.sti_namespace_prefixes&.fetch("::#{base_module.name}::", nil))&.constantize) ||
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
        table_name = base_model.table_name
        build_model_worker(base_module, inheritable_name, model_name, singular_table_name, table_name, relations, table_name)
      else
        # Adjust for STI if we know of a base model for the requested model name
        # %%% Does not yet work with namespaced model names.  Perhaps prefix with plural_class_name when doing the lookups here.
        table_name = if (base_model = ::Brick.sti_models[model_name]&.fetch(:base, nil) || ::Brick.existing_stis[model_name]&.constantize)
                       base_model.table_name
                     else
                       "#{tnp&.first}#{ActiveSupport::Inflector.pluralize(singular_table_name)}"
                     end
        if ::Brick.apartment_multitenant &&
           Apartment.excluded_models.include?(table_name.singularize.camelize)
          schema_name = ::Brick.apartment_default_tenant
        end
        # Maybe, just maybe there's a database table that will satisfy this need
        matching = ::Brick.table_name_lookup&.fetch(
          base_module == Object ? class_name : "#{base_name}::#{class_name}",
          nil
        )
        if (matching ||= [table_name, singular_table_name, plural_class_name, model_name, table_name.titleize].find { |m| relations.key?(schema_name ? "#{schema_name}.#{m}" : m) })
          build_model_worker(schema_name, inheritable_name, model_name, singular_table_name, table_name, relations, matching, is_generator)
        end
      end
    end

    def build_model_worker(schema_name, inheritable_name, model_name, singular_table_name, table_name, relations, matching, is_generator = nil)
      if ::Brick.apartment_multitenant &&
         schema_name == ::Brick.apartment_default_tenant
        relation = relations["#{schema_name}.#{matching}"]
      end
      full_name = if relation || schema_name.blank?
                    if singular_table_name != table_name.singularize && # %%% Try this with http://localhost:3000/brick/spree/property_translations
                       (schema_module = ::Brick.config.table_name_prefixes.find { |k, v| table_name.start_with?(k) }&.last&.constantize)
                      "#{schema_module&.name}::#{inheritable_name || model_name}"
                    else
                      inheritable_name || model_name
                    end
                  else # Prefix the schema to the table name + prefix the schema namespace to the class name
                    schema_module = if schema_name.is_a?(Module) # from an auto-STI namespace?
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
        # Class for auto-generated models to inherit from
        base_model = (::Brick.config.models_inherit_from ||= (begin
                                                                Object.const_defined?('ApplicationRecord') ? ::ApplicationRecord : ::ActiveRecord::Base
                                                              rescue StandardError => ex
                                                                ::ActiveRecord::Base
                                                              end))
      end
      hmts = nil
      if (schema_module || Object).const_defined?((chosen_name = (inheritable_name || model_name)).to_sym)
        possible = (schema_module || Object).const_get(chosen_name)
        return possible unless possible == schema_module || is_generator
      end
      code = +"class #{full_name} < #{base_model.name}\n"
      built_model = Class.new(base_model) do |new_model_class|
        (schema_module || Object).const_set(chosen_name, new_model_class) unless is_generator
        @_brick_relation = relation
        # Enable Elasticsearch for this one?
        access = ::Brick.elasticsearch_models&.is_a?(Hash) ? ::Brick.elasticsearch_models[name] : ::Brick.elasticsearch_models
        @_brick_es_crud ||= case access
                            when String
                              access
                            when :all, :full
                              'icrud' # Auto-create index, and full CRUD
                            else
                              ''
                            end
        unless @_brick_es_crud.blank?
          include ::Elasticsearch::Model
          code << "  include Elasticsearch::Model\n"
          if @_brick_es_crud.index('i') # Enable auto-creation of indexes on import?
            class << self
              alias _original_import import
              def import(options={}, &block)
                self.__elasticsearch__.create_index! unless self.__elasticsearch__.index_exists?
                _original_import(options={}, &block)
              end
            end
          end
          if @_brick_es_crud.index('c') || @_brick_es_crud.index('u') || @_brick_es_crud.index('d')
            include ::Elasticsearch::Model::Callbacks
            code << "  include Elasticsearch::Model::Callbacks\n"
          end
          if @_brick_es_crud.index('r')
            # Customer.__elasticsearch__.search('taco').to_a
          end
          # # Need some mappings for text columns
          # mappings do
          #   indexes :company_name, type: 'text'
          #   indexes :country, type: 'text'
          # end
          # def self.search(q)
          #   s = self.__elasticsearch__.search(q)
          #   binding.pry
          #   s.to_a
          # #   class Elasticsearch::Model::Response::Response
          # #     def to_a
          # #   end
          # # rescue Elastic::Transport::Transport::Errors::NotFound => e
          # #   self.create_index!
          # #   self.__elasticsearch__.search(q)
          # end
        end
        if inheritable_name
          new_model_class.define_singleton_method :inherited do |subclass|
            super(subclass)
            if subclass.name == model_name
              puts "#{full_model_name} properly extends from #{full_name}"
            else
              puts "should be \"class #{model_name} < #{inheritable_name}\"\n           (not \"#{subclass.name} < #{inheritable_name}\")"
            end
          end
          new_model_class.abstract_class = true
          code << "  self.abstract_class = true\n"
        elsif Object.const_defined?('BCrypt') && relation[:cols].include?('password_digest') &&
              !instance_methods.include?(:password) && respond_to?(:has_secure_password)
          puts "Appears that the #{full_name} model is intended to hold user account information.  Applying #has_secure_password."
          has_secure_password
          code << "  has_secure_password\n"
        end
        # Accommodate singular or camel-cased table names such as "order_detail" or "OrderDetails"
        code << "  self.table_name = '#{self.table_name = matching}'\n" if (inheritable_name || model_name).underscore.pluralize != matching

        if (inh_col = relation.fetch(:sti_col, nil) ||
                      ::Brick.config.sti_type_column.find { |_k, v| v.include?(matching) }&.first)
          new_model_class.inheritance_column = inh_col
          code << "  self.inheritance_column = '#{inh_col}'\n"
        end

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
            pk_mutator = if respond_to?(:'primary_keys=')
                           'primary_keys=' # Using the composite_primary_keys gem
                         elsif ActiveRecord.version >= Gem::Version.new('7.1')
                           'primary_key=' # Rails 7.1+?
                         end
            if our_pks.length > 1 && pk_mutator
              new_model_class.send(pk_mutator, our_pks)
              code << "  self.#{pk_mutator[0..-2]} = #{our_pks.map(&:to_sym).inspect}\n"
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

        unless is_sti
          fks = relation[:fks] || {}
          # Do the bulk of the has_many / belongs_to processing, and store details about HMT so they can be done at the very last
          hmts = fks.each_with_object(Hash.new { |h, k| h[k] = [] }) do |fk, hmts2|
                   # The key in each hash entry (fk.first) is the constraint name
                   inverse_assoc_name = (assoc = fk.last)[:inverse]&.fetch(:assoc_name, nil)
                   if (invs = assoc[:inverse_table]).is_a?(Array)
                     if assoc[:is_bt]
                       invs = invs.first # Just do the first one of what would be multiple identical polymorphic belongs_to
                     else
                       invs.each { |inv| build_bt_or_hm(full_name, relations, relation, hmts2, assoc, inverse_assoc_name, inv, code) }
                     end
                   else
                     build_bt_or_hm(full_name, relations, relation, hmts2, assoc, inverse_assoc_name, invs, code)
                   end
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

        # # %%% Enable Turbo Stream if possible -- equivalent of:  broadcasts_to ->(comment) { :comments }
        # if Object.const_defined?(:ApplicationCable) && Object.const_defined?(:Turbo) && Turbo.const_defined?(:Broadcastable) && respond_to?(:broadcasts_to)
        #   relation[:broadcasts] = true
        #   self.broadcasts_to ->(model) { (model&.class&.name || chosen_name).underscore.pluralize.to_sym }
        #   code << "  broadcasts_to ->(#{chosen_name}) { #{chosen_name}&.class&.name&.underscore&.pluralize&.to_sym }\n"
        # end

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
                              options[:source] = hm[1].to_sym
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
              far_assoc = relations[hm.first[:inverse_table]][:fks].find { |_k, v| v[:assoc_name] == hm[1] }
              # Was:  ::Brick.namify(far_assoc.last[:inverse_table], :underscore).camelize
              options[:class_name] = relations[far_assoc.last[:inverse_table]][:class_name]
              options[:foreign_key] = far_assoc.last[:fk].to_sym
            end
            options[:source] ||= hm[1].to_sym unless hmt_name.singularize == hm[1]
            code << "  has_many :#{hmt_name}#{options.map { |opt| ", #{opt.first}: #{opt.last.inspect}" }.join}\n"
            new_model_class.send(:has_many, hmt_name.to_sym, **options)
          end
        end

        # Auto-support Ransack if it's present
        if self.respond_to?(:ransackable_attributes)
          def self.ransackable_attributes(auth_object = nil)
            column_names + _ransackers.keys
          end

          def self.ransackable_associations(auth_object = nil)
            reflect_on_all_associations.map { |a| a.name.to_s } + _ransackers.keys
          end
        end

        code << "end # model #{full_name}\n"
      end # model class definition
      [built_model, code]
    end

    def build_bt_or_hm(full_name, relations, relation, hmts, assoc, inverse_assoc_name, inverse_table, code)
      return unless (singular_table_name = inverse_table&.singularize)

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
                if assoc.key?(:polymorphic) ||
                   # If a polymorphic association is missing but could be established then go ahead and put it into place.
                   relations.fetch(assoc[:inverse_table], nil)&.fetch(:class_name, nil)&.constantize&.reflect_on_all_associations&.find { |inv_assoc| !inv_assoc.belongs_to? && inv_assoc.options[:as].to_s == assoc[:assoc_name] }
                  assoc[:polymorphic] ||= true
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
                singular_assoc_name = ActiveSupport::Inflector.singularize(assoc_name.tr('.', '_'))
                has_ones = ::Brick.config.has_ones&.fetch(full_name, nil)
                macro = if has_ones&.key?(singular_assoc_name)
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
                # Auto-create an accepts_nested_attributes_for for this HM?
                is_anaf = (anaf = ::Brick.config.nested_attributes&.fetch(full_name, nil)) &&
                          (anaf.is_a?(Array) ? anaf.include?(assoc_name) : anaf == assoc_name)
                macro
              end
      # Figure out if we need to specially call out the class_name and/or foreign key
      # (and if either of those then definitely also a specific inverse_of)
      if (singular_table_parts = singular_table_name.split('.')).length > 1 &&
         ::Brick.config.schema_behavior[:multitenant] && singular_table_parts.first == 'public'
        singular_table_parts.shift
      end
      if need_class_name
        options[:class_name] = "::#{assoc[:primary_class]&.name || ::Brick.relations[inverse_table][:class_name]}"
      end
      if need_fk # Funky foreign key?
        options_fk_key = :foreign_key
        if assoc[:fk].is_a?(Array)
          # #uniq works around a bug in CPK where self-referencing belongs_to associations double up their foreign keys
          if (assoc_fk = assoc[:fk].uniq).length > 1
            options_fk_key = :query_constraints if ActiveRecord.version >= ::Gem::Version.new('7.1')
            options[options_fk_key] = assoc_fk
          else
            options[options_fk_key] = assoc_fk.first
          end
        else
          options[options_fk_key] = assoc[:fk].to_sym
        end
      end
      if inverse_assoc_name && (need_class_name || need_fk || need_inverse_of) &&
         (klass = options[:class_name]&.constantize) && (ian = inverse_assoc_name.tr('.', '_').to_sym) &&
         (klass.is_brick? || klass.reflect_on_association(ian))
        options[:inverse_of] = ian
      end

      # Prepare a list of entries for "has_many :through"
      if macro == :has_many
        relations[inverse_table].fetch(:hmt_fks, nil)&.each do |k, hmt_fk|
          next if k == assoc[:fk]

          hmts[ActiveSupport::Inflector.pluralize(hmt_fk.last)] << [assoc, hmt_fk.first]
        end

        # Add any relevant user-requested HMTs
        Brick.config.hmts&.each do |hmt|
          # Make sure this HMT lines up with the current HM
          next unless hmt.first == table_name && hmt[1] == inverse_table &&
                      # And has not already been auto-created
                      !(hmts.fetch(hmt[2], nil)&.any? { |existing_hmt| existing_hmt.first[:assoc_name] == hmt[1] })

          # Good so far -- now see if we have appropriate HM -> BT/HM associations by which we can create this user-requested HMT
          if (hm_assoc = relation[:fks].find { |_k, v| !v[:is_bt] && v[:assoc_name] == hmt[1] }.last) &&
             (hmt_assoc = relations[hm_assoc[:inverse_table]][:fks]&.find { |_k, v| v[:inverse_table] == hmt[2] }.last)
            hmts[hmt[2]] << [hm_assoc, hmt_assoc[:assoc_name]]
          end
        end
      end
      # And finally create a has_one, has_many, or belongs_to for this association
      assoc_name = assoc_name.tr('.', '_').to_sym
      code << "  #{macro} #{assoc_name.inspect}#{options.map { |k, v| ", #{k}: #{v.inspect}" }.join}\n"
      self.send(macro, assoc_name, **options)
      if is_anaf
        code << "  accepts_nested_attributes_for #{assoc_name.inspect}\n"
        self.send(:accepts_nested_attributes_for, assoc_name)
      end
    end

    def default_ordering(table_name, pk, omit_table_name = nil)
      case (order_tbl = ::Brick.config.order[table_name]) && (order_default = order_tbl[:_brick_default])
      when Array
        order_default.map { |od_part| order_tbl[od_part] || od_part }
      when Symbol
        order_tbl[order_default] || order_default
      else
        pk.map { |part| "#{"#{table_name}." unless omit_table_name}#{part}"} # If it's not a custom ORDER BY, just use the key
      end
    end

    def build_controller(namespace, class_name, plural_class_name, model, relations)
      if (is_avo = (namespace.name == 'Avo' && Object.const_defined?('Avo')))
        # Basic Avo functionality is available via its own generic controller.
        # (More information on https://docs.avohq.io/2.0/controllers.html)
        controller_base = Avo::ResourcesController
      end
      if !model&.table_exists? && (tn = model&.table_name)
        msg = +"Can't find table \"#{tn}\" for model #{model.name}."
        puts
        # Potential bad inflection?
        if (dym = DidYouMean::SpellChecker.new(dictionary: ::Brick.relations.keys).correct(tn)).present?
          msg << "\nIf you meant \"#{found_dym = dym.first}\" then to avoid this message add this entry into inflections.rb:\n"
          msg << "  inflect.irregular '#{model.name}', '#{found_dym.camelize}'"
          model.table_name = found_dym
          puts "WARNING:  #{msg}"
        else
          puts "ERROR:  #{msg}"
        end
        puts
      end
      table_name = model&.table_name || ActiveSupport::Inflector.underscore(plural_class_name)
      singular_table_name = ActiveSupport::Inflector.singularize(ActiveSupport::Inflector.underscore(plural_class_name))
      pk = model&._brick_primary_key(relations.fetch(table_name, nil))
      is_postgres = ActiveRecord::Base.connection.adapter_name == 'PostgreSQL'
      is_mysql = ['Mysql2', 'Trilogy'].include?(ActiveRecord::Base.connection.adapter_name)

      namespace = nil if namespace == ::Object
      controller_base ||= ::Brick.config.controllers_inherit_from if ::Brick.config.controllers_inherit_from
      controller_base = controller_base.constantize if controller_base.is_a?(String)
      controller_base ||= ActionController::Base
      code = +"class #{namespace&.name}::#{class_name} < #{controller_base&.name}\n"
      built_controller = Class.new(controller_base) do |new_controller_class|
        (namespace || ::Object).const_set(class_name.to_sym, new_controller_class)

        # Add a hash for the inline style to the content-security-policy if one is present
        self.define_method(:add_csp_hash) do |style_value = nil|
          if request.respond_to?(:content_security_policy) && (csp = request.content_security_policy)
            if (cspd = csp.directives.fetch('style-src'))
              if style_value
                if (nonce = ::ActionDispatch::ContentSecurityPolicy::Request::NONCE)
                  request.env[nonce] = '' # Generally 'action_dispatch.content_security_policy_nonce'
                end
                # Keep only self, if present, and also add this value
                cspd.select! { |val| val == "'self'" }
                cspd << style_value
              else
                cspd << "'sha256-0Vb7j3kDGE3oNfwMpRLClTSCUo/q74bvbt3p6kG/gkM='"
              end
              cspd << 'https://cdn.jsdelivr.net'
            end
            if (cspd = csp.directives.fetch('script-src'))
              cspd << 'https://cdn.jsdelivr.net'
            end
          end
        end

        # Brick-specific pages
        case plural_class_name
        when 'BrickGem'
          self.define_method :status do
            instance_variable_set(:@resources, ::Brick.get_status_of_resources)
            add_csp_hash
          end
          # # if ::Brick.config.add_schema
          # # Currently can only do adding columns
          # self.define_method :schema_create do
          #   if (base_class = (model = params['modelName']&.constantize).base_class) &&
          #      base_class.column_names.exclude?(col_name = params['colName'])
          #     ActiveRecord::Base.connection.add_column(base_class.table_name.to_sym, col_name, (col_type = params['colType']).to_sym)
          #     base_class.reset_column_information
          #     ::Brick.relations[base_class.table_name]&.fetch(:cols, nil)&.[]=(col_name, [col_type, nil, false, false])
          #     # instance_variable_set(:@schema, ::Brick.find_schema(::Brick.set_db_schema(params).first))
          #     add_csp_hash
          #   end
          # end

          # Associate and unassociate in an N:M relation
          self.define_method :associate do
            if (base_class = (model = params['modelName']&.constantize).base_class)
              args = params['args']
              record = base_class.create(args[0] => args[1], args[2] => args[3])
              add_csp_hash
              render json: { data: record.id }
            end
          end
          self.define_method :unassociate do
            if (base_class = (model = params['modelName']&.constantize).base_class)
              base_class.find_by(base_class._pk_as_array&.first => params['id']).delete
              add_csp_hash
            end
          end

          self.define_method :orphans do
            instance_variable_set(:@orphans, ::Brick.find_orphans(::Brick.set_db_schema(params).first))
            add_csp_hash
          end
          self.define_method :crosstab do
            @relations = ::Brick.relations.each_with_object({}) do |r, s|
              next if r.first.is_a?(Symbol)

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
        plural_table_name = table_name.split('.').last.pluralize
        unless is_avo
          self.define_method :index do
            request_ver = request.path.split('/')[-2]
            current_api_root = ::Brick.config.api_roots.find do |ar|
              request.path.start_with?(ar) || # Exact match?
              request_ver == ar.split('/').last # Version at least matches?
            end
            if (current_api_root || is_openapi) &&
               !params&.key?('_brick_schema') &&
               (referrer_params = request.env['HTTP_REFERER']&.split('?')&.last&.split('&')&.each_with_object({}) do |x, s|
                 if (kv = x.split('=')).length > 1
                   s[kv.first] = kv[1..-1].join('=')
                 end
               end).present?
              if params
                referrer_params.each { |k, v| (params.respond_to?(:parameters) ? send(:parameters) : params)[k] = v }
              else
                api_params = referrer_params&.to_h
              end
            end
            _schema, @_is_show_schema_list = ::Brick.set_db_schema(params || api_params)

            if is_openapi
              doc_endpoints = (Object.const_defined?('Rswag::Ui') &&
                               (::Rswag::Ui.config.config_object[:urls])) ||
                              ::Brick.instance_variable_get(:@swagger_endpoints)
              api_name = doc_endpoints&.find { |api_url| api_url[:url] == request.path }&.fetch(:name, 'API documentation')
              current_api_ver = current_api_root.split('/').last&.[](1..-1).to_i
              json = { 'openapi': '3.0.1', 'info': { 'title': api_name, 'version': request_ver },
                       'servers': [
                         { 'url': '{scheme}://{defaultHost}',
                           'variables': {
                             'scheme': { 'default': request.env['rack.url_scheme'] },
                             'defaultHost': { 'default': request.env['HTTP_HOST'] }
                           }
                         }
                       ]
                     }
              unless ::Brick.config.enable_api == false
                json['paths'] = relations.each_with_object({}) do |relation, s|
                  next if relation.first.is_a?(Symbol) || (
                            (api_vers = relation.last.fetch(:api, nil)) &&
                            !(api_ver_paths = api_vers[current_api_ver] || api_vers[nil])
                          )

                  schema_tag = {}
                  if (schema_name = relation.last&.fetch(:schema, nil))
                    schema_tag['tags'] = [schema_name]
                  end
                  all_actions = relation.last.key?(:isView) ? [:index, :show] : ::Brick::ALL_API_ACTIONS
                  (api_ver_paths || { relation.first => all_actions }).each do |api_ver_path, actions|
                    relation_name = (api_ver_path || relation.first).tr('.', '/')
                    table_description = relation.last[:description]

                    # Column renaming / exclusions
                    renamed_columns = if (column_renaming = ::Brick.find_col_renaming(api_ver_path, relation.first))
                                        column_renaming.each_with_object({}) do |rename, s|
                                          s[rename.last] = relation.last[:cols][rename.first] if rename.last
                                        end
                                      else
                                        relation.last[:cols]
                                      end
                    { :index => [:get, 'list', true], :create => [:post, 'create a', false] }.each do |k, v|
                      unless actions&.exclude?(k)
                        this_resource = (s["#{current_api_root}#{relation_name}"] ||= {})
                        this_resource[v.first] = {
                          'summary': "#{v[1]} #{relation.first.send(v[2] ? :pluralize : :singularize)}",
                          'description': table_description,
                          'parameters': renamed_columns.map do |k2, v2|
                                          param = { in: 'query', 'name': k2, 'schema': { 'type': v2.first } }
                                          if (col_descrip = relation.last.fetch(:col_descrips, nil)&.fetch(k2, nil))
                                            param['description'] = col_descrip
                                          end
                                          param
                                        end,
                          'responses': { '200': { 'description': 'successful' } }
                        }.merge(schema_tag)
                      end
                    end

                    # We have not yet implemented the #show action
                    if (id_col = relation.last[:pkey]&.values&.first&.first) # ... ID-dependent stuff
                      { :update => [:patch, 'update'], :destroy => [:delete, 'delete'] }.each do |k, v|
                        unless actions&.exclude?(k)
                          this_resource = (s["#{current_api_root}#{relation_name}/{#{id_col}}"] ||= {})
                          this_resource[v.first] = {
                            'summary': "#{v[1]} a #{relation.first.singularize}",
                            'description': table_description,
                            'parameters': renamed_columns.reject { |k1, _v1| Brick.config.metadata_columns.include?(k1) }.map do |k2, v2|
                              param = { 'name': k2, 'schema': { 'type': v2.first } }
                              if (col_descrip = relation.last.fetch(:col_descrips, nil)&.fetch(k2, nil))
                                param['description'] = col_descrip
                              end
                              param
                            end,
                            'responses': { '200': { 'description': 'successful' } }
                          }.merge(schema_tag)
                        end
                      end
                    end
                  end # Do multiple api_ver_paths
                end
              end
              render inline: json.to_json, content_type: request.format
              return
            end

            real_model = model.real_model(params)

            if request.format == :csv # Asking for a template?
              require 'csv'
              exported_csv = CSV.generate(force_quotes: false) do |csv_out|
                real_model.df_export(real_model.brick_import_template).each { |row| csv_out << row }
              end
              render inline: exported_csv, content_type: request.format
              return
            # elsif request.format == :js || current_api_root # Asking for JSON?
            #   # %%% Add:  where, order, page, page_size, offset, limit
            #   data = (real_model.is_view? || !Object.const_defined?('DutyFree')) ? real_model.limit(1000) : real_model.df_export(real_model.brick_import_template)
            #   render inline: { data: data }.to_json, content_type: request.format == '*/*' ? 'application/json' : request.format
            #   return
            end

            # Normal (not swagger or CSV) request

            # %%% Allow params to define which columns to use for order_by
            # Overriding the default by providing a querystring param?
            order_by = params['_brick_order']&.split(',')&.map(&:to_sym) || Object.send(:default_ordering, table_name, pk)

            ar_relation = ActiveRecord.version < Gem::Version.new('4') ? real_model.preload : real_model.all
            params['_brick_is_api'] = true if (is_api = request.format == :js || current_api_root)
            @_brick_params = ar_relation._brick_querying((selects ||= []), params: params, order_by: order_by,
                                                         translations: (translations = {}),
                                                         join_array: (join_array = ::Brick::JoinArray.new),
                                                         brick_col_names: true)

            if is_api # Asking for JSON?
              # Apply column renaming
              data = ar_relation.respond_to?(:_select!) ? ar_relation.dup._select!(*selects) : ar_relation.select(selects)
              if data.present? &&
                 (column_renaming = ::Brick.find_col_renaming(current_api_root, real_model&._brick_relation)&.select { |cr| cr.last })
                data.map!({}) do |row, s|
                  column_renaming.each_with_object({}) do |rename, s|
                    s[rename.last] = row[rename.first] if rename.last
                  end
                end
              end

              # # %%% This currently only gives a window to check security and raise an exception if someone isn't
              # # authenticated / authorised. Still need to figure out column filtering and transformations.
              # proc_result = if (column_filter = ::Brick.config.api_column_filter).is_a?(Proc)
              #                 object_columns = (relation = real_model&._brick_relation)[:cols]
              #                 begin
              #                   num_args = column_filter.arity.negative? ? 5 : column_filter.arity
              #                   # object_name, api_version, columns, data
              #                   api_ver_path = request.path[0..-relation[:resource].length]
              #                   # Call the api_column_filter in the context of this auto-built controller
              #                   instance_exec(*[relation[:resource], relation, api_ver_path, object_columns, data][0...num_args], &column_filter)
              #                 rescue StandardError => e
              #                   puts "::Brick.api_column_filter Proc error: #{e.message}"
              #                 end
              #               end
              # columns = if (proc_result) # Proc returns up to 2 things:  columns, data
              #             # If it's all valid column name strings then we're just rearranging the column sequence
              #             col_names = proc_result.all? { |pr| object_columns.key?(pr) } ? proc_result : proc_result.first.keys
              #             col_names.each_with_object({}) { |cn, s| s[cn] = relation.last[:cols][cn] }
              #           else
              #             relation.last[:cols]
              #           end

              render inline: { data: data }.to_json, content_type: ['*/*', 'text/html'].include?(request.format) ? 'application/json' : request.format
              return
            end

            # %%% Add custom HM count columns
            # %%% What happens when the PK is composite?
            counts = real_model._br_hm_counts.each_with_object([]) do |v, s|
              s << if is_mysql
                     "`b_r_#{v.first}`.c_t_ AS \"b_r_#{v.first}_ct\""
                   elsif is_postgres
                     "\"b_r_#{v.first}\".c_t_ AS \"b_r_#{v.first}_ct\""
                   else
                     "b_r_#{v.first}.c_t_ AS \"b_r_#{v.first}_ct\""
                   end
            end
            ar_select = ar_relation.respond_to?(:_select!) ? ar_relation.dup._select!(*selects, *counts) : ar_relation.select(selects + counts)
            instance_variable_set("@#{plural_table_name}".to_sym, ar_select)
            table_name_no_schema = singular_table_name.pluralize
            if namespace && (idx = lookup_context.prefixes.index(table_name_no_schema))
              lookup_context.prefixes[idx] = "#{namespace.name.underscore}/#{lookup_context.prefixes[idx]}"
            end
            @_brick_excl = session[:_brick_exclude]&.split(',')&.each_with_object([]) do |excl, s|
                             if (excl_parts = excl.split('.')).first == table_name_no_schema
                               s << excl_parts.last
                             end
                           end
            @_brick_es = real_model.instance_variable_get(:@_brick_es_crud)
            @_brick_bt_descrip = real_model._br_bt_descrip
            @_brick_hm_counts = real_model._br_hm_counts
            @_brick_join_array = join_array
            @_brick_erd = params['_brick_erd']&.to_i
            add_csp_hash
          end
        end

        unless is_openapi || is_avo # Normal controller (non-API)
          if controller_base == ActionController::Base && ::Brick.relations[model.table_name].fetch(:broadcasts, nil)
            puts "WARNING:  If you intend to use the #{model.name} model with Turbo Stream broadcasts,
          you will want to have its controller inherit from ApplicationController instead of
          ActionController::Base (which as you can see below is what it currently does).  To enact
          this for every auto-generated controller, you can uncomment this line in brick.rb:
            ::Brick.controllers_inherit_from = 'ApplicationController'"
          end

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

          _, order_by_txt = model._brick_calculate_ordering(default_ordering(table_name, pk, true)) if pk
          code << "  def index\n"
          code << "    @#{plural_table_name} = #{model.name}#{pk&.present? ? ".order(#{order_by_txt.join(', ')})" : '.all'}\n"
          code << "    @#{plural_table_name}._brick_querying(params, brick_col_names: true)\n"
          code << "  end\n"

          # ----------------------------------------------------------------------------------

          if pk.present?
            code << "  def show\n"
            code << "    #{find_by_name = "find_#{singular_table_name}"}\n"
            code << "  end\n"
            self.define_method :show do
              _schema, @_is_show_schema_list = ::Brick.set_db_schema(params)
              _, singular_table_name = model.real_singular(params)
              instance_variable_set("@#{singular_table_name}".to_sym, find_obj)
              add_csp_hash("'unsafe-inline'")
            end
          end

          params_name_sym = (params_name = "#{singular_table_name}_params").to_sym

          # By default, views get marked as read-only
          # unless model.readonly # (relation = relations[model.table_name]).key?(:isView)
          code << "  def new\n"
          code << "    @#{singular_table_name} = #{model.name}.new\n"
          code << "  end\n"
          self.define_method :new do
            _schema, @_is_show_schema_list = ::Brick.set_db_schema(params)
            new_params = begin
                           send(params_name_sym)
                         rescue
                         end
            real_model, singular_table_name = model.real_singular(params)
            new_params ||= real_model.attribute_names.each_with_object({}) do |a, s|
              if (val = params["__#{a}"])
                # val = case new_obj.class.column_for_attribute(a).type
                #       when :datetime, :date, :time, :timestamp
                #         val.
                #       else
                #         val
                #       end
                s[a] = val
              end
            end
            if (new_obj = real_model.new(new_params)).respond_to?(:serializable_hash)
              # Convert any Filename objects with nil into an empty string so that #encode can be called on them
              new_obj.serializable_hash.each do |k, v|
                new_obj.send("#{k}=", ::ActiveStorage::Filename.new('')) if v.is_a?(::ActiveStorage::Filename) && !v.instance_variable_get(:@filename)
              end if Object.const_defined?('ActiveStorage')
            end
            instance_variable_set("@#{singular_table_name}".to_sym, new_obj)
            add_csp_hash
          end

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
            elsif is_json && (q = params['_brick_es']) # Elasticsearch
              # Make sure that the index is actually present and we allow reading before attempting
              es_result = model.__elasticsearch__.search(q).to_a if (es_perms = model.instance_variable_get(:@_brick_es_crud)).index('r')
              render json: { result: es_result }
            else
              real_model = model.real_model(params)
              singular_table_name = real_model.name.underscore.split('/').last
              created_obj = model.send(:new, send(params_name_sym))
              if created_obj.respond_to?(inh_col = model.inheritance_column) && created_obj.send(inh_col) == ''
                created_obj.send("#{inh_col}=", model.name)
              end
              created_obj.save
              @_lookup_context.instance_variable_set(:@_brick_model, real_model)
              if created_obj.errors.empty?
                instance_variable_set("@#{singular_table_name}".to_sym, created_obj)
                index
                render :index
              else # Surface errors to the user in a flash message
                instance_variable_set("@#{singular_table_name}".to_sym, created_obj)
                flash.now.alert = (created_obj.errors.errors.map { |err| "<b>#{err.attribute}</b> #{err.message}" }.join(', '))
                new
                render :new
              end
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
              _, singular_table_name = model.real_singular(params)
              instance_variable_set("@#{singular_table_name}".to_sym, find_obj)
              add_csp_hash
            end

            code << "  def update\n"
            code << "    #{find_by_name}.update(#{params_name})\n"
            code << "  end\n"
            self.define_method :update do
              ::Brick.set_db_schema(params)
              if request.format == :csv # Importing CSV?
                require 'csv'

                # See if internally it's likely a TSV file (tab-separated)
                likely_separator = Hash.new { |h, k| h[k] = 0 }
                request.body.readline # Expect first row to have column headers
                5.times { ::Brick._find_csv_separator(request.body, likely_separator) unless request.body.eof? }
                request.body.rewind
                separator = "\t" if likely_separator["\t"] > likely_separator[',']

                result = model.df_import(CSV.parse(request.body, **{ col_sep: separator || :auto }), model.brick_import_template)
                render inline: result.to_json, content_type: request.format
                return
              # elsif request.format == :js # Asking for JSON?
              #   render inline: model.df_export(true).to_json, content_type: request.format
              #   return
              end

              _, singular_table_name = model.real_singular(params)
              instance_variable_set("@#{singular_table_name}".to_sym, (obj = find_obj))
              upd_params = send(params_name_sym)
              json_overrides = ::Brick.config.json_columns&.fetch(table_name, nil)
              if model.respond_to?(:devise_modules)
                upd_hash = upd_params.to_h
                upd_hash['reset_password_token'] = nil if upd_hash['reset_password_token'].blank?
                upd_hash['reset_password_sent_at'] = nil if upd_hash['reset_password_sent_at'].blank?
                if model.devise_modules.include?(:invitable)
                  upd_hash['invitation_token'] = nil if upd_hash['invitation_token'].blank?
                  upd_hash['invitation_created_at'] = nil if upd_hash['invitation_created_at'].blank?
                  upd_hash['invitation_sent_at'] = nil if upd_hash['invitation_sent_at'].blank?
                  upd_hash['invitation_accepted_at'] = nil if upd_hash['invitation_accepted_at'].blank?
                end
              end
              if (json_cols = model.columns.select { |c| model.json_column?(c) }.map(&:name)).present?
                upd_hash ||= upd_params.to_h
                json_cols.each do |c|
                  begin
                    upd_hash[c] = JSON.parse(upd_hash[c].tr('`', '"').gsub('^^br_btick__', '`'))
                  rescue
                  end
                end
              end
              if (upd_hash ||= upd_params).fetch(model.inheritance_column, nil)&.strip == ''
                upd_hash[model.inheritance_column] = nil
              end
              # Do not clear out a has_many_attached field if it already has an entry and nothing is supplied
              hoa, hma, rtans = model._activestorage_actiontext_fields
              all_params = params[singular_table_name]
              hma.each do |hma_field|
                if upd_hash.fetch(hma_field) == [''] && # No new attachments...
                   all_params&.fetch("_brick_attached_#{hma_field}", nil) # ...and there is something existing
                  upd_hash.delete(hma_field)
                end
              end
              obj.send(:update, upd_hash)
              if obj.errors.any? # Surface errors to the user in a flash message
                flash.now.alert = (obj.errors.errors.map { |err| "<b>#{err.attribute}</b> #{err.message}" }.join(', '))
              end
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
              id = if pk.length == 1 # && model.columns_hash[pk.first]&.type == :string
                     params[:id].gsub('^^sl^^', '/')
                   else
                     if model.columns_hash[pk.first]&.type == :string
                       params[:id]&.split('/')
                     else
                       params[:id]&.split(/[\/,_]/)
                     end.map do |val_part|
                       val_part.gsub('^^sl^^', '/')
                     end
                   end
              # Support friendly_id gem
              id_simplified = id.is_a?(Array) && id.length == 1 ? id.first : id
              if Object.const_defined?('FriendlyId') && model.instance_variable_get(:@friendly_id_config)
                model.friendly.find(id_simplified)
              else
                model.find(id_simplified)
              end
            end
          end

          if is_need_params
            code << "  def #{params_name}\n"
            permits_txt = model._brick_find_permits(model, permits = model._brick_all_fields(true))
            code << "    params.require(:#{model.base_class.name.underscore.tr('/', '_')
                             }).permit(#{permits_txt.map(&:inspect).join(', ')})\n"
            code << "  end\n"
            self.define_method(params_name) do
              params.require(model.base_class.name.underscore.tr('/', '_').to_sym).permit(permits)
            end
            private params_name
            # Get column names for params from relations[model.table_name][:cols].keys
          end
        end # unless is_openapi
        code << "end # #{class_name}\n"
      end # class definition
      [built_controller, code]
    end

    def _brick_nested_friendly_id
      unless @_brick_nested_friendly_id
        ::ActiveRecord::Base.class_exec do
          if private_instance_methods.include?(:assign_nested_attributes_for_collection_association)
            alias _brick_anafca assign_nested_attributes_for_collection_association
            def assign_nested_attributes_for_collection_association(association_name, attributes_collection)
              association = association(association_name)
              slug_column = association.klass.instance_variable_get(:@friendly_id_config)&.slug_column
              return _brick_anafca unless slug_column

              # Here is the FriendlyId version of #assign_nested_attributes_for_collection_association
              options = nested_attributes_options[association_name]
              attributes_collection = attributes_collection.to_h if attributes_collection.respond_to?(:permitted?)

              unless attributes_collection.is_a?(Hash) || attributes_collection.is_a?(Array)
                raise ArgumentError, "Hash or Array expected for attribute `#{association_name}`, got #{attributes_collection.class.name} (#{attributes_collection.inspect})"
              end

              check_record_limit!(options[:limit], attributes_collection)

              if attributes_collection.is_a? Hash
                keys = attributes_collection.keys
                attributes_collection = if keys.include?("id") || keys.include?(:id)
                                          [attributes_collection]
                                        else
                                          attributes_collection.values
                                        end
              end
              existing_records = if association.loaded?
                                   association.target
                                 else
                                   attribute_ids = attributes_collection.filter_map { |a| a["id"] || a[:id] }
                                   if attribute_ids.empty?
                                     []
                                   else # Implement the same logic as "friendly" scope
                                     association.scope.where(association.klass.primary_key => attribute_ids)
                                                      .or(association.scope.where(slug_column => attribute_ids))
                                   end
                                 end
              attributes_collection.each do |attributes|
                attributes = attributes.to_h if attributes.respond_to?(:permitted?)
                attributes = attributes.with_indifferent_access
                if attributes["id"].blank? && attributes[slug_column].blank?
                  unless reject_new_record?(association_name, attributes)
                    association.reader.build(attributes.except(*::ActiveRecord::Base::UNASSIGNABLE_KEYS))
                  end
                elsif (attr_id_str = attributes["id"].to_s) && 
                      (existing_record = existing_records.detect { |record| record.id.to_s == attr_id_str ||
                                                                            record.send(slug_column).to_s == attr_id_str })
                  unless call_reject_if(association_name, attributes)
                    # Make sure we are operating on the actual object which is in the association's
                    # proxy_target array (either by finding it, or adding it if not found)
                    # Take into account that the proxy_target may have changed due to callbacks
                    target_record = association.target.detect { |record| record.id.to_s == attr_id_str ||
                                                                          record.send(slug_column).to_s == attr_id_str }
                    if target_record
                      existing_record = target_record
                    else
                      association.add_to_target(existing_record, skip_callbacks: true)
                    end

                    assign_to_or_mark_for_destruction(existing_record, attributes, options[:allow_destroy])
                  end
                else
                  raise_nested_attributes_record_not_found!(association_name, attributes["id"])
                end
              end
            end # anafca
          end
        end if ::ActiveRecord::QueryMethods.instance_methods.include?(:or)
        @_brick_nested_friendly_id = true
      end
    end

    def _brick_get_hm_assoc_name(relation, hm_assoc, source = nil)
      assoc_name, needs_class = if (relation[:hm_counts][hm_assoc[:inverse_table]]&.> 1) &&
                                   hm_assoc[:alternate_name] != (source || name&.underscore)
                                  plural = "#{hm_assoc[:assoc_name]}_#{ActiveSupport::Inflector.pluralize(hm_assoc[:alternate_name])}"
                                  new_alt_name = (hm_assoc[:alternate_name] == name&.underscore) ? "#{hm_assoc[:assoc_name].singularize}_#{plural}" : plural
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
                                  assoc_parts = assoc_name.split('.')
                                  if (needs_class = assoc_parts.length > 1) # If there is a schema name present, use a downcased version for the :has_many
                                    assoc_parts[0].downcase! if assoc_parts[0] =~ /^[A-Z0-9_]+$/
                                    assoc_name = assoc_parts.join('.')
                                  else
                                    last_class_name_part = ::Brick.relations[hm_assoc[:inverse_table]].fetch(:class_name, nil)&.split('::')&.last ||
                                                           ::Brick.namify(hm_assoc[:inverse_table], :underscore).split('.').last.singularize.camelize
                                    needs_class = assoc_name.singularize.camelize != last_class_name_part
                                  end
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
if Object.const_defined?('OTR') && OTR.const_defined?('ActiveRecord')
  OTR::ActiveRecord.class_exec do
    class << self
      alias _brick_establish_connection! establish_connection!
      def establish_connection!(*args)
        conn = _brick_establish_connection!(*args)
        return conn unless ::Brick.config.mode == :on

        begin
          # ::Brick.is_db_present = true
          ::Brick.reflect_tables
        rescue ActiveRecord::NoDatabaseError
          # ::Brick.is_db_present = false
        end
        Module.class_exec &::Brick::ADD_CONST_MISSING
        conn
      end
    end
  end
else
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
        # ::Brick.is_db_present = true
        ::Brick.reflect_tables
      rescue ActiveRecord::NoDatabaseError
        # ::Brick.is_db_present = false
      end
      if Object.const_defined?('Avo') && ::Avo.respond_to?(:railtie_namespace)
        Module.class_exec &::Brick::ADD_CONST_MISSING
      end
      conn
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
    def _add_bt_and_hm(fk, relations, polymorphic_class = nil, is_optional = false)
      bt_assoc_name = ::Brick.namify(fk[2].dup, :downcase)
      unless polymorphic_class
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
      fk[0] = ::Brick.apartment_default_tenant if ::Brick.is_apartment_excluded_table(fk_namified)
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
                                      if ::Brick.is_apartment_excluded_table(fk[4])
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

      unless fk[4]
        puts "WARNING:  Foreign key \"#{fk[5]}\" for \"#{"#{fk[0]}." if fk[0]}#{fk[1]}.#{fk[2]}\" does not reference a valid primary key or column(s) configured with a unique constraint."
        return
      end
      unless (cnstr_name = fk[5])
        # For any appended references (those that come from config), arrive upon a definitely unique constraint name
        pri_tbl = is_class ? fk[4][:class].underscore : pri_tbl
        pri_tbl = "#{bt_assoc_name}_#{pri_tbl}" if pri_tbl&.singularize != bt_assoc_name
        cnstr_name = ensure_unique(+"(brick) #{for_tbl}_#{pri_tbl}", nil, bts, hms)
        missing = []
        missing << fk[1] unless relations.key?(fk[1])
        missing << primary_table unless is_class || relations.key?(primary_table)
        unless missing.empty?
          tables = relations.reject { |_k, v| v.is_a?(Hash) && v.fetch(:isView, nil) }.keys
                            .select { |table_name| table_name.is_a?(String) }.sort
          puts "Brick: Additional reference #{fk.inspect} refers to non-existent #{'table'.pluralize(missing.length)} #{missing.join(' and ')}. (Available tables include #{tables.join(', ')}.)"
          return
        end
        unless (cols = relations[fk[1]][:cols]).key?(fk[2]) || (polymorphic_class && cols.key?("#{fk[2]}_id") && cols.key?("#{fk[2]}_type"))
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
        if polymorphic_class
          # Assuming same fk (don't yet support composite keys for polymorphics)
          assoc_bt[:inverse_table] << fk[4]
          assoc_bt[:polymorphic] << polymorphic_class
        else # Expect we could have a composite key going
          if assoc_bt[:fk].is_a?(String)
            assoc_bt[:fk] = [assoc_bt[:fk], fk[2]] unless fk[2] == assoc_bt[:fk]
          elsif assoc_bt[:fk].exclude?(fk[2])
            assoc_bt[:fk] << fk[2]
          end
          assoc_bt[:assoc_name] = "#{assoc_bt[:assoc_name]}_#{fk[2]}"
        end
      else
        inverse_table = [primary_table] if polymorphic_class
        assoc_bt = bts[cnstr_name] = { is_bt: true, fk: fk[2], assoc_name: bt_assoc_name, inverse_table: inverse_table || primary_table }
        assoc_bt[:optional] = true if (is_optional ||
                                       (is_optional.nil? && !relations[fk[1]][:cols][fk[2]][3])
                                      ) && ActiveRecord.version >= ::Gem::Version.new('5.0')
        assoc_bt[:polymorphic] = [polymorphic_class] if polymorphic_class
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
        inv_tbl = if ::Brick.config.schema_behavior[:multitenant] && Object.const_defined?('Apartment') && fk[0] == ::Brick.apartment_default_tenant
                    for_tbl
                  else
                    fk[1]
                  end
        assoc_hm = hms[hm_cnstr_name] = { is_bt: false, fk: fk[2], assoc_name: fk_namified.pluralize, alternate_name: bt_assoc_name,
                                          inverse_table: inv_tbl, inverse: assoc_bt }
        assoc_hm[:polymorphic] = true if polymorphic_class
        hm_counts = relation.fetch(:hm_counts) { relation[:hm_counts] = {} }
        this_hm_count = hm_counts[fk[1]] = hm_counts.fetch(fk[1]) { 0 } + 1
      end
      assoc_bt[:inverse] = assoc_hm
    end

    def ar_base
      @ar_base ||= Object.const_defined?(:ApplicationRecord) ? ApplicationRecord : Class.new(ActiveRecord::Base)
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
      rails_root = ::Rails.root.to_s
      models = ::Brick.relations.each_with_object({}) do |rel, s|
                 next if rel.first.is_a?(Symbol)

                 begin
                   if (model = rel.last[:class_name]&.constantize) &&
                      (inh = ActiveRecord::Base._brick_inheriteds[model]&.join(':'))
                     inh = inh[rails_root.length + 1..-1] if inh.start_with?(rails_root)
                     s[rel.first] = [inh, model]
                   end
                 rescue
                 end
               end
      ::Brick.relations.each_with_object([]) do |v, s|
        next if v.first.is_a?(Symbol) # ||
        #       Brick.config.exclude_tables.include?(v.first)

        tbl_parts = v.first.split('.')
        tbl_parts.shift if ::Brick.apartment_multitenant && tbl_parts.length > 1 && tbl_parts.first == ::Brick.apartment_default_tenant
        res = tbl_parts.join('.')
        table_name = (model = models[res])&.last&.table_name
        table_name ||= begin
                         v.last[:class_name].constantize.table_name
                       rescue
                       end
        model = model.first if model.is_a?(Array)
        s << [v.first, table_name || v.first, migrations&.fetch(res, nil), model]
      end
    end

    def ensure_unique(name, delimiter, *sources)
      base = name
      delimiter ||= '_'
      # By default ends up building this regex:  /_(\d+)$/
      if (added_num = name.slice!(Regexp.new("#{delimiter}(\d+)$")))
        added_num = added_num[1..-1].to_i
      else
        added_num = 1
      end
      while (
        name = "#{base}#{delimiter}#{added_num += 1}"
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
        next if frn_tbl.is_a?(Symbol) || # Skip internal metadata entries
                (relation = v.last).key?(:isView) || config.exclude_tables.include?(frn_tbl) ||
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

    def _brick_index(tbl_name, mode = nil, separator = nil, relation = nil, not_path = nil)
      separator ||= '_'
      relation ||= ::Brick.relations.fetch(tbl_name, nil)
      if mode == :migration
        res_name = tbl_name
      else
        res_name = (tbl_name_parts = tbl_name.split('.'))[0..-2].first
        res_name << '.' if res_name
        (res_name ||= +'') << (relation&.fetch(:resource, nil) || tbl_name_parts.last)
      end

      res_parts = ((mode == :singular) ? res_name.singularize : res_name).split('.')
      res_parts.shift if ::Brick.apartment_multitenant && res_parts.length > 1 && res_parts.first == ::Brick.apartment_default_tenant
      index2 = []
      if ::Brick.config.path_prefix
        res_parts.unshift(::Brick.config.path_prefix)
        index2 << ::Brick.config.path_prefix
      end
      if (aps = relation&.fetch(:auto_prefixed_schema, nil)) # && res_parts.last.start_with?(aps)
        aps = aps[0..-2] if aps[-1] == '_'
        last_part = res_parts.last # [aps.length..-1]
        res_parts[-1] = aps
        res_parts << last_part
        index2 << aps
      end
      index = res_parts.map(&:underscore).join(separator)
      if separator == 'x'
        index = index.tr('_', 'x')
      else
        # Rails applies an _index suffix to that route when the resource name isn't something plural
        index << '_index' if mode != :singular && !not_path &&
                             index == (
                                        index2 + [relation[:class_name][(relation&.fetch(:auto_prefixed_class, nil)&.length&.+ 2) || 0..-1]&.underscore&.tr('/', '_') || '_']
                                      ).join(separator)
      end
      index
    end

    def find_col_renaming(api_ver_path, relation_name)
      ::Brick.config.api_column_renaming&.fetch(
        api_ver_path,
        ::Brick.config.api_column_renaming&.fetch(relation_name, nil)
      )
    end

    def _class_pk(dotted_name, multitenant)
      Object.const_get((multitenant ? [dotted_name.split('.').last] : dotted_name.split('.')).map { |nm| "::#{nm.singularize.camelize}" }.join).primary_key
    end

    def is_apartment_excluded_table(tbl)
      if Object.const_defined?('Apartment')
        tbl_klass = (tnp = ::Brick.config.table_name_prefixes&.find { |k, _v| tbl.start_with?(k) }) ? +"#{tnp.last}::" : +''
        tbl_klass << tbl[tnp&.first&.length || 0..-1].singularize.camelize
        Apartment.excluded_models&.include?(tbl_klass)
      end
    end
  end
end
