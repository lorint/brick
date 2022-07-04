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

        # Polymorphic associations
        ::Brick.polymorphics = app.config.brick.fetch(:polymorphics, nil)
      end

      # After we're initialized and before running the rest of stuff, put our configuration in place
      ActiveSupport.on_load(:after_initialize) do
        # ====================================
        # Dynamically create generic templates
        # ====================================
        if ::Brick.enable_views?
          ActionView::LookupContext.class_exec do
            # Used by Rails 5.0 and above
            alias :_brick_template_exists? :template_exists?
            def template_exists?(*args, **options)
              (::Brick.config.add_orphans && args.first == 'orphans') ||
              _brick_template_exists?(*args, **options) ||
              set_brick_model(args)
            end

            def set_brick_model(find_args)
              # Need to return true if we can fill in the blanks for a missing one
              # args will be something like:  ["index", ["categories"]]
              find_args[1] = find_args[1].each_with_object([]) { |a, s| s.concat(a.split('/')) }
              if (class_name = find_args[1].last&.singularize)
                find_args[1][find_args[1].length - 1] = class_name # Make sure the last item, defining the class name, is singular
                if (model = find_args[1].map(&:camelize).join('::').constantize) && (
                     ['index', 'show'].include?(find_args.first) || # Everything has index and show
                     # Only CUD stuff has create / update / destroy
                     (!model.is_view? && ['new', 'create', 'edit', 'update', 'destroy'].include?(find_args.first))
                   )
                  @_brick_model = model
                end
              end
            end

            def path_keys(hm_assoc, fk_name, obj_name, pk)
              keys = if fk_name.is_a?(Array) && pk.is_a?(Array) # Composite keys?
                       fk_name.zip(pk.map { |pk_part| "#{obj_name}.#{pk_part}" })
                     else
                       pk = pk.each_with_object([]) { |pk_part, s| s << "#{obj_name}.#{pk_part}" }
                       [[fk_name, pk.length == 1 ? pk.first : pk.inspect]]
                     end
              keys << [hm_assoc.inverse_of.foreign_type, hm_assoc.active_record.name] if hm_assoc.options.key?(:as)
              keys.map { |x| "#{x.first}: #{x.last}"}.join(', ')
            end

            alias :_brick_find_template :find_template
            def find_template(*args, **options)
              unless (model_name = (
                       @_brick_model ||
                       (ActionView.version < ::Gem::Version.new('5.0') && args[1].is_a?(Array) ? set_brick_model(args) : nil)
                     )&.name) ||
                     (is_orphans = ::Brick.config.add_orphans && args[0..1] == ['orphans', ['brick_gem']])
                return _brick_find_template(*args, **options)
              end

              unless is_orphans
                pk = @_brick_model._brick_primary_key(::Brick.relations.fetch(model_name, nil))
                obj_name = model_name.split('::').last.underscore
                path_obj_name = model_name.underscore.tr('/', '_')
                table_name = obj_name.pluralize
                template_link = nil
                bts, hms, associatives = ::Brick.get_bts_and_hms(@_brick_model) # This gets BT and HM and also has_many :through (HMT)
                hms_columns = [] # Used for 'index'
                skip_klass_hms = ::Brick.config.skip_index_hms[model_name] || {}
                hms_headers = hms.each_with_object([]) do |hm, s|
                  hm_stuff = [(hm_assoc = hm.last), "H#{hm_assoc.macro == :has_one ? 'O' : 'M'}#{'T' if hm_assoc.options[:through]}", (assoc_name = hm.first)]
                  hm_fk_name = if hm_assoc.options[:through]
                                associative = associatives[hm_assoc.name]
                                associative && "'#{associative.name}.#{associative.foreign_key}'"
                              else
                                hm_assoc.foreign_key
                              end
                  if args.first == 'index'
                    hms_columns << if hm_assoc.macro == :has_many
                                     set_ct = if skip_klass_hms.key?(assoc_name.to_sym)
                                                'nil'
                                              else
                                                # Postgres column names are limited to 63 characters
                                                attrib_name = "_br_#{assoc_name}_ct"[0..62]
                                                "#{obj_name}.#{attrib_name} || 0"
                                              end
                                     if hm_fk_name
"<%= ct = #{set_ct}
     link_to \"#\{ct || 'View'\} #{assoc_name}\", #{hm_assoc.klass.name.underscore.tr('/', '_').pluralize}_path({ #{path_keys(hm_assoc, hm_fk_name, obj_name, pk)} }) unless ct&.zero? %>\n"
                                     else # %%% Would be able to remove this when multiple foreign keys to same destination becomes bulletproof
"#{assoc_name}\n"
                                     end
                                   else # has_one
"<%= obj = #{obj_name}.#{hm.first}; link_to(obj.brick_descrip, obj) if obj %>\n"
                                   end
                  elsif args.first == 'show'
                    hm_stuff << if hm_fk_name
                                  "<%= link_to '#{assoc_name}', #{hm_assoc.klass.name.underscore.tr('/', '_').pluralize}_path({ #{path_keys(hm_assoc, hm_fk_name, "@#{obj_name}", pk)} }) %>\n"
                                else # %%% Would be able to remove this when multiple foreign keys to same destination becomes bulletproof
                                  assoc_name
                                end
                  end
                  s << hm_stuff
                end
              end

              schema_options = ::Brick.db_schemas.keys.each_with_object(+'') { |v, s| s << "<option value=\"#{v}\">#{v}</option>" }.html_safe
              # %%% If we are not auto-creating controllers (or routes) then omit by default, and if enabled anyway, such as in a development
              # environment or whatever, then get either the controllers or routes list instead
              apartment_default_schema = ::Brick.config.schema_behavior[:multitenant] && Object.const_defined?('Apartment') && Apartment.default_schema
              table_options = (::Brick.relations.keys - ::Brick.config.exclude_tables).map do |tbl|
                                if (tbl_parts = tbl.split('.')).first == apartment_default_schema
                                  tbl = tbl_parts.last
                                end
                                tbl
                              end.sort.each_with_object(+'') do |v, s|
                                s << "<option value=\"#{v.underscore.gsub('.', '/').pluralize}\">#{v}</option>"
                              end.html_safe
              table_options << '<option value="brick_orphans">(Orphans)</option>'.html_safe if is_orphans
              css = +"<style>
#dropper {
  background-color: #eee;
}
#btnImport {
  display: none;
}

#headerTop {
	position: sticky;
	top: 0px;
	background-color: white;
	z-index: 1;
}
table {
  border-collapse: collapse;
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
def hide_bcrypt(val, max_len = 200)
  if is_bcrypt?(val)
    '(hidden)'
  else
    if val.is_a?(String)
      if val.length > max_len
        val = val[0...max_len]
        val << '...'
      end
      val.force_encoding('UTF-8') unless val.encoding.name == 'UTF-8'
    end
    val
  end
end %>"

              if ['index', 'show', 'update'].include?(args.first)
                poly_cols = []
                css << "<% bts = { #{
                  bt_items = bts.each_with_object([]) do |v, s|
                    foreign_models = if v.last[2] # Polymorphic?
                                       poly_cols << @_brick_model.reflect_on_association(v[1].first).foreign_type
                                       v.last[1].each_with_object([]) { |x, s| s << "[#{x.name}, #{x.primary_key.inspect}]" }.join(', ')
                                     else
                                       "[#{v.last[1].name}, #{v.last[1].primary_key.inspect}]"
                                     end
                    s << "#{v.first.inspect} => [#{v.last.first.inspect}, [#{foreign_models}], #{v.last[2].inspect}]"
                  end
                  # # %%% Need to fix poly going to an STI class
                  # binding.pry unless poly_cols.empty?
                  bt_items.join(', ')
                } }
                poly_cols = #{poly_cols.inspect} %>"
              end

              # %%% When doing schema select, if we're on a new page go to index
              script = "<script>
var schemaSelect = document.getElementById(\"schema\");
var tblSelect = document.getElementById(\"tbl\");
var brickSchema;
var #{table_name}HtColumns;

// This PageTransitionEvent fires when the page first loads, as well as after any other history
// transition such as when using the browser's Back and Forward buttons.
window.addEventListener(\"pageshow\", function() {
  if (schemaSelect) { // First drop-down is only present if multitenant
    brickSchema = changeout(location.href, \"_brick_schema\");
    if (brickSchema) {
      [... document.getElementsByTagName(\"A\")].forEach(function (a) { a.href = changeout(a.href, \"_brick_schema\", brickSchema); });
    }
    schemaSelect.value = brickSchema || \"public\";
    schemaSelect.focus();
    schemaSelect.addEventListener(\"change\", function () {
      // If there's an ID then remove it (trim after selected table)
      location.href = changeout(location.href, \"_brick_schema\", this.value, tblSelect.value);
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

  if (tblSelect) { // Always present
    tblSelect.value = changeout(location.href)[schemaSelect ? 1 : 0];
    tblSelect.addEventListener(\"change\", function () {
      var lhr = changeout(location.href, null, this.value);
      if (brickSchema)
        lhr = changeout(lhr, \"_brick_schema\", schemaSelect.value);
      location.href = lhr;
    });
  }
});

function changeout(href, param, value, trimAfter) {
  var hrefParts = href.split(\"?\");
  if (param === undefined || param === null) {
    hrefParts = hrefParts[0].split(\"://\");
    var pathParts = hrefParts[hrefParts.length - 1].split(\"/\");
    if (value === undefined)
      // A couple possibilities if it's namespaced, starting with two parts in the path -- and then try just one
      return [pathParts.slice(1, 3).join('/'), pathParts.slice(1, 2)];
    else
      return hrefParts[0] + \"://\" + pathParts[0] + \"/\" + value;
  }
  if (trimAfter) {
    var pathParts = hrefParts[0].split(\"/\");
    while (pathParts.lastIndexOf(trimAfter) != pathParts.length - 1) pathParts.pop();
    hrefParts[0] = pathParts.join(\"/\");
  }
  var params = hrefParts.length > 1 ? hrefParts[1].split(\"&\") : [];
  params = params.reduce(function (s, v) { var parts = v.split(\"=\"); s[parts[0]] = parts[1]; return s; }, {});
  if (value === undefined) return params[param];
  params[param] = value;
  return hrefParts[0] + \"?\" + Object.keys(params).reduce(function (s, v) { s.push(v + \"=\" + params[v]); return s; }, []).join(\"&\");
}

// Snag first TR for sticky header
var grid = document.getElementById(\"#{table_name}\");
#{table_name}HtColumns = grid && [grid.getElementsByTagName(\"TR\")[0]];
var headerTop = document.getElementById(\"headerTop\");
function setHeaderSizes() {
  // console.log(\"start\");
  // See if the headerTop is already populated
  // %%% Grab the TRs from headerTop, clear it out, do this stuff, add them back
  headerTop.innerHTML = \"\"; // %%% Would love to not have to clear it out like this every time!  (Currently doing this to support resize events.)
  var isEmpty = headerTop.childElementCount === 0;
  // Set up proper sizings of sticky column header
  var node;
  for (var j = 0; j < #{table_name}HtColumns.length; ++j) {
    var row = #{table_name}HtColumns[j];
    var tr = isEmpty ? document.createElement(\"TR\") : headerTop.childNodes[j];
    tr.innerHTML = row.innerHTML.trim();
    // Match up widths from the original column headers
    for (var i = 0; i < row.childNodes.length; ++i) {
      node = row.childNodes[i];
      if (node.nodeType === 1) {
        var style = tr.childNodes[i].style;
        style.minWidth = style.maxWidth = getComputedStyle(node).width;
      }
    }
    if (isEmpty) headerTop.appendChild(tr);
  }
  grid.style.marginTop = \"-\" + getComputedStyle(headerTop).height;
  // console.log(\"end\");
}
if (headerTop) {
  setHeaderSizes();
  window.addEventListener('resize', function(event) {
    setHeaderSizes();
  }, true);
}
</script>"
              inline = case args.first
                       when 'index'
                         obj_pk = if pk&.is_a?(Array) # Composite primary key?
                                    "[#{pk.map { |pk_part| "#{obj_name}.#{pk_part}" }.join(', ')}]" unless pk.empty?
                                  elsif pk
                                    "#{obj_name}.#{pk}"
                                  end
                         if Object.const_defined?('DutyFree')
                           template_link = "
  <%= link_to 'CSV', #{table_name}_path(format: :csv) %> &nbsp; <a href=\"#\" id=\"sheetsLink\">Sheets</a>
  <div id=\"dropper\" contenteditable=\"true\"></div>
  <input type=\"button\" id=\"btnImport\" value=\"Import\">

<script>
  var dropperDiv = document.getElementById(\"dropper\");
  var btnImport = document.getElementById(\"btnImport\");
  var droppedTSV;
  if (dropperDiv) { // Other interesting events: blur keyup input
    dropperDiv.addEventListener(\"paste\", function (evt) {
      droppedTSV = evt.clipboardData.getData('text/plain');
      var html = evt.clipboardData.getData('text/html');
      var tbl = html.substring(html.indexOf(\"<tbody>\") + 7, html.lastIndexOf(\"</tbody>\"));
      console.log(tbl);
      btnImport.style.display = droppedTSV.length > 0 ? \"block\" : \"none\";
    });
    btnImport.addEventListener(\"click\", function () {
      fetch(changeout(<%= #{path_obj_name}_path(-1, format: :csv).inspect.html_safe %>, \"_brick_schema\", brickSchema), {
        method: 'PATCH',
        headers: { 'Content-Type': 'text/tab-separated-values' },
        body: droppedTSV
      }).then(function (tsvResponse) {
        btnImport.style.display = \"none\";
        console.log(\"toaster\", tsvResponse);
      });
    });
  }
  var sheetUrl;
  var spreadsheetId;
  var sheetsLink = document.getElementById(\"sheetsLink\");
  function gapiLoaded() {
    // Have a click on the sheets link to bring up the sign-in window.  (Must happen from some kind of user click.)
    sheetsLink.addEventListener(\"click\", async function (evt) {
      evt.preventDefault();
      await gapi.load(\"client\", function () {
        gapi.client.init({ // Load the discovery doc to initialize the API
          clientId: \"487319557829-fgj4u660igrpptdji7ev0r5hb6kh05dh.apps.googleusercontent.com\",
          scope: \"https://www.googleapis.com/auth/spreadsheets https://www.googleapis.com/auth/drive.file\",
          discoveryDocs: [\"https://sheets.googleapis.com/$discovery/rest?version=v4\"]
        }).then(function () {
          gapi.auth2.getAuthInstance().isSignedIn.listen(updateSignInStatus);
          updateSignInStatus(gapi.auth2.getAuthInstance().isSignedIn.get());
        });
      });
    });
  }

  async function updateSignInStatus(isSignedIn) {
    if (isSignedIn) {
      await gapi.client.sheets.spreadsheets.create({
        properties: {
          title: #{table_name.inspect},
        },
        sheets: [
          // sheet1, sheet2, sheet3
        ]
      }).then(function (response) {
        sheetUrl = response.result.spreadsheetUrl;
        spreadsheetId = response.result.spreadsheetId;
        sheetsLink.setAttribute(\"href\", sheetUrl); // response.result.spreadsheetUrl
        console.log(\"x1\", sheetUrl);

        // Get JSON data
        fetch(changeout(<%= #{table_name}_path(format: :js).inspect.html_safe %>, \"_brick_schema\", brickSchema)).then(function (response) {
          response.json().then(function (data) {
            gapi.client.sheets.spreadsheets.values.append({
              spreadsheetId: spreadsheetId,
              range: \"Sheet1\",
              valueInputOption: \"RAW\",
              insertDataOption: \"INSERT_ROWS\"
            }, {
              range: \"Sheet1\",
              majorDimension: \"ROWS\",
              values: data,
            }).then(function (response2) {
  //            console.log(\"beefcake\", response2);
            });
          });
        });
      });
      window.open(sheetUrl, '_blank');
    }
  }
</script>
<script async defer src=\"https://apis.google.com/js/api.js\" onload=\"gapiLoaded()\"></script>
"
                         end
# %%% Instead of our current "for Janet Leverling (Employee)" kind of link we previously had this code that did a "where x = 123" thing:
#   (where <%= @_brick_params.each_with_object([]) { |v, s| s << \"#\{v.first\} = #\{v.last.inspect\}\" }.join(', ') %>)
"#{css}
<p style=\"color: green\"><%= notice %></p>#{"
<select id=\"schema\">#{schema_options}</select>" if ::Brick.config.schema_behavior[:multitenant] && ::Brick.db_schemas.length > 1}
<select id=\"tbl\">#{table_options}</select>
<h1>#{model_plural = model_name.pluralize}</h1>#{template_link}<%
   if (description = (relation = Brick.relations[#{model_name}.table_name])&.fetch(:description, nil)) %><%=
     description %><br><%
   end
   if @_brick_params&.present? %>
  <% if @_brick_params.length == 1 # %%% Does not yet work with composite keys
       k, id = @_brick_params.first
       id = id.first if id.is_a?(Array) && id.length == 1
       origin = (key_parts = k.split('.')).length == 1 ? #{model_name} : #{model_name}.reflect_on_association(key_parts.first).klass
       if (destination_fk = Brick.relations[origin.table_name][:fks].values.find { |fk| puts fk.inspect; fk[:fk] == key_parts.last }) &&
          (obj = (destination = origin.reflect_on_association(destination_fk[:assoc_name])&.klass)&.find(id)) %>
         <h3>for <%= link_to \"#{"#\{obj.brick_descrip\} (#\{destination.name\})\""}, send(\"#\{destination.name.underscore.tr('/', '_')\}_path\".to_sym, id) %></h3><%
       end
     end %>
  (<%= link_to 'See all #{model_plural.split('::').last}', #{path_obj_name.pluralize}_path %>)
<% end %>
<br>
<table id=\"headerTop\">
<table id=\"#{table_name}\">
  <thead><tr>#{'<th></th>' if pk.present?}<%
     col_order = []
     @#{table_name}.columns.each do |col|
       col_name = col.name
       next if (#{(pk || []).inspect}.include?(col_name) && col.type == :integer && !bts.key?(col_name)) ||
               ::Brick.config.metadata_columns.include?(col_name) || poly_cols.include?(col_name)

       col_order << col_name
    %><th<%= \" title = \\\"#\{col.comment}\\\"\".html_safe if col.respond_to?(:comment) && !col.comment.blank? %>><%
       if (bt = bts[col_name]) %>
         BT <%
         bt[1].each do |bt_pair| %><%=
           bt_pair.first.bt_link(bt.first) %> <%
         end %><%
       else %><%=
         col_name %><%
       end
  %></th><%
     end
     # Consider getting the name from the association -- h.first.name -- if a more \"friendly\" alias should be used for a screwy table name
  %>#{hms_headers.map do |h|
        if h.first.options[:through] && !h.first.through_reflection
    "<th>#{h[1]} #{h[2]} %></th>" # %%% Would be able to remove this when multiple foreign keys to same destination becomes bulletproof
        else
    "<th>#{h[1]} <%= link_to('#{h[2]}', #{h.first.klass.name.underscore.tr('/', '_').pluralize}_path) %></th>"
        end
      end.join
  }</tr></thead>

  <tbody>
  <% @#{table_name}.each do |#{obj_name}| %>
  <tr>#{"
    <td><%= link_to '⇛', #{path_obj_name}_path(#{obj_pk}), { class: 'big-arrow' } %></td>" if obj_pk}
    <% col_order.each do |col_name|
         val = #{obj_name}.attributes[col_name] %>
      <td>
      <% if (bt = bts[col_name]) %>
        <% if bt[2] # Polymorphic?
             bt_class = #{obj_name}.send(\"#\{bt.first\}_type\")
             base_class = (::Brick.existing_stis[bt_class] || bt_class).constantize.base_class.name.underscore
             poly_id = #{obj_name}.send(\"#\{bt.first\}_id\")
             %><%= link_to(\"#\{bt_class\} ##\{poly_id\}\",
                           send(\"#\{base_class\}_path\".to_sym, poly_id)) if poly_id %><%
           else
             bt_txt = (bt_class = bt[1].first.first).brick_descrip(
               # 0..62 because Postgres column names are limited to 63 characters
               #{obj_name}, (descrips = @_brick_bt_descrip[bt.first][bt_class])[0..-2].map { |z| #{obj_name}.send(z.last[0..62]) }, (bt_id_col = descrips.last)
             )
             bt_txt ||= \"<< Orphaned ID: #\{val} >>\" if val
             bt_id = #{obj_name}.send(*bt_id_col) if bt_id_col&.present? %>
          <%= bt_id ? link_to(bt_txt, send(\"#\{bt_class.base_class.name.underscore.tr('/', '_')\}_path\".to_sym, bt_id)) : bt_txt %>
          <%#= Previously was:  bt_obj = bt[1].first.first.find_by(bt[2] => val); link_to(bt_obj.brick_descrip, send(\"#\{bt[1].first.first.name.underscore\}_path\".to_sym, bt_obj.send(bt[1].first.first.primary_key.to_sym))) if bt_obj %>
        <% end %>
      <% else %>
        <%= hide_bcrypt(val) %>
      <% end %>
      </td>
    <% end %>
    #{hms_columns.each_with_object(+'') { |hm_col, s| s << "<td>#{hm_col}</td>" }}
  </tr>
  <% end %>
  </tbody>
</table>

#{"<hr><%= link_to \"New #{obj_name}\", new_#{path_obj_name}_path %>" unless @_brick_model.is_view?}
#{script}"
                       when 'orphans'
                         if is_orphans
"#{css}
<p style=\"color: green\"><%= notice %></p>#{"
<select id=\"schema\">#{schema_options}</select>" if ::Brick.config.schema_behavior[:multitenant] && ::Brick.db_schemas.length > 1}
<select id=\"tbl\">#{table_options}</select>
<h1>Orphans<%= \" for #\{}\" if false %></h1>
<% @orphans.each do |o|
  via = \" (via #\{o[4]})\" unless \"#\{o[2].split('.').last.underscore.singularize}_id\" == o[4] %>
  <a href=\"/<%= o[0].split('.').last %>/<%= o[1] %>\">
    <%= \"#\{o[0]} #\{o[1]} refers#\{via} to non-existent #\{o[2]} #\{o[3]}#\{\" (in table \\\"#\{o[5]}\\\")\" if o[5]}\" %>
  </a><br>
<% end %>
#{script}"
                         end

                       when 'show', 'update'
"#{css}
<p style=\"color: green\"><%= notice %></p>#{"
<select id=\"schema\">#{schema_options}</select>" if ::Brick.config.schema_behavior[:multitenant] && ::Brick.db_schemas.length > 1}
<select id=\"tbl\">#{table_options}</select>
<h1>#{model_name}: <%= (obj = @#{obj_name})&.brick_descrip || controller_name %></h1><%
if (description = (relation = Brick.relations[#{model_name}.table_name])&.fetch(:description, nil)) %><%=
  description %><br><%
end
%><%= link_to '(See all #{obj_name.pluralize})', #{path_obj_name.pluralize}_path %>
<% if obj %>
  <br><br>
  <%= # path_options = [obj.#{pk}]
    # path_options << { '_brick_schema':  } if
    # url = send(:#{model_name.underscore}_path, obj.#{pk})
    form_for(obj.becomes(#{model_name})) do |f| %>
  <table>
  <% has_fields = false
    @#{obj_name}.attributes.each do |k, val|
      col = #{model_name}.columns_hash[k] %>
    <tr>
    <% next if (#{(pk || []).inspect}.include?(k) && !bts.key?(k)) ||
               ::Brick.config.metadata_columns.include?(k) %>
    <th class=\"show-field\"<%= \" title = \\\"#\{col.comment}\\\"\".html_safe if col.respond_to?(:comment) && !col.comment.blank? %>>
    <% has_fields = true
      if (bt = bts[k])
        # Add a final member in this array with descriptive options to be used in <select> drop-downs
        bt_name = bt[1].map { |x| x.first.name }.join('/')
        # %%% Only do this if the user has permissions to edit this bt field
        if bt[2] # Polymorphic?
          poly_class_name = orig_poly_name = @#{obj_name}.send(\"#\{bt.first\}_type\")
          bt_pair = nil
          loop do
            bt_pair = bt[1].find { |pair| pair.first.name == poly_class_name }
            # Acxommodate any valid STI by going up the chain of inheritance
            break unless bt_pair.nil? && poly_class_name = ::Brick.existing_stis[poly_class_name]
          end
          puts \"*** Might be missing an STI class called #\{orig_poly_name\} whose base class should have this:
***   has_many :#{table_name}, as: :#\{bt.first\}
*** Can probably auto-configure everything using these lines in an initialiser:
***   Brick.sti_namespace_prefixes = { '::#\{orig_poly_name\}' => 'SomeParentModel' }
***   Brick.polymorphics = { '#{table_name}.#\{bt.first\}' => ['SomeParentModel'] }\" if bt_pair.nil?
          # descrips = @_brick_bt_descrip[bt.first][bt_class]
          poly_id = @#{obj_name}.send(\"#\{bt.first\}_id\")
          # bt_class.order(obj_pk = bt_class.primary_key).each { |obj| option_detail << [obj.brick_descrip(nil, obj_pk), obj.send(obj_pk)] }
        else # No polymorphism, so just get the first one
          bt_pair = bt[1].first
        end
        bt_class = bt_pair&.first
        if bt.length < 4
          bt << (option_detail = [[\"(No #\{bt_name\} chosen)\", '^^^brick_NULL^^^']])
          # %%% Accommodate composite keys for obj.pk at the end here
          bt_class&.order(obj_pk = bt_class.primary_key)&.each { |obj| option_detail << [obj.brick_descrip(nil, obj_pk), obj.send(obj_pk)] }
        end %>
        BT <%= bt_class&.bt_link(bt.first) || orig_poly_name %>
    <% else %>
      <%= k %>
    <% end %>
    </th>
    <td>
    <% if bt
      html_options = { prompt: \"Select #\{bt_name\}\" }
      html_options[:class] = 'dimmed' unless val %>
      <%= f.select k.to_sym, bt[3], { value: val || '^^^brick_NULL^^^' }, html_options %>
      <%= if (bt_obj = bt_class&.find_by(bt_pair[1] => val))
            link_to('⇛', send(\"#\{bt_class.base_class.name.underscore.tr('/', '_')\}_path\".to_sym, bt_obj.send(bt_class.primary_key.to_sym)), { class: 'show-arrow' })
          elsif val
            \"Orphaned ID: #\{val}\"
          end %>
    <% else case #{model_name}.column_for_attribute(k).type
      when :string, :text %>
        <% if is_bcrypt?(val) # || .readonly? %>
          <%= hide_bcrypt(val, 1000) %>
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
  <% end
  if has_fields %>
    <tr><td colspan=\"2\" class=\"right\"><%= f.submit %></td></tr>
  <% else %>
    <tr><td colspan=\"2\">(No displayable fields)</td></tr>
  <% end %>
  </table>
  <% end %>

  #{hms_headers.each_with_object(+'') do |hm, s|
    # %%% Would be able to remove this when multiple foreign keys to same destination becomes bulletproof
    next if hm.first.options[:through] && !hm.first.through_reflection

    if (pk = hm.first.klass.primary_key)
      hm_singular_name = (hm_name = hm.first.name.to_s).singularize.underscore
      obj_pk = (pk.is_a?(Array) ? pk : [pk]).each_with_object([]) { |pk_part, s| s << "#{hm_singular_name}.#{pk_part}" }.join(', ')
      s << "<table id=\"#{hm_name}\">
        <tr><th>#{hm[3]}</th></tr>
        <% collection = @#{obj_name}.#{hm_name}
        collection = collection.is_a?(ActiveRecord::Associations::CollectionProxy) ? collection.order(#{pk.inspect}) : [collection].compact
        if collection.empty? %>
          <tr><td>(none)</td></tr>
        <% else %>
          <% collection.uniq.each do |#{hm_singular_name}| %>
            <tr><td><%= link_to(#{hm_singular_name}.brick_descrip, #{hm.first.klass.name.underscore.tr('/', '_')}_path([#{obj_pk}])) %></td></tr>
          <% end %>
        <% end %>
      </table>"
    else
      s
    end
  end}
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
        # go make sure we've loaded additional references (virtual foreign keys and polymorphic associations).
        # (This should only happen if for whatever reason the initializer file was not exactly config/initializers/brick.rb.)
        ::Brick.load_additional_references
      end
    end
  end
end
