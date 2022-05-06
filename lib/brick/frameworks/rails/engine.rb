# frozen_string_literal: true

module Brick
  module Rails
    # See http://guides.rubyonrails.org/engines.html
    class Engine < ::Rails::Engine
      # paths['app/models'] << 'lib/brick/frameworks/active_record/models'
      config.brick = ActiveSupport::OrderedOptions.new
      ActiveSupport.on_load(:before_initialize) do |app|
        is_development = (ENV['RAILS_ENV'] || ENV['RACK_ENV'])  == 'development'
        ::Brick.enable_models = app.config.brick.fetch(:enable_models, true)
        ::Brick.enable_controllers = app.config.brick.fetch(:enable_controllers, is_development)
        require 'brick/join_array' if ::Brick.enable_controllers?
        ::Brick.enable_views = app.config.brick.fetch(:enable_views, is_development)
        ::Brick.enable_routes = app.config.brick.fetch(:enable_routes, is_development)
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
        if ::Brick.enable_views?
          ActionView::LookupContext.class_exec do
            alias :_brick_template_exists? :template_exists?
            def template_exists?(*args, **options)
              unless (is_template_exists = _brick_template_exists?(*args, **options))
                # Need to return true if we can fill in the blanks for a missing one
                # args will be something like:  ["index", ["categories"]]
                model = args[1].map(&:camelize).join('::').singularize.constantize
                if is_template_exists = model && (
                     ['index', 'show'].include?(args.first) || # Everything has index and show
                     # Only CUD stuff has create / update / destroy
                      (!model.is_view? && ['new', 'create', 'edit', 'update', 'destroy'].include?(args.first))
                   )
                  @_brick_model = model
                end
              end
              is_template_exists
            end

            alias :_brick_find_template :find_template
            def find_template(*args, **options)
              return  _brick_find_template(*args, **options) unless @_brick_model

              model_name = @_brick_model.name
              pk = @_brick_model.primary_key
              obj_name = model_name.underscore
              table_name = model_name.pluralize.underscore
              bts, hms, associatives = ::Brick.get_bts_and_hms(@_brick_model) # This gets BT and HM and also has_many :through (HMT)
              hms_columns = [] # Used for 'index'
              skip_klass_hms = ::Brick.config.skip_index_hms[model_name] || {}
              hms_headers = hms.each_with_object([]) do |hm, s|
                hm_stuff = [(hm_assoc = hm.last), "H#{hm_assoc.macro == :has_one ? 'O' : 'M'}#{'T' if hm_assoc.options[:through]}", (assoc_name = hm.first)]
                hm_fk_name = if hm_assoc.options[:through]
                               associative = associatives[hm_assoc.name]
                               "'#{associative.name}.#{associative.foreign_key}'"
                             else
                               hm_assoc.foreign_key
                             end
                if args.first == 'index'
                  hms_columns << if hm_assoc.macro == :has_many
                                   set_ct = if skip_klass_hms.key?(assoc_name.to_sym)
                                              'nil'
                                            else
                                              "#{obj_name}._br_#{assoc_name}_ct || 0"
                                            end
"<%= ct = #{set_ct}
     link_to \"#\{ct || 'View'\} #{assoc_name}\", #{hm_assoc.klass.name.underscore.pluralize}_path({ #{hm_fk_name}: #{obj_name}.#{pk} }) unless ct&.zero? %>\n"
                                 else # has_one
"<%= obj = #{obj_name}.#{hm.first}; link_to(obj.brick_descrip, obj) if obj %>\n"
                                 end
                elsif args.first == 'show'
                  hm_stuff << "<%= link_to '#{assoc_name}', #{hm_assoc.klass.name.underscore.pluralize}_path({ #{hm_fk_name}: @#{obj_name}&.first&.#{pk} }) %>\n"
                end
                s << hm_stuff
              end

              schema_options = ::Brick.db_schemas.each_with_object(+'') { |v, s| s << "<option value=\"#{v}\">#{v}</option>" }.html_safe
              # %%% If we are not auto-creating controllers (or routes) then omit by default, and if enabled anyway, such as in a development
              # environment or whatever, then get either the controllers or routes list instead
              table_options = (::Brick.relations.keys - ::Brick.config.exclude_tables)
                              .each_with_object(+'') { |v, s| s << "<option value=\"#{v.underscore.pluralize}\">#{v}</option>" }.html_safe
              css = +"<style>
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
  color: #fff;
  text-align: left;
}
table thead tr th a, table tr th a {
  color: #80FFB8;
}

table th, table td {
  padding: 0.2em 0.5em;
}

.show-field {
  background-color: #004998;
}
.show-field a {
  color: #80B8D2;
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
.wide-input {
  display: block;
  overflow: hidden;
}
.wide-input input[type=text] {
  width: 100%;
}
.dimmed {
  background-color: #C0C0C0;
}
input[type=submit] {
  background-color: #004998;
  color: #FFF;
}
.right {
  text-align: right;
}
</style>
<% def is_bcrypt?(val)
  val.is_a?(String) && val.length == 60 && val.start_with?('$2a$')
end
def hide_bcrypt(val)
  is_bcrypt?(val) ? '(hidden)' : val
end %>"

              if ['index', 'show', 'update'].include?(args.first)
                css << "<% bts = { #{bts.each_with_object([]) { |v, s| s << "#{v.first.inspect} => [#{v.last.first.inspect}, #{v.last[1].name}, #{v.last[1].primary_key.inspect}]"}.join(', ')} } %>"
              end

              # %%% When doing schema select, if there's an ID then remove it, or if we're on a new page go to index
              script = "<script>
var schemaSelect = document.getElementById(\"schema\");
var brickSchema;
if (schemaSelect) {
  brickSchema = changeout(location.href, \"_brick_schema\");
  if (brickSchema) {
    [... document.getElementsByTagName(\"A\")].forEach(function (a) { a.href = changeout(a.href, \"_brick_schema\", brickSchema); });
  }
  schemaSelect.value = brickSchema || \"public\";
  schemaSelect.focus();
  schemaSelect.addEventListener(\"change\", function () {
    location.href = changeout(location.href, \"_brick_schema\", this.value);
  });
}
[... document.getElementsByTagName(\"FORM\")].forEach(function (form) {
  if (brickSchema)
    form.action = changeout(form.action, \"_brick_schema\", brickSchema);
  form.addEventListener('submit', function (ev) {
    [... ev.target.getElementsByTagName(\"SELECT\")].forEach(function (select) {
      if (select.value === \"^^^brick_NULL^^^\")
        select.value = null;
    });
    return true;
  });
});

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
  <thead><tr>#{'<th></th>' if pk}
  <% @#{table_name}.columns.map(&:name).each do |col| %>
    <% next if col == '#{pk}' || ::Brick.config.metadata_columns.include?(col) %>
    <th>
    <% if (bt = bts[col]) %>
      BT <%= bt[1].bt_link(bt.first) %>
    <% else %>
      <%= col %>
    <% end %>
    </th>
  <% end %>
  <%# Consider getting the name from the association -- h.first.name -- if a more \"friendly\" alias should be used for a screwy table name %>
  #{hms_headers.map { |h| "<th>#{h[1]} <%= link_to('#{h[2]}', #{h.first.klass.name.underscore.pluralize}_path) %></th>\n" }.join}
  </tr></thead>

  <tbody>
  <% @#{table_name}.each do |#{obj_name}| %>
  <tr>#{"
    <td><%= link_to '⇛', #{obj_name}_path(#{obj_name}.#{pk}), { class: 'big-arrow' } %></td>" if pk}
    <% #{obj_name}.attributes.each do |k, val| %>
      <% next if k == '#{pk}' || ::Brick.config.metadata_columns.include?(k) || k.start_with?('_brfk_') || (k.start_with?('_br_') && k.end_with?('_ct')) %>
      <td>
      <% if (bt = bts[k]) %>
        <%# binding.pry # Postgres column names are limited to 63 characters %>
        <% bt_txt = bt[1].brick_descrip(#{obj_name}, @_brick_bt_descrip[bt.first][1].map { |z| #{obj_name}.send(z.last[0..62]) }, @_brick_bt_descrip[bt.first][2]) %>
        <% bt_id_col = @_brick_bt_descrip[bt.first][2]; bt_id = #{obj_name}.send(bt_id_col) if bt_id_col %>
        <%= bt_id ? link_to(bt_txt, send(\"#\{bt_obj_path_base = bt[1].name.underscore\}_path\".to_sym, bt_id)) : bt_txt %>
        <%#= Previously was:  bt_obj = bt[1].find_by(bt[2] => val); link_to(bt_obj.brick_descrip, send(\"#\{bt_obj_path_base = bt[1].name.underscore\}_path\".to_sym, bt_obj.send(bt[1].primary_key.to_sym))) if bt_obj %>
      <% else %>
        <%= hide_bcrypt(val) %>
      <% end %>
      </td>
    <% end %>
    #{hms_columns.each_with_object(+'') { |hm_col, s| s << "<td>#{hm_col}</td>" }}
  </tr>
  </tbody>
  <% end %>
</table>

#{"<hr><%= link_to \"New #{obj_name}\", new_#{obj_name}_path %>" unless @_brick_model.is_view?}
#{script}"
                       when 'show', 'update'
"#{css}
<p style=\"color: green\"><%= notice %></p>#{"
<select id=\"schema\">#{schema_options}</select>" if ::Brick.db_schemas.length > 1}
<select id=\"tbl\">#{table_options}</select>
<h1>#{model_name}: <%= (obj = @#{obj_name}&.first)&.brick_descrip || controller_name %></h1>
<%= link_to '(See all #{obj_name.pluralize})', #{table_name}_path %>
<% if obj %>
  <%= # path_options = [obj.#{pk}]
   # path_options << { '_brick_schema':  } if
   # url = send(:#{model_name.underscore}_path, obj.#{pk})
   form_for(obj.becomes(#{model_name})) do |f| %>
  <table>
  <% @#{obj_name}.first.attributes.each do |k, val| %>
    <tr>
    <% next if k == '#{pk}' || ::Brick.config.metadata_columns.include?(k) %>
    <th class=\"show-field\">
    <% if (bt = bts[k])
      # Add a final member in this array with descriptive options to be used in <select> drop-downs
      bt_name = bt[1].name
      # %%% Only do this if the user has permissions to edit this bt field
      if bt.length < 4
        bt << (option_detail = [[\"(No #\{bt_name\} chosen)\", '^^^brick_NULL^^^']])
        bt[1].order(:#{pk}).each { |obj| option_detail << [obj.brick_descrip, obj.#{pk}] }
      end %>
      BT <%= bt[1].bt_link(bt.first) %>
    <% else %>
      <%= k %>
    <% end %>
    </th>
    <td>
    <% if (bt = bts[k]) # bt_obj.brick_descrip
      html_options = { prompt: \"Select #\{bt_name\}\" }
      html_options[:class] = 'dimmed' unless val %>
      <%= f.select k.to_sym, bt[3], { value: val || '^^^brick_NULL^^^' }, html_options %>
      <%= bt_obj = bt[1].find_by(bt[2] => val); link_to('⇛', send(\"#\{bt_obj_path_base = bt_name.underscore\}_path\".to_sym, bt_obj.send(bt[1].primary_key.to_sym)), { class: 'show-arrow' }) if bt_obj %>
    <% else case #{model_name}.column_for_attribute(k).type
      when :string, :text %>
        <% if is_bcrypt?(val) # || .readonly? %>
          <%= hide_bcrypt(val) %>
        <% else %>
          <div class=\"wide-input\"><%= f.text_field k.to_sym %></div>
        <% end %>
      <% when :boolean %>
        <%= f.check_box k.to_sym %>
      <% when :integer, :decimal, :float, :date, :datetime, :time, :timestamp
         # What happens when keys are UUID?
         # Postgres naturally uses the +uuid_generate_v4()+ function from the uuid-ossp extension
         # If it's not yet enabled then:  enable_extension 'uuid-ossp'
         # ActiveUUID gem created a new :uuid type %>
        <%= val %>
      <% when :binary, :primary_key %>
      <% end %>
    <% end %>
    </td>
    </tr>
    <% end %>
    <tr><td colspan=\"2\" class=\"right\"><%= f.submit %></td></tr>
  </table>
  <% end %>

  #{hms_headers.map do |hm|
  next unless (pk = hm.first.klass.primary_key) # %%% Should this be an each_with_object instead?

  "<table id=\"#{hm_name = hm.first.name.to_s}\">
    <tr><th>#{hm[3]}</th></tr>
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
<% end %>
#{script}"

                       end
              # As if it were an inline template (see #determine_template in actionview-5.2.6.2/lib/action_view/renderer/template_renderer.rb)
              keys = options.has_key?(:locals) ? options[:locals].keys : []
              handler = ActionView::Template.handler_for_extension(options[:type] || 'erb')
              ActionView::Template.new(inline, "auto-generated #{args.first} template", handler, locals: keys)
            end
          end
        end

        if ::Brick.enable_routes?
          ActionDispatch::Routing::RouteSet.class_exec do
            # In order to defer auto-creation of any routes that already exist, calculate Brick routes only after having loaded all others
            prepend ::Brick::RouteSet
          end
        end

        # Just in case it hadn't been done previously when we tried to load the brick initialiser,
        # go make sure we've loaded additional references (virtual foreign keys).
        ::Brick.load_additional_references
      end
    end
  end
end
