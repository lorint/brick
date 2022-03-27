# frozen_string_literal: true

module Brick
  module Rails
    # See http://guides.rubyonrails.org/engines.html
    class Engine < ::Rails::Engine
      # paths['app/models'] << 'lib/brick/frameworks/active_record/models'
      config.brick = ActiveSupport::OrderedOptions.new
      ActiveSupport.on_load(:before_initialize) do |app|
        ::Brick.enable_models = app.config.brick.fetch(:enable_models, true)
        ::Brick.enable_controllers = app.config.brick.fetch(:enable_controllers, false)
        ::Brick.enable_views = app.config.brick.fetch(:enable_views, false)
        ::Brick.enable_routes = app.config.brick.fetch(:enable_routes, false)
        ::Brick.skip_database_views = app.config.brick.fetch(:skip_database_views, false)

        # Specific database tables and views to omit when auto-creating models
        ::Brick.exclude_tables = app.config.brick.fetch(:exclude_tables, [])

        # Class for auto-generated models to inherit from
        ::Brick.models_inherit_from = app.config.brick.fetch(:models_inherit_from, ActiveRecord::Base)

        # When table names have specific prefixes, automatically place them in their own module with a table_name_prefix.
        ::Brick.table_name_prefixes = app.config.brick.fetch(:table_name_prefixes, [])

        # Columns to treat as being metadata for purposes of identifying associative tables for has_many :through
        ::Brick.metadata_columns = app.config.brick.fetch(:metadata_columns, ['created_at', 'updated_at', 'deleted_at'])

        # Columns for which to add a validate presence: true even though the database doesn't have them marked as NOT NULL
        ::Brick.not_nullables = app.config.brick.fetch(:not_nullables, [])

        # Additional references (virtual foreign keys)
        ::Brick.additional_references = app.config.brick.fetch(:additional_references, nil)

        # Skip creating a has_many association for these
        ::Brick.exclude_hms = app.config.brick.fetch(:exclude_hms, nil)

        # Has one relationships
        ::Brick.has_ones = app.config.brick.fetch(:has_ones, nil)
      end

      # After we're initialized and before running the rest of stuff, put our configuration in place
      ActiveSupport.on_load(:after_initialize) do
        # ====================================
        # Dynamically create generic templates
        # ====================================
        if ::Brick.enable_views? || (ENV['RAILS_ENV'] || ENV['RACK_ENV'])  == 'development'
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
                bts, hms = ::Brick.get_bts_and_hms(@_brick_model)
                # Mark has_manys that go to an associative ("join") table so that they are skipped in the UI,
                # as well as any possible polymorphic associations
                exclude_hms = {}
                associatives = hms.each_with_object({}) do |hmt, s|
                  if (through = hmt.last.options[:through])
                    exclude_hms[through] = nil
                    s[hmt.first] = hms[through] # End up with a hash of HMT names pointing to join-table associations
                  elsif hmt.last.inverse_of.nil?
                    puts "SKIPPING #{hmt.last.name.inspect}"
                    # %%% If we don't do this then below associative.name will find that associative is nil
                    exclude_hms[hmt.last.name] = nil
                  end
                end

                schema_options = ::Brick.db_schemas.each_with_object(+'') { |v, s| s << "<option value=\"#{v}\">#{v}</option>" }.html_safe
                table_options = ::Brick.relations.keys.each_with_object(+'') { |v, s| s << "<option value=\"#{v}\">#{v}</option>" }.html_safe
                hms_columns = +'' # Used for 'index'
                hms_headers = hms.each_with_object([]) do |hm, s|
                  next if exclude_hms.key?((hm_assoc = hm.last).name)

                  if args.first == 'index'
                    hm_fk_name = if hm_assoc.options[:through]
                                   associative = associatives[hm_assoc.name]
                                   "'#{associative.name}.#{associative.foreign_key}'"
                                 else
                                   hm_assoc.foreign_key
                                 end
                    hms_columns << if hm_assoc.macro == :has_many
"<td>
  <%= link_to \"#\{#{obj_name}.#{hm.first}.count\} #{hm.first}\", #{hm_assoc.klass.name.underscore.pluralize}_path({ #{hm_fk_name}: #{obj_name}.#{pk} }) unless #{obj_name}.#{hm.first}.count.zero? %>
</td>\n"
                                   else # has_one
"<td>
  <%= obj = #{obj_name}.#{hm.first}; link_to(obj.brick_descrip, obj) if obj %>
</td>\n"
                                   end
                  end
                  s << [hm_assoc, "H#{hm_assoc.macro == :has_one ? 'O' : 'M'}#{'T' if hm_assoc.options[:through]} #{hm.first}"]
                end

                css = "<style>
table {
  border-collapse: collapse;
  margin: 25px 0;
  font-size: 0.9em;
  font-family: sans-serif;
  min-width: 400px;
  box-shadow: 0 0 20px rgba(0, 0, 0, 0.15);
}

table thead tr th, table tr th {
  background-color: #009879;
  color: #ffffff;
  text-align: left;
}

table th, table td {
  padding: 0.2em 0.5em;
}

.show-field {
  background-color: #004998;
}

table tbody tr {
  border-bottom: thin solid #dddddd;
}

table tbody tr:nth-of-type(even) {
  background-color: #f3f3f3;
}

table tbody tr:last-of-type {
  border-bottom: 2px solid #009879;
}

table tbody tr.active-row {
  font-weight: bold;
  color: #009879;
}

a.show-arrow {
  font-size: 1.5em;
  text-decoration: none;
}
a.big-arrow {
  font-size: 2.5em;
  text-decoration: none;
}
</style>
<% def is_bcrypt?(val)
  val.is_a?(String) && val.length == 60 && val.start_with?('$2a$')
end
def hide_bcrypt(val)
  is_bcrypt?(val) ? '(hidden)' : val
end %>"

                script = "<script>
var schemaSelect = document.getElementById(\"schema\");
if (schemaSelect) {
  var brickSchema = changeout(location.href, \"_brick_schema\");
  if (brickSchema) {
    [... document.getElementsByTagName(\"A\")].forEach(function (a) { a.href = changeout(a.href, \"_brick_schema\", brickSchema); });
  }
  schemaSelect.value = brickSchema || \"public\";
  schemaSelect.focus();
  schemaSelect.addEventListener(\"change\", function () {
    location.href = changeout(location.href, \"_brick_schema\", this.value);
  });
}

var tblSelect = document.getElementById(\"tbl\");
if (tblSelect) {
  tblSelect.value = changeout(location.href);
  tblSelect.addEventListener(\"change\", function () {
    var lhr = changeout(location.href, null, this.value);
    if (brickSchema)
      lhr = changeout(lhr, \"_brick_schema\", schemaSelect.value);
    location.href = lhr;
  });
}

function changeout(href, param, value) {
  var hrefParts = href.split(\"?\");
  if (param === undefined || param === null) {
    hrefParts = hrefParts[0].split(\"://\");
    var pathParts = hrefParts[hrefParts.length - 1].split(\"/\");
    if (value === undefined)
      return pathParts[1];
    else
      return hrefParts[0] + \"://\" + pathParts[0] + \"/\" + value;
  }
  var params = hrefParts.length > 1 ? hrefParts[1].split(\"&\") : [];
  params = params.reduce(function (s, v) { var parts = v.split(\"=\"); s[parts[0]] = parts[1]; return s; }, {});
  if (value === undefined) return params[param];
  params[param] = value;
  return hrefParts[0] + \"?\" + Object.keys(params).reduce(function (s, v) { s.push(v + \"=\" + params[v]); return s; }, []).join(\"&\");
}
</script>"

                inline = case args.first
                when 'index'
"#{css}
<p style=\"color: green\"><%= notice %></p>#{"
<select id=\"schema\">#{schema_options}</select>" if ::Brick.db_schemas.length > 1}
<select id=\"tbl\">#{table_options}</select>
<h1>#{model_name.pluralize}</h1>
<% if @_brick_params&.present? %><h3>where <%= @_brick_params.each_with_object([]) { |v, s| s << \"#\{v.first\} = #\{v.last.inspect\}\" }.join(', ') %></h3><% end %>
<table id=\"#{table_name}\">
  <thead><tr>#{"<th></th>" if pk }
  <% bts = { #{bts.each_with_object([]) { |v, s| s << "#{v.first.inspect} => [#{v.last.first.inspect}, #{v.last[1].name}, #{v.last[1].primary_key.inspect}]"}.join(', ')} }
     @#{table_name}.columns.map(&:name).each do |col| %>
    <% next if col == '#{pk}' || ::Brick.config.metadata_columns.include?(col) %>
    <th>
    <% if (bt = bts[col]) %>
      BT <%= \"#\{bt.first\}-\" unless bt[1].name.underscore == bt.first.to_s %><%= bt[1].name %>
    <% else %>
      <%= col %>
    <% end %>
    </th>
  <% end %>
  #{hms_headers.map { |h| "<th>#{h.last}</th>\n" }.join}
  </tr></thead>

  <tbody>
  <% @#{table_name}.each do |#{obj_name}| %>
  <tr>#{"
    <td><%= link_to '⇛', #{obj_name}_path(#{obj_name}.#{pk}), { class: 'big-arrow' } %></td>" if pk }
    <% #{obj_name}.attributes.each do |k, val| %>
      <% next if k == '#{pk}' || ::Brick.config.metadata_columns.include?(k) %>
      <td>
      <% if (bt = bts[k]) %>
        <%# Instead of just 'bt_obj we have to put in all of this junk:
        # send(\"#\{bt_obj_class = bt[1].name.underscore\}_path\".to_sym, bt_obj.send(bt[1].primary_key.to_sym))
        # Otherwise we get stuff like:
        # ActionView::Template::Error (undefined method `vehicle_path' for #<ActionView::Base:0x0000000033a888>) %>
        <%= bt_obj = bt[1].find_by(bt[2] => val); link_to(bt_obj.brick_descrip, send(\"#\{bt_obj_class = bt[1].name.underscore\}_path\".to_sym, bt_obj.send(bt[1].primary_key.to_sym))) if bt_obj %>
      <% else %>
        <%= hide_bcrypt(val) %>
      <% end %>
      </td>
    <% end %>
#{hms_columns}
    <!-- td>X</td -->
  </tr>
  </tbody>
  <% end %>
</table>

#{"<hr><%= link_to \"New #{obj_name}\", new_#{obj_name}_path %>" unless @_brick_model.is_view?}
#{script}"
                when 'show'
  "#{css}
    <p style=\"color: green\"><%= notice %></p>#{"
    <select id=\"schema\">#{schema_options}</select>" if ::Brick.db_schemas.length > 1}
    <select id=\"tbl\">#{table_options}</select>
    <h1>#{model_name}: <%= (obj = @#{obj_name}.first).brick_descrip %></h1>
    <%= link_to '(See all #{obj_name.pluralize})', #{table_name}_path %>
  <%= form_for obj do |f| %>
  <table>
  <% bts = { #{bts.each_with_object([]) { |v, s| s << "#{v.first.inspect} => [#{v.last.first.inspect}, #{v.last[1].name}, #{v.last[1].primary_key.inspect}]"}.join(', ')} }
      @#{obj_name}.first.attributes.each do |k, val| %>
    <tr>
    <% next if k == '#{pk}' || ::Brick.config.metadata_columns.include?(k) %>
    <th class=\"show-field\">
    <% if (bt = bts[k])
      # Add a final member in this array with descriptive options to be used in <select> drop-downs
      # %%% Only do this if the user has permissions to edit this bt field
      bt << bt[1].order(:#{pk}).map { |obj| [obj.brick_descrip, obj.#{pk}] } if bt.length < 4 %>
      BT <%= \"#\{bt.first\}-\" unless bt[1].name.underscore == bt.first.to_s %><%= bt[1].name %>
    <% else %>
      <%= k %>
    <% end %>
    </th>
    <td>
    <% if (bt = bts[k]) # bt_obj.brick_descrip %>
      <%= f.select k.to_sym, bt[3], {}, prompt: 'Select #{model_name}' %>
      <%= bt_obj = bt[1].find_by(bt[2] => val); link_to('⇛', send(\"#\{bt_obj_class = bt[1].name.underscore\}_path\".to_sym, bt_obj.send(bt[1].primary_key.to_sym)), { class: 'show-arrow' }) if bt_obj %>
    <% elsif is_bcrypt?(val) %>
      <%= hide_bcrypt(val) %>
    <% else %>
      <%= f.text_field k.to_sym %>
    <% end %>
    </td>
    </tr>
  <% end %>
  </table>
  <% end %>

  #{hms_headers.map do |hm|
    next unless (pk = hm.first.klass.primary_key)
  "<table id=\"#{hm_name = hm.first.name.to_s}\">
    <tr><th>#{hm.last}</th></tr>
    <% collection = @#{obj_name}.first.#{hm_name}
    collection = collection.is_a?(ActiveRecord::Associations::CollectionProxy) ? collection.order(#{pk.inspect}) : [collection]
    if collection.empty? %>
      <tr><td>(none)</td></tr>
    <% else %>
      <% collection.uniq.each do |#{hm_singular_name = hm_name.singularize.underscore}| %>
        <tr><td><%= link_to(#{hm_singular_name}.brick_descrip, #{hm.first.klass.name.underscore}_path(#{hm_singular_name}.#{pk})) %></td></tr>
      <% end %>
    <% end %>
  </table>" end.join}
#{script}"

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

        if ::Brick.enable_routes? || (ENV['RAILS_ENV'] || ENV['RACK_ENV'])  == 'development'
          ActionDispatch::Routing::RouteSet.class_exec do
            # In order to defer auto-creation of any routes that already exist, calculate Brick routes only after having loaded all others
            prepend ::Brick::RouteSet
          end
        end

        # Just in case it hadn't been done previously when we tried to load the brick initialiser,
        # go make sure we've loaded additional references (virtual foreign keys).
        ::Brick.load_additional_references

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
    end
  end
end
