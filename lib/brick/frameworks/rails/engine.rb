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

        # When table names have specific prefixes, automatically place them in their own module with a table_name_prefix.
        ::Brick.order = app.config.brick.fetch(:order, {})

        # Skip creating a has_many association for these
        ::Brick.exclude_hms = app.config.brick.fetch(:exclude_hms, nil)

        # Has one relationships
        ::Brick.has_ones = app.config.brick.fetch(:has_ones, nil)

        # Polymorphic associations
        ::Brick.polymorphics = app.config.brick.fetch(:polymorphics, nil)
      end

      # After we're initialized and before running the rest of stuff, put our configuration in place
      ActiveSupport.on_load(:after_initialize) do |app|
        assets_path = File.expand_path("#{__dir__}/../../../../vendor/assets")
        (app.config.assets.precompile ||= []) << "#{assets_path}/images/brick_erd.png"
        (app.config.assets.paths ||= []) << assets_path
        # ====================================
        # Dynamically create generic templates
        # ====================================
        if ::Brick.enable_views?
          ActionView::LookupContext.class_exec do
            # Used by Rails 5.0 and above
            alias :_brick_template_exists? :template_exists?
            def template_exists?(*args, **options)
              (::Brick.config.add_status && args.first == 'status') ||
              (::Brick.config.add_orphans && args.first == 'orphans') ||
              _brick_template_exists?(*args, **options) ||
              # Do not auto-create a template when it's searching for an application.html.erb, which comes in like:  ["edit", ["games", "application"]]
              ((args[1].length == 1 || args[1][-1] != 'application') &&
               set_brick_model(args))
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
              unless (model_name = @_brick_model&.name) ||
                     (is_status = ::Brick.config.add_status && args[0..1] == ['status', ['brick_gem']]) ||
                     (is_orphans = ::Brick.config.add_orphans && args[0..1] == ['orphans', ['brick_gem']]) ||
                     # Used to also have:  ActionView.version < ::Gem::Version.new('5.0') &&
                     (model_name = (args[1].is_a?(Array) ? set_brick_model(args) : nil)&.name)
                return _brick_find_template(*args, **options)
              end

            if @_brick_model
                pk = @_brick_model._brick_primary_key(::Brick.relations.fetch(model_name, nil))
                obj_name = model_name.split('::').last.underscore
                path_obj_name = model_name.underscore.tr('/', '_')
                table_name = obj_name.pluralize
                template_link = nil
                bts, hms = ::Brick.get_bts_and_hms(@_brick_model) # This gets BT and HM and also has_many :through (HMT)
                hms_columns = [] # Used for 'index'
                skip_klass_hms = ::Brick.config.skip_index_hms[model_name] || {}
                hms_headers = hms.each_with_object([]) do |hm, s|
                  hm_stuff = [(hm_assoc = hm.last),
                              "H#{hm_assoc.macro == :has_one ? 'O' : 'M'}#{'T' if hm_assoc.options[:through]}",
                              (assoc_name = hm.first)]
                  hm_fk_name = if (through = hm_assoc.options[:through])
                                 next unless @_brick_model.instance_methods.include?(through)

                                 associative = @_brick_model._br_associatives[hm.first]
                                 tbl_nm = if hm_assoc.options[:source]
                                            associative.klass.reflect_on_association(hm_assoc.options[:source]).inverse_of&.name
                                          else
                                            associative.name
                                          end
                                 # If there is no inverse available for the source belongs_to association, make one based on the class name
                                 unless tbl_nm
                                   tbl_nm = associative.class_name.underscore
                                   tbl_nm.slice!(0) if tbl_nm[0] == ('/')
                                   tbl_nm = tbl_nm.tr('/', '_').pluralize
                                 end
                                 "'#{tbl_nm}.#{associative.foreign_key}'"
                               else
                                 hm_assoc.foreign_key
                               end
                  case args.first
                  when 'index'
                    hm_entry = +"'#{hm_assoc.name}' => [#{assoc_name.inspect}"
                    hm_entry << if hm_assoc.macro == :has_many
                                   if hm_fk_name # %%% Can remove this check when multiple foreign keys to same destination becomes bulletproof
                                     set_ct = if skip_klass_hms.key?(assoc_name.to_sym)
                                                 'nil'
                                               else
                                                 # Postgres column names are limited to 63 characters
                                                 "#{obj_name}.#{"_br_#{assoc_name}_ct"[0..62]} || 0"
                                               end
                                     ", #{set_ct}, #{path_keys(hm_assoc, hm_fk_name, obj_name, pk)}"
                                   end
                                 else # has_one
                                   # 0..62 because Postgres column names are limited to 63 characters
                                   ", nil, #{path_keys(hm_assoc, hm_fk_name, obj_name, pk)}"
                                 end
                    hm_entry << ']'
                    hms_columns << hm_entry
                  when 'show', 'new', 'update'
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
              apartment_default_schema = ::Brick.apartment_multitenant && Apartment.default_schema
              table_options = (::Brick.relations.keys - ::Brick.config.exclude_tables).each_with_object({}) do |tbl, s|
                                if (tbl_parts = tbl.split('.')).first == apartment_default_schema
                                  tbl = tbl_parts.last
                                end
                                s[tbl] = nil
                              end.keys.sort.each_with_object(+'') do |v, s|
                                s << "<option value=\"#{v.underscore.gsub('.', '/').pluralize}\">#{v}</option>"
                              end.html_safe
              table_options << '<option value="brick_status">(Status)</option>'.html_safe if ::Brick.config.add_status
              table_options << '<option value="brick_orphans">(Orphans)</option>'.html_safe if is_orphans
              css = +"<style>
h1, h3 {
  margin-bottom: 0;
}
#imgErd {
  background-image:url(/assets/brick_erd.png);
  background-size: 100% 100%;
  width: 2.2em;
  height: 2.2em;
  cursor: pointer;
}
#mermaidErd {
  position: relative;
  display: none;
}
#mermaidErd .exclude {
  position: absolute;
  color: red;
  top: 0;
  right: 0;
  cursor: pointer;
}
.relatedModel {
  cursor: pointer;
}

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
}
table.shadow {
  min-width: 400px;
  box-shadow: 0 0 20px rgba(0, 0, 0, 0.15);
}

tr th {
  background-color: #009879;
  color: #fff;
  text-align: left;
}
#headerTop tr th {
  position: relative;
}
#headerTop tr th .exclude {
  position: absolute;
  display: none;
  top: 0;
  right: 0;
  cursor: pointer;
}
#headerTop tr th:hover {
  background-color: #18B090;
}
#exclusions {
  font-size: 0.7em;
}
#exclusions div {
  border: 1px solid blue;
  display: inline-block;
  cursor: copy;
}
#headerTop tr th:hover .exclude {
  display: inline;
  cursor: pointer;
  color: red;
}
tr th a {
  color: #80FFB8;
}

tr th, tr td {
  padding: 0.2em 0.5em;
}

.show-field {
  background-color: #004998;
}
.show-field a {
  color: #80B8D2;
}

table.shadow > tbody > tr {
  border-bottom: thin solid #dddddd;
}

table tbody tr:nth-of-type(even) {
  background-color: #f3f3f3;
}

table.shadow > tbody > tr:last-of-type {
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
.dimmed {
  background-color: #C0C0C0;
  text-align: center;
}
.orphan {
  color: red;
  white-space: nowrap;
}

#revertTemplate {
  display: none;
}
svg.revert {
  display: none;
  margin-left: 0.25em;
}
input+svg.revert {
  top: 0.5em;
}

.update {
  position: sticky;
  right: 1em;
  float: right;
  background-color: #004998;
  color: #FFF;
}
</style>

<% is_includes_dates = nil
def is_bcrypt?(val)
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
end
def display_value(col_type, val)
  case col_type
  when 'geometry'
    if Object.const_defined?('RGeo')
      @is_mysql = ActiveRecord::Base.connection.adapter_name == 'Mysql2' if @is_mysql.nil?
      if @is_mysql
        # MySQL's \"Internal Geometry Format\" is like WKB, but with an initial 4 bytes that indicates the SRID.
        srid = val[0..3].unpack('I')
        val = val[4..-1]
      end
      RGeo::WKRep::WKBParser.new.parse(val)
    else
      '(Add RGeo gem to parse geometry detail)'
    end
  else
    if col_type
      hide_bcrypt(val)
    else
      '?'
    end
  end
end
callbacks = {} %>"

              if ['index', 'show', 'new', 'update'].include?(args.first)
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
    var i = schemaSelect ? 1 : 0,
        changeoutList = changeout(location.href);
    for (; i < changeoutList.length; ++i) {
      tblSelect.value = changeoutList[i];
      if (tblSelect.value !== \"\") break;
    }

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
  var params = hrefParts.length > 1 ? hrefParts[1].split(\"&\") : [];
  if (param === undefined || param === null || param === -1) {
    hrefParts = hrefParts[0].split(\"://\");
    var pathParts = hrefParts[hrefParts.length - 1].split(\"/\");
    if (value === undefined)
      // A couple possibilities if it's namespaced, starting with two parts in the path -- and then try just one
      return [pathParts.slice(1, 3).join('/'), pathParts.slice(1, 2)[0]];
    else {
      var queryString = param ? \"?\" + params.join(\"&\") : \"\";
      return hrefParts[0] + \"://\" + pathParts[0] + \"/\" + value + queryString;
    }
  }
  if (trimAfter) {
    var pathParts = hrefParts[0].split(\"/\");
    while (pathParts.lastIndexOf(trimAfter) !== pathParts.length - 1) pathParts.pop();
    hrefParts[0] = pathParts.join(\"/\");
  }
  params = params.reduce(function (s, v) { var parts = v.split(\"=\"); if (parts[1]) s[parts[0]] = parts[1]; return s; }, {});
  if (value === undefined) return params[param];
  params[param] = value;
  var finalParams = Object.keys(params).reduce(function (s, v) { if (params[v]) s.push(v + \"=\" + params[v]); return s; }, []).join(\"&\");
  return hrefParts[0] + (finalParams.length > 0 ? \"?\" + finalParams : \"\");
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
        var th = tr.childNodes[i];
        th.style.minWidth = th.style.maxWidth = getComputedStyle(node).width;
        if (#{pk&.present? ? 'i > 0' : 'true'}) {
          // Add <span> at the end
          var span = document.createElement(\"SPAN\");
          span.className = \"exclude\";
          span.innerHTML = \"X\";
          span.addEventListener(\"click\", function (e) {
            e.stopPropagation();
            doFetch(\"POST\", {_brick_exclude: this.parentElement.getAttribute(\"x-order\")});
          });
          th.appendChild(span);
        }
      }
    }
    if (isEmpty) headerTop.appendChild(tr);
  }
  grid.style.marginTop = \"-\" + getComputedStyle(headerTop).height;
  // console.log(\"end\");
}
function doFetch(method, payload, success) {
  payload.authenticity_token = <%= session[:_csrf_token].inspect.html_safe %>;
  if (!success) {
    success = function (p) {p.text().then(function (response) {
      var result = JSON.parse(response).result;
      if (result) location.href = location.href;
    });};
  }
  var options = {method: method, headers: {\"Content-Type\": \"application/json\"}};
  if (payload) options.body = JSON.stringify(payload);
  return fetch(location.href, options).then(success);
}
if (headerTop) {
  setHeaderSizes();
  window.addEventListener('resize', function(event) {
    setHeaderSizes();
  }, true);
}
</script>"

              erd_markup = if @_brick_model
                             "<div id=\"mermaidErd\" class=\"mermaid\">
erDiagram
<% model_short_name = #{@_brick_model.name.split('::').last.inspect}
   @_brick_bt_descrip&.each do |bt|
     bt_class = bt[1].first.first
     callbacks[bt_name = bt_class.name.split('::').last] = bt_class
     is_has_one = #{@_brick_model.name}.reflect_on_association(bt.first).inverse_of&.macro == :has_one ||
                  ::Brick.config.has_ones&.fetch('#{@_brick_model.name}', nil)&.key?(bt.first.to_s)
    %>  <%= \"#\{model_short_name} #\{is_has_one ? '||' : '}o'}--|| #\{bt_name} : \\\"#\{
        bt_underscored = bt[1].first.first.name.underscore.singularize
        bt.first unless bt.first.to_s == bt_underscored.split('/').last # Was:  bt_underscored.tr('/', '_')
        }\\\"\".html_safe %>
<% end
   last_through = nil
   @_brick_hm_counts&.each do |hm|
     # Skip showing self-referencing HM links since they would have already been drawn while evaluating the BT side
     next if (hm_class = hm.last&.klass) == #{@_brick_model.name}

     callbacks[hm_name = hm_class.name.split('::').last] = hm_class
     if (through = hm.last.options[:through]&.to_s) # has_many :through  (HMT)
       through_name = (through_assoc = hm.last.source_reflection).active_record.name.split('::').last
       callbacks[through_name] = through_assoc.active_record
       if last_through == through # Same HM, so no need to build it again, and for clarity just put in a blank line
%><%=    \"\n\"
%><%   else
%>  <%= \"#\{model_short_name} ||--o{ #\{through_name}\".html_safe %> : \"\"
<%       last_through = through
       end
%>    <%= \"#\{through_name} }o--|| #\{hm_name}\".html_safe %> : \"\"
    <%= \"#\{model_short_name} }o..o{ #\{hm_name} : \\\"#\{hm.first}\\\"\".html_safe %><%
     else # has_many
%>  <%= \"#\{model_short_name} ||--o{ #\{hm_name} : \\\"#\{
            hm_name unless hm.first.to_s == hm_class.name.underscore.pluralize.tr('/', '_')
          }\\\"\".html_safe %><%
     end %>
<% end
   def dt_lookup(dt)
     { 'integer' => 'int', }[dt] || dt&.tr(' ', '_') || 'int'
   end
   callbacks.merge({model_short_name => #{@_brick_model.name}}).each do |cb_k, cb_class|
     cb_relation = ::Brick.relations[cb_class.table_name]
     pkeys = cb_relation[:pkey]&.first&.last
     fkeys = cb_relation[:fks]&.values&.each_with_object([]) { |fk, s| s << fk[:fk] if fk.fetch(:is_bt, nil) }
     cols = cb_relation[:cols]
 %>  <%= cb_k %> {<%
     pkeys&.each do |pk| %>
    <%= \"#\{dt_lookup(cols[pk].first)} #\{pk} \\\"PK#\{' fk' if fkeys&.include?(pk)}\\\"\".html_safe %><%
     end %><%
     fkeys&.each do |fk|
       if fk.is_a?(Array)
         fk.each do |fk_part| %>
    <%= \"#\{dt_lookup(cols[fk_part].first)} #\{fk_part} \\\"&nbsp;&nbsp;&nbsp;&nbsp;fk\\\"\".html_safe unless pkeys&.include?(fk_part) %><%
         end
       else # %%% Does not yet accommodate polymorphic BTs
    %>
    <%= \"#\{dt_lookup(cols[fk]&.first)} #\{fk} \\\"&nbsp;&nbsp;&nbsp;&nbsp;fk\\\"\".html_safe unless pkeys&.include?(fk) %><%
       end
     end %>
  }
<% end
 # callback < %= cb_k % > erdClick
 %>
</div>
"
                           end
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
        method: \"PATCH\",
        headers: { \"Content-Type\": \"text/tab-separated-values\" },
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
                         end # DutyFree data export and import
# %%% Instead of our current "for Janet Leverling (Employee)" kind of link we previously had this code that did a "where x = 123" thing:
#   (where <%= @_brick_params.each_with_object([]) { |v, s| s << \"#\{v.first\} = #\{v.last.inspect\}\" }.join(', ') %>)
+"#{css}
<p style=\"color: green\"><%= notice %></p>#{"
<select id=\"schema\">#{schema_options}</select>" if ::Brick.config.schema_behavior[:multitenant] && ::Brick.db_schemas.length > 1}
<select id=\"tbl\">#{table_options}</select>
<table id=\"resourceName\"><tr>
  <td><h1>#{model_plural = model_name.pluralize}</h1></td>
  <td id=\"imgErd\" title=\"Show ERD\"></td>
</tr></table>#{template_link}<%
   if (description = (relation = Brick.relations[#{model_name}.table_name])&.fetch(:description, nil)) %><%=
     description %><br><%
   end
   # FILTER PARAMETERS
   if @_brick_params&.present? %>
  <% if @_brick_params.length == 1 # %%% Does not yet work with composite keys
       k, id = @_brick_params.first
       id = id.first if id.is_a?(Array) && id.length == 1
       origin = (key_parts = k.split('.')).length == 1 ? #{model_name} : #{model_name}.reflect_on_association(key_parts.first).klass
       if (destination_fk = Brick.relations[origin.table_name][:fks].values.find { |fk| fk[:fk] == key_parts.last }) &&
          (obj = (destination = origin.reflect_on_association(destination_fk[:assoc_name])&.klass)&.find(id)) %>
         <h3>for <%= link_to \"#{"#\{obj.brick_descrip\} (#\{destination.name\})\""}, send(\"#\{destination.name.underscore.tr('/', '_')\}_path\".to_sym, id) %></h3><%
       end
     end %>
  (<%= link_to 'See all #{model_plural.split('::').last}', #{path_obj_name.pluralize}_path %>)
<% end
   # COLUMN EXCLUSIONS
   if @_brick_excl&.present? %>
  <div id=\"exclusions\">Excluded columns:
  <% @_brick_excl.each do |excl| %>
    <div class=\"colExclusion\"><%= excl %></div>
  <% end %>
  </div>
  <script>
    [... document.getElementsByClassName(\"colExclusion\")].forEach(function (excl) {
      excl.addEventListener(\"click\", function () {
        doFetch(\"POST\", {_brick_unexclude: this.innerHTML});
      });
    });
  </script>
<% end %>
#{erd_markup}
<table id=\"headerTop\"></table>
<table id=\"#{table_name}\" class=\"shadow\">
  <thead><tr>#{"<th x-order=\"#{pk.join(',')}\"></th>" if pk.present?}<%=
     # Consider getting the name from the association -- hm.first.name -- if a more \"friendly\" alias should be used for a screwy table name
     cols = {#{hms_keys = []
               hms_headers.map do |hm|
                 hms_keys << (assoc_name = (assoc = hm.first).name.to_s)
                 "#{assoc_name.inspect} => [#{(assoc.options[:through] && !assoc.through_reflection).inspect}, #{assoc.klass.name}, #{hm[1].inspect}, #{hm[2].inspect}]"
               end.join(', ')}}
     col_keys = @#{table_name}.columns.each_with_object([]) do |col, s|
       col_name = col.name
       next if @_brick_incl&.exclude?(col_name) ||
               (#{(pk || []).inspect}.include?(col_name) && col.type == :integer && !bts.key?(col_name)) ||
               ::Brick.config.metadata_columns.include?(col_name) || poly_cols.include?(col_name)

       s << col_name
       cols[col_name] = col
     end
     unless @_brick_sequence # If no sequence is defined, start with all inclusions
       @_brick_sequence = col_keys + #{(hms_keys).inspect}.reject { |assoc_name| @_brick_incl&.exclude?(assoc_name) }
     end
     @_brick_sequence.reject! { |nm| @_brick_excl.include?(nm) } if @_brick_excl # Reject exclusions
     @_brick_sequence.each_with_object(+'') do |col_name, s|
       if (col = cols[col_name]).is_a?(ActiveRecord::ConnectionAdapters::Column)
         s << '<th'
         s << \" title=\\\"#\{col.comment}\\\"\" if col.respond_to?(:comment) && !col.comment.blank?
         s << if (bt = bts[col_name])
                # Allow sorting for any BT except polymorphics
                \"#\{' x-order=\"' + bt.first.to_s + '\"' unless bt[2]}>BT \" +
                bt[1].map { |bt_pair| bt_pair.first.bt_link(bt.first) }.join(' ')
              else # Normal column
                \"#\{' x-order=\"' + col_name + '\"' if true}>#\{col_name}\"
              end
       elsif col # HM column
         s << \"<th#\{' x-order=\"' + col_name + '\"' if true}>#\{col[2]} \"
         s << (col.first ? \"#\{col[3]}\" : \"#\{link_to(col[3], send(\"#\{col[1].name.underscore.tr('/', '_').pluralize}_path\"))}\")
       else # Bad column name!
         s << \"<th title=\\\"<< Unknown column >>\\\">#\{col_name}\"
       end
       s << '</th>'
     end.html_safe
  %></tr></thead>
  <tbody>
  <% @#{table_name}.each do |#{obj_name}|
       hms_cols = {#{hms_columns.join(', ')}} %>
  <tr>#{"
    <td><%= link_to '⇛', #{path_obj_name}_path(#{obj_pk}), { class: 'big-arrow' } %></td>" if obj_pk}
    <% @_brick_sequence.each do |col_name|
         val = #{obj_name}.attributes[col_name] %>
      <td<%= ' class=\"dimmed\"'.html_safe unless cols.key?(col_name)%>><%
         if (bt = bts[col_name])
           if bt[2] # Polymorphic?
             bt_class = #{obj_name}.send(\"#\{bt.first\}_type\")
             base_class = (::Brick.existing_stis[bt_class] || bt_class).constantize.base_class.name.underscore
             poly_id = #{obj_name}.send(\"#\{bt.first\}_id\")
             %><%= link_to(\"#\{bt_class\} ##\{poly_id\}\", send(\"#\{base_class\}_path\".to_sym, poly_id)) if poly_id %><%
           else
             bt_txt = (bt_class = bt[1].first.first).brick_descrip(
               # 0..62 because Postgres column names are limited to 63 characters
               #{obj_name}, (descrips = @_brick_bt_descrip[bt.first][bt_class])[0..-2].map { |id| #{obj_name}.send(id.last[0..62]) }, (bt_id_col = descrips.last)
             )
             bt_txt ||= \"<span class=\\\"orphan\\\">&lt;&lt; Orphaned ID: #\{val} >></span>\".html_safe if val
             bt_id = bt_id_col.map { |id_col| #{obj_name}.send(id_col.to_sym) } %>
          <%= bt_id&.first ? link_to(bt_txt, send(\"#\{bt_class.base_class.name.underscore.tr('/', '_')\}_path\".to_sym, bt_id)) : bt_txt %>
        <% end
         elsif (hms_col = hms_cols[col_name])
           if hms_col.length == 1 %>
        <%=  hms_col.first %>
        <% else
             klass = (col = cols[col_name])[1]
             txt = if col[2] == 'HO'
                     descrips = @_brick_bt_descrip[col_name.to_sym][klass]
                     ho_txt = klass.brick_descrip(#{obj_name}, descrips[0..-2].map { |id| #{obj_name}.send(id.last[0..62]) }, (ho_id_col = descrips.last))
                     ho_id = ho_id_col.map { |id_col| #{obj_name}.send(id_col.to_sym) }
                     ho_id&.first ? link_to(ho_txt, send(\"#\{klass.base_class.name.underscore.tr('/', '_')\}_path\".to_sym, ho_id)) : ho_txt
                   else
                     \"#\{hms_col[1] || 'View'\} #\{hms_col.first}\"
                   end %>
         <%= link_to txt, send(\"#\{klass.name.underscore.tr('/', '_').pluralize}_path\".to_sym, hms_col[2]) unless hms_col[1]&.zero? %>
        <% end
         elsif (col = cols[col_name])
    %><%=  display_value(col&.type || col&.sql_type, val) %><%
         else # Bad column name!
      %>?<%
         end
    %></td>
    <% end %>
  </tr>
  <% end %>
  </tbody>
</table>

#{"<hr><%= link_to \"New #{obj_name}\", new_#{path_obj_name}_path %>" unless @_brick_model.is_view?}
#{script}"

                       when 'status'
                         if is_status
# Status page - list of all resources and 5 things they do or don't have present, and what is turned on and off
# Must load all models, and then find what table names are represented
# Easily could be multiple files involved (STI for instance)
+"#{css}
<p style=\"color: green\"><%= notice %></p>#{"
<select id=\"schema\">#{schema_options}</select>" if ::Brick.config.schema_behavior[:multitenant] && ::Brick.db_schemas.length > 1}
<select id=\"tbl\">#{table_options}</select>
<h1>Status</h1>
<table id=\"status\" class=\"shadow\"><thead><tr>
  <th>Resource</th>
  <th>Table</th>
  <th>Migration</th>
  <th>Model</th>
  <th>Route</th>
  <th>Controller</th>
  <th>Views</th>
</tr></thead>
<tbody>
<% # (listing in schema.rb)
   # Solid colour if file or route entry is present
  @resources.each do |r|
  %>
  <tr>
  <td><%= link_to(r[0], \"/#\{r[0].underscore.tr('.', '/')}\") %></td>
  <td<%= if r[1]
           ' class=\"orphan\"' unless ::Brick.relations.key?(r[1])
         else
           ' class=\"dimmed\"'
         end&.html_safe %>><%= # Table
          r[1] %></td>
  <td<%= ' class=\"dimmed\"'.html_safe unless r[2] %>><%= # Migration
          r[2]&.join('<br>')&.html_safe %></td>
  <td<%= ' class=\"dimmed\"'.html_safe unless r[3] %>><%= # Model
          r[3] %></td>
  <td<%= ' class=\"dimmed\"'.html_safe unless r[4] %>><%= # Route
               %></td>
  <td<%= ' class=\"dimmed\"'.html_safe unless r[5] %>><%= # Controller
               %></td>
  <td<%= ' class=\"dimmed\"'.html_safe unless r[6] %>><%= # Views
               %></td>
  <tr>
<% end %>
</tbody></table>
#{script}"
                         end

                       when 'orphans'
                         if is_orphans
+"#{css}
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

                       when 'show', 'new', 'update'
+"#{css}

<svg id=\"revertTemplate\" version=\"1.1\" xmlns=\"http://www.w3.org/2000/svg\" xmlns:xlink=\"http://www.w3.org/1999/xlink\"
  width=\"32px\" height=\"32px\" viewBox=\"0 0 512 512\" xml:space=\"preserve\">
<path id=\"revertPath\" fill=\"#2020A0\" d=\"M271.844,119.641c-78.531,0-148.031,37.875-191.813,96.188l-80.172-80.188v256h256l-87.094-87.094
  c23.141-70.188,89.141-120.906,167.063-120.906c97.25,0,176,78.813,176,176C511.828,227.078,404.391,119.641,271.844,119.641z\" />
</svg>

<p style=\"color: green\"><%= notice %></p>#{"
<select id=\"schema\">#{schema_options}</select>" if ::Brick.config.schema_behavior[:multitenant] && ::Brick.db_schemas.length > 1}
<select id=\"tbl\">#{table_options}</select>
<h1>#{model_name}: <%= (obj = @#{obj_name})&.brick_descrip || controller_name %></h1><%
if (description = (relation = Brick.relations[#{model_name}.table_name])&.fetch(:description, nil)) %><%=
  description %><br><%
end
%><%= link_to '(See all #{obj_name.pluralize})', #{path_obj_name.pluralize}_path %>
#{erd_markup}
<% if obj %>
  <br><br>
  <%= # path_options = [obj.#{pk}]
    # path_options << { '_brick_schema':  } if
    # url = send(:#{model_name.underscore}_path, obj.#{pk})
    form_for(obj.becomes(#{model_name})) do |f| %>
  <table class=\"shadow\">
  <% has_fields = false
    @#{obj_name}.attributes.each do |k, val|
      col = #{model_name}.columns_hash[k] %>
    <tr>
    <% next if (#{(pk || []).inspect}.include?(k) && !bts.key?(k)) ||
               ::Brick.config.metadata_columns.include?(k) %>
    <th class=\"show-field\"<%= \" title=\\\"#\{col.comment}\\\"\".html_safe if col.respond_to?(:comment) && !col.comment.blank? %>>
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
    <table><tr><td>
    <% dt_pickers = { datetime: 'datetimepicker', timestamp: 'datetimepicker', time: 'timepicker', date: 'datepicker' }
    html_options = {}
    html_options[:class] = 'dimmed' unless val
    is_revert = true
    if bt
      html_options[:prompt] = \"Select #\{bt_name\}\" %>
      <%= f.select k.to_sym, bt[3], { value: val || '^^^brick_NULL^^^' }, html_options %>
      <%= if (bt_obj = bt_class&.find_by(bt_pair[1] => val))
            link_to('⇛', send(\"#\{bt_class.base_class.name.underscore.tr('/', '_')\}_path\".to_sym, bt_obj.send(bt_class.primary_key.to_sym)), { class: 'show-arrow' })
          elsif val
            \"<span class=\\\"orphan\\\">Orphaned ID: #\{val}</span>\".html_safe
          end %>
    <% else
      case (col_type = col.type || col.sql_type)
      when :string, :text %>
        <% if is_bcrypt?(val) # || .readonly?
             is_revert = false %>
          <%= hide_bcrypt(val, 1000) %>
        <% else %>
          <%= f.text_field(k.to_sym, html_options) %>
        <% end %>
      <% when :boolean %>
        <%= f.check_box k.to_sym %>
      <% when :integer, :decimal, :float %>
        <%= if col_type == :integer
              f.text_field k.to_sym, { pattern: '\\d*', class: 'check-validity' }
            else
              f.number_field k.to_sym
            end %>
      <% when *dt_pickers.keys
           is_includes_dates = true %>
        <%= f.text_field k.to_sym, { class: dt_pickers[col_type] } %>
      <% when :uuid
           is_revert = false %>
        <%=
          # Postgres naturally uses the +uuid_generate_v4()+ function from the uuid-ossp extension
          # If it's not yet enabled then:  create extension \"uuid-ossp\";
          # ActiveUUID gem created a new :uuid type
          val %>
      <% when :ltree %>
        <%=
          # In Postgres labels of data stored in a hierarchical tree-like structure
          # If it's not yet enabled then:  create extension ltree;
          val %>
      <% when :binary, :primary_key
           is_revert = false %>
      <% else %>
        <%= display_value(col_type, val)
           is_revert = false %>
      <% end
       end
       if is_revert
         %></td>
         <td><svg class=\"revert\" width=\"1.5em\" viewBox=\"0 0 512 512\"><use xlink:href=\"#revertPath\" /></svg>
      <% end %>
      </td></tr></table>
    </td>
    </tr>
  <% end
  if has_fields %>
    <tr><td colspan=\"2\"><%= f.submit({ class: 'update' }) %></td></tr>
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
      s << "<table id=\"#{hm_name}\" class=\"shadow\">
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
              inline << "
<% if is_includes_dates %>
<link rel=\"stylesheet\" href=\"https://cdn.jsdelivr.net/npm/flatpickr/dist/flatpickr.min.css\">
<style>
.flatpickr-calendar {
  background: #A0FFA0;
}
</style>
<script src=\"https://cdn.jsdelivr.net/npm/flatpickr\"></script>
<script>
flatpickr(\".datepicker\");
flatpickr(\".datetimepicker\", {enableTime: true});
flatpickr(\".timepicker\", {enableTime: true, noCalendar: true});
</script>
<% end %>

<% if true # @_brick_erd
%>
<script>
  var imgErd = document.getElementById(\"imgErd\");
  var mermaidErd = document.getElementById(\"mermaidErd\");
  var mermaidCode;
  var cbs = {<%= callbacks.map { |k, v| \"#\{k}: \\\"#\{v.name.underscore.pluralize}\\\"\" }.join(', ').html_safe %>};
  if (imgErd) imgErd.addEventListener(\"click\", showErd);
  function showErd() {
    imgErd.style.display = \"none\";
    mermaidErd.style.display = \"inline-block\";
    if (mermaidCode) return; // Cut it short if we've already rendered the diagram

    mermaidCode = document.createElement(\"SCRIPT\");
    mermaidCode.setAttribute(\"src\", \"https://cdn.jsdelivr.net/npm/mermaid/dist/mermaid.min.js\");
    mermaidCode.addEventListener(\"load\", function () {
      mermaid.initialize({
        startOnLoad: true,
        securityLevel: \"loose\",
        mermaid: {callback: function(objId) {
          var svg = document.getElementById(objId);
          svg.removeAttribute(\"width\");
          var cb;
          for(cb in cbs) {
            var gErd = svg.getElementById(cb);
            gErd.setAttribute(\"class\", \"relatedModel\");
            gErd.addEventListener(\"click\",
              function (evt) {
                location.href = changeout(changeout(location.href, -1, cbs[this.id]), \"_brick_erd\", \"1\");
              }
            );
          }
        }}
      });
      mermaid.contentLoaded();
      // Add <span> at the end
      var span = document.createElement(\"SPAN\");
      span.className = \"exclude\";
      span.innerHTML = \"X\";
      span.addEventListener(\"click\", function (e) {
        e.stopPropagation();
        imgErd.style.display = \"table-cell\";
        mermaidErd.style.display = \"none\";
        window.history.pushState({}, '', changeout(location.href, '_brick_erd', null));
      });
      mermaidErd.appendChild(span);
    });
    document.body.appendChild(mermaidCode);
  }
  <%= \"  showErd();\n\" if (@_brick_erd || 0) > 0
%></script>

<% end

%><script>
<% # Make column headers sort when clicked
   # %%% Create a smart javascript routine which can do this client-side %>
[... document.getElementsByTagName(\"TH\")].forEach(function (th) {
  th.addEventListener(\"click\", function (e) {
    var xOrder;
    if (xOrder = this.getAttribute(\"x-order\"))
      location.href = changeout(location.href, \"_brick_order\", xOrder);
  });
});
document.querySelectorAll(\"input, select\").forEach(function (inp) {
  var origVal = getInpVal(),
      prevVal = origVal;
  var revert;
  if (inp.getAttribute(\"type\") == \"hidden\" || inp.getAttribute(\"type\") == \"submit\") return;

  var svgTd = null;
  if ((revert = ((inp.tagName === \"SELECT\" && (svgTd = inp.parentElement.nextElementSibling) && svgTd.firstElementChild) ||
                 ((svgTd = inp.parentElement.nextElementSibling) && svgTd.firstElementChild))
     ) && revert.tagName.toLowerCase() === \"svg\")
    revert.addEventListener(\"click\", function (e) {
      if (inp.type === \"checkbox\")
        inp.checked = origVal;
      else
        inp.value = origVal;
      revert.style.display = \"none\";
      if (inp._flatpickr)
        inp._flatpickr.setDate(origVal);
      else
        inp.focus();
    });
  inp.addEventListener(inp.type === \"checkbox\" ? \"change\" : \"input\", function (e) {
    if(inp.className.split(\" \").indexOf(\"check-validity\") > 0) {
      if (inp.checkValidity()) {
        prevVal = getInpVal();
      } else {
        inp.value = prevVal;
      }
    } else {
      // If this is the result of changing an hour or minute, keep the calendar open.
      // And if it was the result of selecting a date, the calendar can now close.
      if (inp._flatpickr &&
           // Test only for changes in the date portion of a date or datetime
           ((giv = getInpVal()) && (giv1 = giv.split(' ')[0])) !== (prevVal && prevVal.split(' ')[0]) &&
           giv1.indexOf(\":\") < 0 // (definitely not any part of a time thing)
         )
        inp._flatpickr.close();
      prevVal = getInpVal();
    }
    // Show or hide the revert button
    if (revert) revert.style.display = getInpVal() === origVal ? \"none\" : \"block\";
  });
  function getInpVal() {
    return inp.type === \"checkbox\" ? inp.checked : inp.value;
  }
});
</script>"
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
