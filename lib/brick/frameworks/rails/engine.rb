# frozen_string_literal: true

module Brick
  module Rails
    # See http://guides.rubyonrails.org/engines.html
    class Engine < ::Rails::Engine
      # paths['app/models'] << 'lib/brick/frameworks/active_record/models'
      puts "BEFORE - engine set config"
      config.brick = ActiveSupport::OrderedOptions.new
      # initializer 'brick.initialisation' do |app|
      ActiveSupport.on_load(:before_initialize) do |app|
        puts "BEFORE - engine initialisation"
        ::Brick.enable_models = app.config.brick.fetch(:enable_models, true)
        ::Brick.enable_controllers = app.config.brick.fetch(:enable_controllers, true)
        ::Brick.enable_views = app.config.brick.fetch(:enable_views, true)
        ::Brick.enable_routes = app.config.brick.fetch(:enable_routes, true)
        ::Brick.skip_database_views = app.config.brick.fetch(:skip_database_views, false)

        # Specific database tables and views to omit when auto-creating models
        ::Brick.exclude_tables = app.config.brick.fetch(:exclude_tables, [])

        # Columns to treat as being metadata for purposes of identifying associative tables for has_many :through
        ::Brick.metadata_columns = app.config.brick.fetch(:metadata_columns, ['created_at', 'updated_at', 'deleted_at'])

        # Additional references (virtual foreign keys)
        ::Brick.additional_references = app.config.brick.fetch(:additional_references, nil)

        # After we're initialized and before running the rest of stuff, put our configuration in place
        ActiveSupport.on_load(:after_initialize) do |xyz|
          puts "AFTER - engine initialisation"
          # ====================================
          # Dynamically create generic templates
          # ====================================
          if ::Brick.enable_views?
            ActionView::LookupContext.class_exec do
              alias :_brick_template_exists? :template_exists?
              def template_exists?(*args, **options)
                unless (is_template_exists = _brick_template_exists?(*args, **options))
                  # Need to return true if we can fill in the blanks for a missing one
                  # args will be something like:  ["index", ["categories"]]
                  model = args[1].map(&:camelize).join('::').singularize.constantize
                  if (
                       is_template_exists = model && (
                         ['index', 'show'].include?(args.first) || # Everything has index and show
                         # Only CRU stuff has create / update / destroy
                         (!model.is_view? && ['new', 'create', 'edit', 'update', 'destroy'].include?(args.first))
                       )
                     )
                    instance_variable_set(:@_brick_model, model)
                  end
                end
                is_template_exists
              end

              alias :_brick_find_template :find_template
              def find_template(*args, **options)
                if @_brick_model
                  model_name = @_brick_model.name
                  pk = @_brick_model.primary_key
                  obj_name = model_name.underscore
                  table_name = model_name.pluralize.underscore
                  # This gets has_many as well as has_many :through
                  # %%% weed out ones that don't have an available model to reference
                  bts, hms = @_brick_model.reflect_on_all_associations.each_with_object([{}, {}]) do |a, s|
                    case a.macro
                    when :belongs_to
                      # Build #brick_descrip if needed
                      unless a.klass.instance_methods(false).include?(:brick_descrip)
                        descrip_col = (a.klass.columns.map(&:name) - a.klass._brick_get_fks -
                                      (::Brick.config.metadata_columns || []) -
                                      [a.klass.primary_key]).first&.to_sym
                        if descrip_col
                          a.klass.define_method :brick_descrip do
                            send(descrip_col)
                          end
                        end
                      end

                      s.first[a.foreign_key] = [a.name, a.klass]
                    when :has_many
                      s.last[a.name] = a
                    end
                    s
                  end
                  # Weed out has_manys that go to an associative table
                  associatives = hms.select { |k, v| v.options[:through] }.each_with_object({}) do |hmt, s|
                    s[hmt.first] = hms.delete(hmt.last.options[:through]) # End up with a hash of HMT names pointing to join-table associations
                  end
                  hms_headers = hms.each_with_object(+'') { |hm, s| s << "<th>HM#{'T' if hm.last.options[:through]} #{hm.first}</th>\n" }
                  hms_columns = hms.each_with_object(+'') do |hm, s|
                    hm_fk_name = if hm.last.options[:through]
                      associative = associatives[hm.last.name]
                      "'#{associative.name}.#{associative.foreign_key}'"
                    else
                      hm.last.foreign_key
                    end
                    s << "<td>
  <%= link_to \"#\{#{obj_name}.#{hm.first}.count\} #{hm.first}\", #{hm.last.klass.name.underscore.pluralize}_path({ #{hm_fk_name}: #{obj_name}.#{pk} }) %>
</td>\n"
                  end

                  inline = case args.first
                  when 'index'
                    "<p style=\"color: green\"><%= notice %></p>

<h1>#{model_name.pluralize}</h1>
<% if @_brick_params&.present? %><h3>where <%= @_brick_params.each_with_object([]) { |v, s| s << \"#\{v.first\} = #\{v.last.inspect\}\" }.join(', ') %></h3><% end %>

<table id=\"#{table_name}\">
  <tr>
  <% is_first = true; is_need_id_col = nil
     bts = { #{bts.each_with_object([]) { |v, s| s << "#{v.first.inspect} => [#{v.last.first.inspect}, #{v.last.last.name}, #{v.last.last.primary_key.inspect}]"}.join(', ')} }
     @#{table_name}.columns.map(&:name).each do |col| %>
    <% next if col == '#{pk}' || ::Brick.config.metadata_columns.include?(col) %>
    <th>
    <% if bt = bts[col]
        if is_first
          is_first = false
          is_need_id_col = true %>
          </th><th>
        <% end %>
      BT <%= \"#\{bt.first\}-\" unless bt[1].name.underscore == bt.first.to_s %><%= bt[1].name %>
    <% else
        is_first = false %>
      <%= col %>
    <% end %>
    </th>
  <% end %>
  <% if is_first # STILL haven't been able to write a first non-key / non-metadata column?
    is_first = false
    is_need_id_col = true %>
    <th></th>
  <% end %>
#{hms_headers}
  </tr>

  <% @#{table_name}.each do |#{obj_name}| %>
  <tr>
    <% is_first = true
       if is_need_id_col
         is_first = false %>
      <td><%= link_to \"#\{#{obj_name}.class.name\} ##\{#{obj_name}.id\}\", #{obj_name} %></td>
    <% end %>
    <% #{obj_name}.attributes.each do |k, val| %>
      <% next if k == '#{pk}' || ::Brick.config.metadata_columns.include?(k) %>
      <td>
      <% if (bt = bts[k]) %>
        <%= obj = bt[1].find_by(bt.last => val); link_to obj.brick_descrip, obj %>
      <% elsif is_first %>
        <%= is_first = false; link_to val, #{obj_name} %>
      <% else %>
        <%= val %>
      <% end %>
      </td>
    <% end %>
#{hms_columns}
    <!-- td>X</td -->
  </tr>
  <% end %>
</table>

#{"<hr><%= link_to \"New #{obj_name}\", new_#{obj_name}_path %>" unless @_brick_model.is_view?}
"
                  when 'show'
                    "<%= @#{@_brick_model.name.underscore}.inspect %>"
                  end
                  # As if it were an inline template (see #determine_template in actionview-5.2.6.2/lib/action_view/renderer/template_renderer.rb)
                  keys = options.has_key?(:locals) ? options[:locals].keys : []
                  handler = ActionView::Template.handler_for_extension(options[:type] || 'erb')
                  ActionView::Template.new(inline, "auto-generated #{args.first} template", handler, locals: keys)
                else
                  _brick_find_template(*args, **options)
                end
              end
            end
          end

          if ::Brick.enable_routes?
            ActionDispatch::Routing::RouteSet.class_exec do
              alias _brick_finalize_routeset! finalize!
              def finalize!(*args, **options)
                unless @finalized
                  existing_controllers = routes.each_with_object({}) { |r, s| c = r.defaults[:controller]; s[c] = nil if c }
                  ::Rails.application.routes.append do
                    # %%% TODO: If no auto-controllers then enumerate the controllers folder in order to build matching routes
                    # If auto-controllers and auto-models are both enabled then this makes sense:
                    relations = (::Brick.instance_variable_get(:@relations) || {})[ActiveRecord::Base.connection_pool.object_id] || {}
                    relations.each do |k, v|
                      unless existing_controllers.key?(controller_name = k.underscore.pluralize)
                        options = {}
                        options[:only] = [:index, :show] if v.key?(:isView)
                        send(:resources, controller_name.to_sym, **options)
                      end
                    end
                  end
                end
                _brick_finalize_routeset!(*args, **options)
              end
            end
          end

          # Additional references (virtual foreign keys)
          if (ars = ::Brick.config.additional_references)
            ars = ars.call if ars.is_a?(Proc)
            ars = ars.to_a unless ars.is_a?(Array)
            ars = [ars] unless ars.empty? || ars.first.is_a?(Array)
            ars.each do |fk|
              ::Brick._add_bt_and_hm(fk[0..2])
            end
          end

          # Find associative tables that can be set up for has_many :through
          ::Brick.relations.each do |_key, tbl|
            tbl_cols = tbl[:cols].keys
            fks = tbl[:fks].each_with_object({}) { |fk, s| s[fk.last[:fk]] = fk.last[:inverse_table] if fk.last[:is_bt]; s }
            # Aside from the primary key and the metadata columns created_at, updated_at, and deleted_at, if this table only has
            # foreign keys then it can act as an associative table and thus be used with has_many :through.
            if fks.length > 1 && (tbl_cols - fks.keys - (::Brick.config.metadata_columns || []) - tbl[:pkey].values.first).length.zero?
              fks.each { |fk| tbl[:hmt_fks][fk.first] = fk.last }
            end
          end
        end
      end
    end
  end
end
