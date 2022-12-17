# frozen_string_literal: true

module Brick
  module Rails
    # See http://guides.rubyonrails.org/engines.html
    class Engine < ::Rails::Engine
      JS_CHANGEOUT = "function changeout(href, param, value, trimAfter) {
  var hrefParts = href.split(\"?\");
  var params = hrefParts.length > 1 ? hrefParts[1].split(\"&\") : [];
  if (param === undefined || param === null || param === -1) {
    hrefParts = hrefParts[0].split(\"://\");
    var pathParts = hrefParts[hrefParts.length - 1].split(\"/\").filter(function (pp) {return pp !== \"\";});
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
"

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
        ::Brick.models_inherit_from = app.config.brick.fetch(:models_inherit_from, nil) ||
                                      begin
                                        ::ApplicationRecord
                                      rescue StandardError => ex
                                        ::ActiveRecord::Base
                                      end

        # When table names have specific prefixes, automatically place them in their own module with a table_name_prefix.
        ::Brick.table_name_prefixes = app.config.brick.fetch(:table_name_prefixes, {})

        # Columns to treat as being metadata for purposes of identifying associative tables for has_many :through
        ::Brick.metadata_columns = app.config.brick.fetch(:metadata_columns, ['created_at', 'updated_at', 'deleted_at'])

        # Columns for which to add a validate presence: true even though the database doesn't have them marked as NOT NULL
        ::Brick.not_nullables = app.config.brick.fetch(:not_nullables, [])

        # Additional references (virtual foreign keys)
        ::Brick.additional_references = app.config.brick.fetch(:additional_references, nil)

        # Custom columns to add to a table, minimally defined with a name and DSL string
        ::Brick.custom_columns = app.config.brick.fetch(:custom_columns, nil)

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
        if (app_config = app.config).respond_to?(:assets)
          (app_config.assets.precompile ||= []) << "#{assets_path}/images/brick_erd.png"
          (app.config.assets.paths ||= []) << assets_path
        end

        # Smarten up Avo so it recognises Brick's querystring option for Apartment multi-tenancy
        if Object.const_defined?('Avo') && ::Avo.respond_to?(:railtie_namespace)
          module ::Avo
            class ApplicationController
              # Make Avo tenant-compatible when a querystring param is included such as:  ?_brick_schema=globex_corp
              alias _brick_avo_init init_app
              def init_app
                _brick_avo_init
                ::Brick.set_db_schema(params)
              end
            end

            module UrlHelpers
              alias _brick_resource_path resource_path
              # Accommodate STI resources
              def resource_path(model:, resource:, **args)
                resource ||= if (klass = model&.class)
                               Avo::App.resources.find { |r| r.model_class > klass }
                             end
                _brick_resource_path(model: model, resource: resource, **args)
              end
            end

            class Fields::BelongsToField
              # When there is no Resource created for the target of a belongs_to, defer to the description that Brick would use
              alias _brick_label label
              def label
                target_resource ? _brick_label : value.send(:brick_descrip)
              end
            end

            class App
              class << self
                alias _brick_eager_load eager_load
                def eager_load(entity)
                  _brick_eager_load(entity)
                  if entity == :resources
                    # %%% This useful logic can be DRYd up since it's very similar to what's around extensions.rb:1894
                    if (possible_schemas = (multitenancy = ::Brick.config.schema_behavior&.[](:multitenant)) &&
                                           multitenancy&.[](:schema_to_analyse))
                      possible_schemas = [possible_schemas] unless possible_schemas.is_a?(Array)
                      if (possible_schema = possible_schemas.find { |ps| ::Brick.db_schemas.key?(ps) })
                        orig_tenant = Apartment::Tenant.current
                        Apartment::Tenant.switch!(possible_schema)
                      end
                    end
                    existing = Avo::BaseResource.descendants.each_with_object({}) do |r, s|
                                 s[r.name[0..-9]] = nil if r.name.end_with?('Resource')
                               end
                    ::Brick.relations.each do |k, v|
                      unless existing.key?(class_name = v[:class_name]) || Brick.config.exclude_tables.include?(k) || class_name.blank?
                        Object.const_get("#{class_name}Resource")
                      end
                    end
                    Apartment::Tenant.switch!(orig_tenant) if orig_tenant
                  end
                end
              end
            end

            # Add our schema link Javascript code when the TurboFrameWrapper is rendered so it ends up on all index / show / etc
            TurboFrameWrapperComponent.class_exec do
              alias _brick_content content
              def content
                # Avo's logo partial fails if there is not a URL helper called exactly "root_path"
                # (Finicky line over there is:  avo/app/views/avo/partials/_logo.html.erb:1)
                if ::Brick.instance_variable_get(:@_brick_avo_js) == view_renderer.object_id
                  _brick_content
                else
                  ::Brick.instance_variable_set(:@_brick_avo_js, view_renderer.object_id)
                  unless ::Rails.application.routes.named_routes.names.include?(:root) || ActionView::Base.respond_to?(:root_path)
                    ActionView::Base.class_exec do
                      def root_path
                        Avo::App.root_path
                      end
                    end
                  end
"<script>
#{JS_CHANGEOUT}
window.addEventListener(\"load\", linkSchemas);
document.addEventListener(\"turbo:render\", linkSchemas);
window.addEventListener(\"popstate\", linkSchemas);
// [... document.getElementsByTagName('turbo-frame')].forEach(function (a) { a.addEventListener(\"turbo:frame-render\", linkSchemas); });
function linkSchemas() {
  brickSchema = changeout(location.href, \"_brick_schema\");
  if (brickSchema) {
    [... document.getElementsByTagName(\"A\")].forEach(function (a) { a.href = changeout(a.href, \"_brick_schema\", brickSchema); });
    [... document.getElementsByTagName(\"FORM\")].forEach(function (form) { form.action = changeout(form.action, \"_brick_schema\", brickSchema); });
  }
}
</script>
#{_brick_content}".html_safe
                end
              end
            end

            # When available, add a clickable brick icon to go to the Brick version of the page
            PanelComponent.class_exec do
              alias _brick_init initialize
              def initialize(*args)
                _brick_init(*args)
                @name = BrickTitle.new(@name, self)
              end
            end

            class BrickTitle
              def initialize(name, view_component)
                @vc = view_component
                @_name = name || ''
              end
              def to_s
                @_name.html_safe + @vc.instance_variable_get(:@__vc_helpers)&.link_to_brick(nil,
                  "<svg version=\"1.1\" style=\"display: inline; padding-left: 0.5em;\" xmlns=\"http://www.w3.org/2000/svg\" xmlns:xlink=\"http://www.w3.org/1999/xlink\"
  viewBox=\"0 0 58 58\" height=\"1.4em\" xml:space=\"preserve\">
<g>
  <polygon style=\"fill:#C2615F;\" points=\"58,15.831 19.106,35.492 0,26.644 40,6\"/>
  <polygon style=\"fill:#6D4646;\" points=\"19,52 0,43.356 0,26.644 19,35\"/>
  <polygon style=\"fill:#894747;\" points=\"58,31.559 19,52 19,35 58,15.831\"/>
</g>
</svg>
".html_safe,
                  { title: "#{@_name} in Brick" }
                )
              end
            end

            class Fields::IndexComponent
              alias _brick_resource_view_path resource_view_path
              def resource_view_path
                return if @resource.model&.class&.is_view?

                _brick_resource_view_path
              end
            end
          end # module Avo

          # Steer any Avo-related controller/action based URL lookups to the Avo RouteSet
          class ActionDispatch::Routing::RouteSet
            alias _brick_url_for url_for
            def url_for(options, *args)
              if self != ::Avo.railtie_routes_url_helpers._routes && # This URL lookup is not on the Avo RouteSet ...
                 (options[:controller]&.start_with?('avo/') || # ... but it is based on an Avo controller and action?
                  options[:_recall]&.fetch(:controller, nil)&.start_with?('avo/')
                 )
                options[:script_name] = ::Avo.configuration.root_path if options[:script_name].blank?
                ::Avo.railtie_routes_url_helpers._routes.url_for(options, *args) # Go get the answer from the real Avo RouteSet
              # Views currently do not support show / new / edit
              elsif options[:controller]&.start_with?('avo/') &&
                    ['show', 'new', 'edit'].include?(options[:action]) &&
                    ((options[:id].is_a?(ActiveRecord::Base) && options[:id].class.is_view?) ||
                     ::Brick.relations.fetch(options[:controller][4..-1], nil)&.fetch(:isView, nil)
                    )
                nil
              else # This is either a non-Avo request or a proper Avo request, so carry on
                _brick_url_for(options, *args)
              end
            end
          end
        end # Avo compatibility

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
              (args.first == 'crosstab') ||
              _brick_template_exists?(*args, **options) ||
              # Do not auto-create a template when it's searching for an application.html.erb, which comes in like:  ["edit", ["games", "application"]]
              ((args[1].length == 1 || args[1][-1] != 'application') &&
               set_brick_model(args))
            end

            def set_brick_model(find_args)
              # Need to return true if we can fill in the blanks for a missing one
              # args will be something like:  ["index", ["categories"]]
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

            def path_keys(hm_assoc, fk_name, pk)
              pk.map!(&:to_sym)
              keys = if fk_name.is_a?(Array) && pk.is_a?(Array) # Composite keys?
                       fk_name.zip(pk)
                     else
                       [[fk_name, pk.length == 1 ? pk.first : pk.inspect]]
                     end
              keys << [hm_assoc.inverse_of.foreign_type, hm_assoc.active_record.name] if hm_assoc.options.key?(:as)
              keys.to_h
            end

            alias :_brick_find_template :find_template
            def find_template(*args, **options)
              unless (model_name = @_brick_model&.name) ||
                     (is_status = ::Brick.config.add_status && args[0..1] == ['status', ['brick_gem']]) ||
                     (is_orphans = ::Brick.config.add_orphans && args[0..1] == ['orphans', ['brick_gem']]) ||
                     (is_crosstab = args[0..1] == ['crosstab', ['brick_gem']])
                if ActionView.version < ::Gem::Version.new('5.0') # %%% Not sure if this should be perhaps 4.2 instead
                  begin
                    if (possible_template = _brick_find_template(*args, **options))
                      return possible_template
                    end
                  rescue
                  end
                elsif (possible_template = _brick_find_template(*args, **options))
                  return possible_template
                end
                # Used to also have:  ActionView.version < ::Gem::Version.new('5.0') &&
                model_name = (args[1].is_a?(Array) ? set_brick_model(args) : nil)&.name
              end

              if @_brick_model
                pk = @_brick_model._brick_primary_key(::Brick.relations.fetch((table_name = @_brick_model.table_name.split('.').last), nil))
                obj_name = model_name.split('::').last.underscore
                path_obj_name = @_brick_model._brick_index(:singular)
                table_name ||= obj_name.pluralize
                template_link = nil
                bts, hms = ::Brick.get_bts_and_hms(@_brick_model) # This gets BT and HM and also has_many :through (HMT)
                hms_columns = [] # Used for 'index'
                skip_klass_hms = ::Brick.config.skip_index_hms[model_name] || {}
                hms_headers = hms.each_with_object([]) do |hm, s|
                  hm_stuff = [(hm_assoc = hm.last),
                              "H#{hm_assoc.macro == :has_one ? 'O' : 'M'}#{'T' if hm_assoc.options[:through]}",
                              (assoc_name = hm.first)]
                  hm_fk_name = if (through = hm_assoc.options[:through])
                                 next unless @_brick_model.instance_methods.include?(through) &&
                                             (associative = @_brick_model._br_associatives.fetch(hm.first, nil))

                                 tbl_nm = if (source = hm_assoc.source_reflection).macro == :has_many
                                            source.inverse_of&.name # For HM -> HM style HMT
                                          else # belongs_to or has_one
                                            hm_assoc.through_reflection&.name # for standard HMT, which is HM -> BT
                                          end
                                 # If there is no inverse available for the source belongs_to association, make one based on the class name
                                 unless tbl_nm
                                   tbl_nm = associative.class_name.underscore
                                   tbl_nm.slice!(0) if tbl_nm[0] == '/'
                                   tbl_nm = tbl_nm.tr('/', '_').pluralize
                                 end
                                 "#{tbl_nm}.#{associative.foreign_key}"
                               else
                                 hm_assoc.foreign_key
                               end
                  case args.first
                  when 'index'
                    if !skip_klass_hms.key?(assoc_name.to_sym) && (
                         @_brick_model._br_hm_counts.key?(assoc_name) ||
                         @_brick_model._br_bt_descrip.key?(assoc_name) # Will end up here if it's a has_one
                       )
                      hm_entry = +"'#{hm_assoc.name}' => [#{assoc_name.inspect}, "
                      hm_entry << if hm_assoc.macro == :has_one
                                    'nil'
                                  else # :has_many or :has_and_belongs_to_many
                                    # Postgres column names are limited to 63 characters
                                    "'" + "b_r_#{assoc_name}_ct"[0..62] + "'"
                                  end
                      hm_entry << ", #{path_keys(hm_assoc, hm_fk_name, pk).inspect}]"
                      hms_columns << hm_entry
                    end
                  when 'show', 'new', 'update'
                    hm_stuff << if hm_fk_name
                                  if hm_assoc.klass.column_names.include?(hm_fk_name)
                                    predicates = path_keys(hm_assoc, hm_fk_name, pk).map do |k, v|
                                                   v.is_a?(String) ? "#{k}: '#{v}'" : "#{k}: @#{obj_name}.#{v}"
                                                 end.join(', ')
                                    "<%= link_to '#{assoc_name}', #{hm_assoc.klass._brick_index}_path({ #{predicates} }) %>\n"
                                  else
                                    puts "Warning:  has_many :#{hm_assoc.name} in model #{hm_assoc.active_record.name} currently looks for a foreign key called \"#{hm_assoc.foreign_key}\".  "\
                                         "Instead it should use the clause  \"foreign_key: :#{hm_assoc.inverse_of&.foreign_key}\"."
                                    assoc_name
                                  end
                                else # %%% Would be able to remove this when multiple foreign keys to same destination becomes bulletproof
                                  assoc_name
                                end
                  end
                  s << hm_stuff
                end
              end

              apartment_default_schema = ::Brick.apartment_multitenant && ::Brick.apartment_default_tenant
              if ::Brick.apartment_multitenant && ::Brick.db_schemas.length > 1
                schema_options = +'<select id="schema"><% if @_is_show_schema_list %>'
                ::Brick.db_schemas.keys.each { |v| schema_options << "\n  <option value=\"#{v}\">#{v}</option>" }
                schema_options << "\n<% else %><option selected value=\"#{Apartment::Tenant.current}\">#{Apartment::Tenant.current}</option>\n"
                schema_options << '<% end %></select>'
              end
              # %%% If we are not auto-creating controllers (or routes) then omit by default, and if enabled anyway, such as in a development
              # environment or whatever, then get either the controllers or routes list instead
              prefix = "#{::Brick.config.path_prefix}/" if ::Brick.config.path_prefix
              table_options = (::Brick.relations.keys - ::Brick.config.exclude_tables).each_with_object({}) do |tbl, s|
                                if (tbl_parts = tbl.split('.')).first == apartment_default_schema
                                  tbl = tbl_parts.last
                                end
                                s[tbl] = nil
                              end.keys.sort.each_with_object(+'') do |v, s|
                                s << "<option value=\"#{prefix}#{v.underscore.gsub('.', '/')}\">#{v}</option>"
                              end.html_safe
              table_options << "<option value=\"#{prefix}brick_status\">(Status)</option>".html_safe if ::Brick.config.add_status
              table_options << "<option value=\"#{prefix}brick_orphans\">(Orphans)</option>".html_safe if is_orphans
              table_options << "<option value=\"#{prefix}brick_orphans\">(Crosstab)</option>".html_safe if is_crosstab
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
#headerTop tr th:hover, #headerTop tr th.highlight {
  background-color: #28B898;
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

tr td.highlight {
  background-color: #B0B0FF;
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
.danger {
  background-color: red;
  color: white;
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
      if (val = val.dup.strip).length > max_len
        if val[0] == '<' # Seems to be HTML?
          cur_len = 0
          cur_idx = 0
          # Find which HTML tags we might be inside so we can apply ending tags to balance
          element_name = nil
          in_closing = nil
          elements = []
          val.each_char do |ch|
            case ch
            when '<'
              element_name = +''
            when '/' # First character of tag is '/'?
              in_closing = true if element_name == ''
            when '>'
              if element_name
                if in_closing
                  if (idx = elements.index { |tag| tag.downcase == element_name.downcase })
                    elements.delete_at(idx)
                  end
                elsif (tag_name = element_name.split.first).present?
                  elements.unshift(tag_name)
                end
                element_name = nil
                in_closing = nil
              end
            else
              element_name << ch if element_name
            end
            cur_idx += 1
            # Unless it's inside wickets then this is real text content, and see if we're at the limit
            break if element_name.nil? && ((cur_len += 1) > max_len)
          end
          val = val[0..cur_idx]
          # Somehow still in the middle of an opening tag right at the end? (Should never happen)
          if !in_closing && (tag_name = element_name&.split&.first)&.present?
            elements.unshift(tag_name)
            val << '>'
          end
          elements.each do |closing_tag|
            val << \"</#\{closing_tag}>\"
          end
        else # Not HTML, just cut it at the length
          val = val[0...max_len]
        end
        val = \"#\{val}...\"
      end
      val = val.dup.force_encoding('UTF-8') unless val.encoding.name == 'UTF-8'
      val
    else
      val.to_s
    end
  end
end
def display_value(col_type, val)
  case col_type
  when 'geometry', 'geography'
    if Object.const_defined?('RGeo')
      @is_mysql = ActiveRecord::Base.connection.adapter_name == 'Mysql2' if @is_mysql.nil?
      @is_mssql = ActiveRecord::Base.connection.adapter_name == 'SQLServer' if @is_mssql.nil?
      val_err = nil
      if @is_mysql || @is_mssql
        # MySQL's \"Internal Geometry Format\" and MSSQL's Geography are like WKB, but with an initial 4 bytes that indicates the SRID.
        if (srid = val&.[](0..3)&.unpack('I'))
          val = val.dup.force_encoding('BINARY')[4..-1].bytes

          # MSSQL spatial bitwise flags, often 0C for a point:
          # xxxx xxx1 = HasZValues
          # xxxx xx1x = HasMValues
          # xxxx x1xx = IsValid
          # xxxx 1xxx = IsSinglePoint
          # xxx1 xxxx = IsSingleLineSegment
          # xx1x xxxx = IsWholeGlobe
          # Convert Microsoft's unique geography binary to standard WKB
          # (MSSQL point usually has two doubles, lng / lat, and can also have Z)
          if @is_mssql
            if val[0] == 1 && (val[1] & 8 > 0) && # Single point?
              (val.length - 2) % 8 == 0 && val.length < 27 # And containing up to three 8-byte values?
              idx = 2
              new_val = [0, 0, 0, 0, 1]
              new_val.concat(val[idx - 8...idx].reverse) while (idx += 8) <= val.length
              val = new_val
            else
              val_err = '(Microsoft internal SQL geography type)'
            end
          end
        end
      end
      val_err || (val ? RGeo::WKRep::WKBParser.new.parse(val.pack('c*')) : nil)
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
# Accommodate composite primary keys that include strings with forward-slash characters
def slashify(*vals)
  vals.map { |val_part| val_part.is_a?(String) ? val_part.gsub('/', '^^sl^^') : val_part }
end
callbacks = {} %>

<% avo_svg = \"#{
"<svg version=\"1.1\" xmlns=\"http://www.w3.org/2000/svg\" viewBox=\"0 0 84 90\" height=\"30\" fill=\"#3096F7\">
  <path d=\"M83.8304 81.0201C83.8343 82.9343 83.2216 84.7996 82.0822 86.3423C80.9427 87.8851 79.3363 89.0244 77.4984 89.5931C75.6606 90.1618 73.6878 90.1302 71.8694 89.5027C70.0509 88.8753 68.4823 87.6851 67.3935 86.1065L67.0796 85.6029C66.9412 85.378 66.8146 85.1463 66.6998 84.9079L66.8821 85.3007C64.1347 81.223 60.419 77.8817 56.0639 75.5723C51.7087 73.263 46.8484 72.057 41.9129 72.0609C31.75 72.0609 22.372 77.6459 16.9336 85.336C17.1412 84.7518 17.7185 83.6137 17.9463 83.0446L19.1059 80.5265L19.1414 80.456C25.2533 68.3694 37.7252 59.9541 52.0555 59.9541C53.1949 59.9541 54.3241 60.0095 55.433 60.1102C60.748 60.6134 65.8887 62.2627 70.4974 64.9433C75.1061 67.6238 79.0719 71.2712 82.1188 75.6314C82.1188 75.6314 82.1441 75.6717 82.1593 75.6868C82.1808 75.717 82.1995 75.749 82.215 75.7825C82.2821 75.8717 82.3446 75.9641 82.4024 76.0595C82.4682 76.1653 82.534 76.4221 82.5999 76.5279C82.6657 76.6336 82.772 76.82 82.848 76.9711L83.1822 77.7063C83.6094 78.7595 83.8294 79.8844 83.8304 81.0201V81.0201Z\" fill=\"currentColor\" fill-opacity=\"0.22\"></path>
  <path opacity=\"0.25\" d=\"M83.8303 81.015C83.8354 82.9297 83.2235 84.7956 82.0844 86.3393C80.9453 87.8829 79.339 89.0229 77.5008 89.5923C75.6627 90.1617 73.6895 90.1304 71.8706 89.5031C70.0516 88.8758 68.4826 87.6854 67.3935 86.1065L67.0796 85.6029C66.9412 85.3746 66.8146 85.1429 66.6998 84.9079L66.8821 85.3007C64.1353 81.222 60.4199 77.8797 56.0647 75.5695C51.7095 73.2593 46.8488 72.0524 41.9129 72.0558C31.75 72.0558 22.372 77.6408 16.9336 85.3309C17.1412 84.7467 17.7185 83.6086 17.9463 83.0395L19.1059 80.5214L19.1414 80.4509C22.1906 74.357 26.8837 69.2264 32.6961 65.6326C38.5086 62.0387 45.2114 60.1232 52.0555 60.1001C53.1949 60.1001 54.3241 60.1555 55.433 60.2562C60.7479 60.7594 65.8887 62.4087 70.4974 65.0893C75.1061 67.7698 79.0719 71.4172 82.1188 75.7775C82.1188 75.7775 82.1441 75.8177 82.1593 75.8328C82.1808 75.863 82.1995 75.895 82.215 75.9285C82.2821 76.0177 82.3446 76.1101 82.4024 76.2055L82.5999 76.5228C82.6859 76.6638 82.772 76.8149 82.848 76.966L83.1822 77.7012C83.6093 78.7544 83.8294 79.8793 83.8303 81.015Z\" fill=\"currentColor\" fill-opacity=\"0.22\"></path>
  <path d=\"M42.1155 30.2056L35.3453 45.0218C35.2161 45.302 35.0189 45.5458 34.7714 45.7313C34.5239 45.9168 34.2338 46.0382 33.9274 46.0844C27.3926 47.1694 21.1567 49.5963 15.617 53.2105C15.279 53.4302 14.8783 53.5347 14.4753 53.5083C14.0723 53.4819 13.6889 53.326 13.3827 53.0641C13.0765 52.8022 12.8642 52.4485 12.7777 52.0562C12.6911 51.6638 12.7351 51.2542 12.9029 50.8889L32.2311 8.55046L33.6894 5.35254C32.8713 7.50748 32.9166 9.89263 33.816 12.0153L33.9983 12.4131L42.1155 30.2056Z\" fill=\"currentColor\" fill-opacity=\"0.22\"></path>
  <path d=\"M82.812 76.8753C82.6905 76.694 82.3715 76.2207 82.2449 76.0444C82.2044 75.9739 82.2044 75.8782 82.1588 75.8127C82.1132 75.7473 82.1335 75.7724 82.1183 75.7573C79.0714 71.3971 75.1056 67.7497 70.4969 65.0692C65.8882 62.3886 60.7474 60.7393 55.4325 60.2361C54.3236 60.1354 53.1943 60.08 52.055 60.08C45.2173 60.1051 38.5214 62.022 32.7166 65.6161C26.9118 69.2102 22.2271 74.3397 19.1864 80.4308L19.151 80.5013C18.7358 81.3323 18.3458 82.1784 17.9914 83.0194L16.9786 85.2655C16.9077 85.3662 16.8419 85.472 16.771 85.5828C16.6647 85.7389 16.5584 85.9 16.4621 86.0612C15.3778 87.6439 13.8123 88.8397 11.995 89.4732C10.1776 90.1068 8.20406 90.1448 6.36344 89.5817C4.52281 89.0186 2.9119 87.884 1.76676 86.3442C0.621625 84.8044 0.00246102 82.9403 0 81.0251C0.00604053 80.0402 0.177178 79.0632 0.506372 78.1344L1.22036 76.5681C1.25084 76.5034 1.28639 76.4411 1.32669 76.3818C1.40265 76.2559 1.47861 76.135 1.56469 76.0192C1.58531 75.9789 1.60901 75.9401 1.63558 75.9034C7.06401 67.6054 14.947 61.1866 24.1977 57.5317C33.4485 53.8768 43.6114 53.166 53.2855 55.4971L48.9155 45.9286L41.9276 30.6188L33.8256 12.8263L33.6433 12.4285C32.7439 10.3058 32.6986 7.92067 33.5167 5.76573L34.0231 4.69304C34.8148 3.24136 35.9941 2.03525 37.431 1.20762C38.868 0.379997 40.5068 -0.0370045 42.1668 0.0025773C43.8268 0.0421591 45.4436 0.536787 46.839 1.43195C48.2345 2.32711 49.3543 3.58804 50.0751 5.07578L50.2523 5.47363L51.8474 8.96365L74.0974 57.708L82.812 76.8753Z\" fill=\"currentColor\" fill-opacity=\"0.22\"></path>
  <path opacity=\"0.25\" d=\"M41.9129 30.649L35.3301 45.0422C35.2023 45.3204 35.0074 45.563 34.7627 45.7484C34.518 45.9337 34.2311 46.0562 33.9274 46.1048C27.3926 47.1897 21.1567 49.6166 15.617 53.2308C15.279 53.4505 14.8783 53.555 14.4753 53.5286C14.0723 53.5022 13.6889 53.3463 13.3827 53.0844C13.0765 52.8225 12.8642 52.4688 12.7777 52.0765C12.6911 51.6842 12.7351 51.2745 12.9029 50.9092L32.0285 8.99382L33.4869 5.7959C32.6687 7.95084 32.7141 10.336 33.6135 12.4586L33.7958 12.8565L41.9129 30.649Z\" fill=\"currentColor\" fill-opacity=\"0.22\"></path>
</svg>
".gsub('"', '\"')
}\".html_safe %>"

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
  if (tblSelect) { // Always present
    var i = #{::Brick.config.path_prefix ? '0' : 'schemaSelect ? 1 : 0'},
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

  if (schemaSelect && schemaSelect.options.length > 1) { // First drop-down is only present if multitenant
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
});

// Add \"Are you sure?\" behaviour to any data-confirm buttons out there
document.querySelectorAll(\"input[type=submit][data-confirm]\").forEach(function (btn) {
  btn.addEventListener(\"click\", function (evt) {
    if (!confirm(this.getAttribute(\"data-confirm\"))) {
      evt.preventDefault();
      return false;
    }
  });
});

#{JS_CHANGEOUT}

// Snag first TR for sticky header
var grid = document.getElementById(\"#{table_name}\");
#{table_name}HtColumns = grid && [grid.getElementsByTagName(\"TR\")[0]];
var headerTop = document.getElementById(\"headerTop\");
var headerCols;
if (grid) {
  // COLUMN HEADER AND TABLE CELL HIGHLIGHTING
  var gridHighHeader = null,
      gridHighCell = null;
  grid.addEventListener(\"mouseenter\", gridMove);
  grid.addEventListener(\"mousemove\", gridMove);
  grid.addEventListener(\"mouseleave\", function (evt) {
    if (gridHighCell) gridHighCell.classList.remove(\"highlight\");
    gridHighCell = null;
    if (gridHighHeader) gridHighHeader.classList.remove(\"highlight\");
    gridHighHeader = null;
  });
  function gridMove(evt) {
    var lastHighCell = gridHighCell;
    gridHighCell = document.elementFromPoint(evt.x, evt.y);
    while (gridHighCell && gridHighCell.tagName !== \"TD\" && gridHighCell.tagName !== \"TH\")
      gridHighCell = gridHighCell.parentElement;
    if (gridHighCell) {
      if (lastHighCell !== gridHighCell) {
        gridHighCell.classList.add(\"highlight\");
        if (lastHighCell) lastHighCell.classList.remove(\"highlight\");
      }
      var lastHighHeader = gridHighHeader;
      if ((gridHighHeader = headerCols[gridHighCell.cellIndex]) && lastHighHeader !== gridHighHeader) {
        if (gridHighHeader) gridHighHeader.classList.add(\"highlight\");
        if (lastHighHeader) lastHighHeader.classList.remove(\"highlight\");
      }
    }
  }
  // // LESS TOUCHY NAVIGATION BACK OR FORWARD IN HISTORY WHEN USING MOUSE WHEEL
  // grid.addEventListener(\"wheel\", function (evt) {
  //   grid.scrollLeft += evt.deltaX;
  //   document.body.scrollTop += (evt.deltaY * 0.6);
  //   evt.preventDefault();
  //   return false;
  // });
}
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
    headerCols = tr.childNodes;
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
<% def sidelinks(shown_classes, klass)
     links = []
     # %%% Not yet showing these as they can get just a bit intense!
     # klass.reflect_on_all_associations.select { |a| shown_classes.key?(a.klass) }.each do |assoc|
     #   unless shown_classes[assoc.klass].key?(klass.name)
     #     links << \"    #\{klass.name.split('::').last} #\{assoc.macro == :belongs_to ? '}o--||' : '||--o{'} #\{assoc.klass.name.split('::').last} : \\\"\\\"\"n\"
     #     shown_classes[assoc.klass][klass.name] = nil
     #   end
     # end
     # shown_classes[klass] ||= {}
     links.join
   end

   model_short_name = #{@_brick_model.name.split('::').last.inspect}
   shown_classes = {}
   @_brick_bt_descrip&.each do |bt|
     bt_class = bt[1].first.first
     callbacks[bt_name = bt_class.name.split('::').last] = bt_class
     is_has_one = #{@_brick_model.name}.reflect_on_association(bt.first).inverse_of&.macro == :has_one ||
                  ::Brick.config.has_ones&.fetch('#{@_brick_model.name}', nil)&.key?(bt.first.to_s)
    %>  <%= \"#\{model_short_name} #\{is_has_one ? '||' : '}o'}--|| #\{bt_name} : \\\"#\{
        bt_underscored = bt[1].first.first.name.underscore.singularize
        bt.first unless bt.first.to_s == bt_underscored.split('/').last # Was:  bt_underscored.tr('/', '_')
        }\\\"\".html_safe %>
<%=  sidelinks(shown_classes, bt_class).html_safe %>
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
<%=      sidelinks(shown_classes, through_assoc.active_record).html_safe %>
<%       last_through = through
       end
%>    <%= \"#\{through_name} }o--|| #\{hm_name}\".html_safe %> : \"\"
    <%= \"#\{model_short_name} }o..o{ #\{hm_name} : \\\"#\{hm.first}\\\"\".html_safe %><%
     else # has_many
%>  <%= \"#\{model_short_name} ||--o{ #\{hm_name} : \\\"#\{
            hm.first.to_s unless hm.first.to_s.downcase == hm_class.name.underscore.pluralize.tr('/', '_')
          }\\\"\".html_safe %><%
     end %>
<%=  sidelinks(shown_classes, hm_class).html_safe %>
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
                         if Object.const_defined?('DutyFree')
                           template_link = "
  <%= link_to 'CSV', #{@_brick_model._brick_index}_path(format: :csv) %> &nbsp; <a href=\"#\" id=\"sheetsLink\">Sheets</a>
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
        fetch(changeout(<%= #{@_brick_model._brick_index}_path(format: :js).inspect.html_safe %>, \"_brick_schema\", brickSchema)).then(function (response) {
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
+"<html>
<head>
#{css}
<title><% model = #{model_name}
          if sub_model = @_brick_params&.fetch(type_col = model.inheritance_column, nil)&.first
            model = Object.const_get(sub_model.to_sym)
          end
       %><%= model.name %><%
  if (description = (relation = Brick.relations[model.table_name])&.fetch(:description, nil)).present?
    %> - <%= description
%><% end
%></title>
</head>
<body>
<p style=\"color: green\"><%= notice %></p>#{"
#{schema_options}" if schema_options}
<select id=\"tbl\">#{table_options}</select>
<table id=\"resourceName\"><tr>
  <td><h1><%= model.name %></h1></td>
  <td id=\"imgErd\" title=\"Show ERD\"></td>
  <% if Object.const_defined?('Avo') && ::Avo.respond_to?(:railtie_namespace) %>
    <td><%= link_to_brick(
        avo_svg,
        { index_proc: Proc.new do |avo_model|
                        ::Avo.railtie_routes_url_helpers.send(\"resources_#\{model.model_name.route_key}_path\".to_sym)
                      end,
          title: \"#\{model.name} in Avo\" }
      ) %></td>
  <% end %>
</tr></table>#{template_link}<%
   if description.present? %><%=
     description %><br><%
   end
   # FILTER PARAMETERS
   if @_brick_params&.present? %>
  <% if @_brick_params.length == 1 # %%% Does not yet work with composite keys
       k, id = @_brick_params.first
       id = id.first if id.is_a?(Array) && id.length == 1
       origin = (key_parts = k.split('.')).length == 1 ? model : model.reflect_on_association(key_parts.first).klass
       if (destination_fk = Brick.relations[origin.table_name][:fks].values.find { |fk| fk[:fk] == key_parts.last }) &&
          (obj = (destination = origin.reflect_on_association(destination_fk[:assoc_name])&.klass)&.find(id)) %>
         <h3>for <%= link_to \"#{"#\{obj.brick_descrip\} (#\{destination.name\})\""}, send(\"#\{destination._brick_index(:singular)\}_path\".to_sym, id) %></h3><%
       end
     end %>
  (<%= link_to \"See all #\{model.base_class.name.split('::').last.pluralize}\", #{@_brick_model._brick_index}_path %>)
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

<%= # Consider getting the name from the association -- hm.first.name -- if a more \"friendly\" alias should be used for a screwy table name
    cols = {#{hms_keys = []
              hms_headers.map do |hm|
                hms_keys << (assoc_name = (assoc = hm.first).name.to_s)
                "#{assoc_name.inspect} => [#{(assoc.options[:through] && !assoc.through_reflection).inspect}, #{assoc.klass.name}, #{hm[1].inspect}, #{hm[2].inspect}]"
              end.join(', ')}}

    # If the resource is missing, has the user simply created an inappropriately pluralised name for a table?
    @#{table_name} ||= if (dym_list = instance_variables.reject do |entry|
                             entry.to_s.start_with?('@_') ||
                             ['@cache_hit', '@marked_for_same_origin_verification', '@view_renderer', '@view_flow', '@output_buffer', '@virtual_path'].include?(entry.to_s)
                           end).present?
                         msg = \"Can't find resource \\\"#{table_name}\\\".\"
                          # Can't be sure otherwise of what is up, so check DidYouMean and offer a suggestion.
                         if (dym = DidYouMean::SpellChecker.new(dictionary: dym_list).correct('@#{table_name}')).present?
                           msg << \"\nIf you meant \\\"#\{found_dym = dym.first[1..-1]}\\\" then to avoid this message add this entry into inflections.rb:\n\"
                           msg << \"  inflect.singular('#\{found_dym}', '#{obj_name}')\"
                           puts
                           puts \"WARNING:  #\{msg}\"
                           puts
                           @#{table_name} = instance_variable_get(dym.first.to_sym)
                         else
                           raise ActiveRecord::RecordNotFound.new(msg)
                         end
                       end

    # Write out the mega-grid
    brick_grid(@#{table_name}, @_brick_bt_descrip, @_brick_sequence, @_brick_incl, @_brick_excl,
               cols, poly_cols, bts, #{hms_keys.inspect}, {#{hms_columns.join(', ')}}) %>

#{"<hr><%= link_to \"New #{obj_name}\", new_#{path_obj_name}_path %>" unless @_brick_model.is_view?}
#{script}
</body>
</html>
"

                       when 'status'
                         if is_status
# Status page - list of all resources and 5 things they do or don't have present, and what is turned on and off
# Must load all models, and then find what table names are represented
# Easily could be multiple files involved (STI for instance)
+"#{css}
<p style=\"color: green\"><%= notice %></p>#{"
#{schema_options}" if schema_options}
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
  <td><%= begin
            kls = Object.const_get(::Brick.relations.fetch(r[0], nil)&.fetch(:class_name, nil))
          rescue
          end
          kls ? link_to(r[0], send(\"#\{kls._brick_index}_path\".to_sym)) : r[0] %></td>
  <td<%= if r[1]
           ' class=\"orphan\"' unless ::Brick.relations.key?(r[1])
         else
           ' class=\"dimmed\"'
         end&.html_safe %>><%= # Table
          r[1] %></td>
  <td<%= lines = r[2]&.map { |line| \"#\{line.first}:#\{line.last}\" }
         ' class=\"dimmed\"'.html_safe unless r[2] %>><%= # Migration
          lines&.join('<br>')&.html_safe %></td>
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
#{schema_options}" if schema_options}
<select id=\"tbl\">#{table_options}</select>
<h1>Orphans<%= \" for #\{}\" if false %></h1>
<% @orphans.each do |o|
     if (klass = ::Brick.relations[o[0]]&.fetch(:class_name, nil)&.constantize) %>
<%=    via = \" (via #\{o[4]})\" unless \"#\{o[2].split('.').last.underscore.singularize}_id\" == o[4]
       link_to(\"#\{o[0]} #\{o[1]} refers#\{via} to non-existent #\{o[2]} #\{o[3]}#\{\" (in table \\\"#\{o[5]}\\\")\" if o[5]}\",
               send(\"#\{klass._brick_index(:singular)\}_path\".to_sym, o[1])) %>
  <br>
<%   end
   end %>
#{script}"
                         end

                       when 'crosstab'
                         if is_crosstab && ::Brick.config.license
                           decipher = OpenSSL::Cipher::AES256.new(:CBC).decrypt
                           decipher.iv = "\xB4,\r2\x19\xF5\xFE/\aR\x1A\x8A\xCFV\v\x8C"
                           decipher.key = Digest::SHA256.hexdigest(::Brick.config.license).scan(/../).map { |x| x.hex }.pack('c*')
                           decipher.update(File.binread("/Users/aga/brick/lib/brick/frameworks/rails/crosstab.brk"))[16..-1]
                         else
                           'Crosstab Charting not yet activated -- enter a valid license key in brick.rb'
                         end

                       when 'show', 'new', 'update'
+"<html>
<head>
#{css}
<title><%=
  page_title = (\"#{model_name}: #\{(obj = @#{obj_name})&.brick_descrip || controller_name}\")
%></title>
</head>
<body>

<svg id=\"revertTemplate\" version=\"1.1\" xmlns=\"http://www.w3.org/2000/svg\" xmlns:xlink=\"http://www.w3.org/1999/xlink\"
  width=\"32px\" height=\"32px\" viewBox=\"0 0 512 512\" xml:space=\"preserve\">
<path id=\"revertPath\" fill=\"#2020A0\" d=\"M271.844,119.641c-78.531,0-148.031,37.875-191.813,96.188l-80.172-80.188v256h256l-87.094-87.094
  c23.141-70.188,89.141-120.906,167.063-120.906c97.25,0,176,78.813,176,176C511.828,227.078,404.391,119.641,271.844,119.641z\" />
</svg>

<p style=\"color: green\"><%= notice %></p>#{"
#{schema_options}" if schema_options}
<select id=\"tbl\">#{table_options}</select>
<table><td><h1><%= page_title %></h1></td>
<% if Object.const_defined?('Avo') && ::Avo.respond_to?(:railtie_namespace) %>
  <td><%= link_to_brick(
      avo_svg,
      { show_proc: Proc.new do |obj|
                     ::Avo.railtie_routes_url_helpers.send(\"resources_#\{obj.class.base_class.model_name.singular_route_key}_path\".to_sym, obj)
                   end,
        title: \"#\{page_title} in Avo\" }
    ) %></td>
<% end %>
</table>
<%
if (description = (relation = Brick.relations[#{model_name}.table_name])&.fetch(:description, nil)) %><%=
  description %><br><%
end
%><%= link_to '(See all #{obj_name.pluralize})', #{@_brick_model._brick_index}_path %>
#{erd_markup}
<% if obj
      # path_options = [obj.#{pk}]
      # path_options << { '_brick_schema':  } if
      # url = send(:#\{model_name._brick_index(:singular)}_path, obj.#{pk})
      options = {}
      options[:url] = send(\"#\{#{model_name}._brick_index(:singular)}_path\".to_sym, obj) if ::Brick.config.path_prefix
 %>
  <br><br>
  <%= form_for(obj.becomes(#{model_name}), options) do |f| %>
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
            # Accommodate any valid STI by going up the chain of inheritance
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
            link_to('⇛', send(\"#\{bt_class.base_class._brick_index(:singular)\}_path\".to_sym, bt_obj.send(bt_class.primary_key.to_sym)), { class: 'show-arrow' })
          elsif val
            \"<span class=\\\"orphan\\\">Orphaned ID: #\{val}</span>\".html_safe
          end %>
    <% else
      col_type = col.sql_type == 'geography' ? col.sql_type : col.type
      case (col_type ||= col.sql_type)
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
        <%= is_revert = false
           display_value(col_type, val) %>
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
<%   end %>

#{unless args.first == 'new'
  # Was:  confirm_are_you_sure = ActionView.version < ::Gem::Version.new('7.0') ? "data: { confirm: 'Delete #{model_name} -- Are you sure?' }" : "form: { data: { turbo_confirm: 'Delete #{model_name} -- Are you sure?' } }"
  confirm_are_you_sure = "data: { confirm: 'Delete #{model_name} -- Are you sure?' }"
  hms_headers.each_with_object(+'') do |hm, s|
    # %%% Would be able to remove this when multiple foreign keys to same destination becomes bulletproof
    next if hm.first.options[:through] && !hm.first.through_reflection

    if (pk = hm.first.klass.primary_key)
      hm_singular_name = (hm_name = hm.first.name.to_s).singularize.underscore
      obj_pk = (pk.is_a?(Array) ? pk : [pk]).each_with_object([]) { |pk_part, s| s << "#{hm_singular_name}.#{pk_part}" }.join(', ')
      s << "<table id=\"#{hm_name}\" class=\"shadow\">
        <tr><th>#{hm[3]}</th></tr>
        <% collection = @#{obj_name}.#{hm_name}
        collection = case collection
                     when ActiveRecord::Associations::CollectionProxy
                       collection.order(#{pk.inspect})
                     when ActiveRecord::Base # Object from a has_one
                       [collection]
                     else # We get an array back when AR < 4.2
                       collection.to_a.compact
                     end
        if collection.empty? %>
          <tr><td>(none)</td></tr>
        <% else %>
          <% collection.uniq.each do |#{hm_singular_name}| %>
            <tr><td><%= link_to(#{hm_singular_name}.brick_descrip, #{hm.first.klass._brick_index(:singular)}_path(slashify(#{obj_pk}))) %></td></tr>
          <% end %>
        <% end %>
      </table>"
    else
      s
    end
  end +
  "<%= button_to(\"Delete #\{@#{obj_name}.brick_descrip}\", send(\"#\{#{model_name}._brick_index(:singular)}_path\".to_sym, @#{obj_name}), { method: 'delete', class: 'danger', #{confirm_are_you_sure} }) %>"
end}
<% end %>
#{script}
</body>
</html>
"

                       end
              unless is_crosstab
                inline << "
<% if is_includes_dates %>
<link rel=\"stylesheet\" type=\"text/css\" href=\"https://cdn.jsdelivr.net/npm/flatpickr/dist/flatpickr.min.css\">
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

<% if false # is_includes_dropdowns %>
<script src=\"https://cdnjs.cloudflare.com/ajax/libs/slim-select/1.27.1/slimselect.min.js\"></script>
<link rel=\"stylesheet\" type=\"text/css\" href=\"https://cdnjs.cloudflare.com/ajax/libs/slim-select/1.27.1/slimselect.min.css\">
<% end %>

<% if true # @_brick_erd
%>
<script>
  var imgErd = document.getElementById(\"imgErd\");
  var mermaidErd = document.getElementById(\"mermaidErd\");
  var mermaidCode;
  var cbs = {<%= callbacks.map { |k, v| \"#\{k}: \\\"#\{send(\"#\{v._brick_index}_path\".to_sym)}\\\"\" }.join(', ').html_safe %>};
  if (imgErd) imgErd.addEventListener(\"click\", showErd);
  function showErd() {
    imgErd.style.display = \"none\";
    mermaidErd.style.display = \"inline-block\";
    if (mermaidCode) return; // Cut it short if we've already rendered the diagram

    mermaidCode = document.createElement(\"SCRIPT\");
    mermaidCode.setAttribute(\"src\", \"https://cdn.jsdelivr.net/npm/mermaid@9.1.7/dist/mermaid.min.js\");
    mermaidCode.addEventListener(\"load\", function () {
      mermaid.initialize({
        startOnLoad: true,
        securityLevel: \"loose\",
        er: { useMaxWidth: false },
        mermaid: {callback: function(objId) {
          var svg = document.getElementById(objId);
          var cb;
          for(cb in cbs) {
            var gErd = svg.getElementById(cb);
            gErd.setAttribute(\"class\", \"relatedModel\");
            gErd.addEventListener(\"click\",
              function (evt) {
                location.href = changeout(changeout(
                  changeout(location.href, '_brick_order', null), // Remove any ordering
                -1, cbs[this.id].replace(/^[\/]+/, \"\")), \"_brick_erd\", \"1\");
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
              end
              # puts "==============="
              # puts inline
              # puts "==============="
              # As if it were an inline template (see #determine_template in actionview-5.2.6.2/lib/action_view/renderer/template_renderer.rb)
              keys = options.has_key?(:locals) ? options[:locals].keys : []
              handler = ActionView::Template.handler_for_extension(options[:type] || 'erb')
              ActionView::Template.new(inline, "auto-generated #{args.first} template", handler, locals: keys).tap do |t|
                t.instance_variable_set(:@is_brick, true)
              end
            end
          end # LookupContext

          # For any auto-generated template, if multitenancy is active via some flavour of an Apartment gem, switch back to the default tenant.
          # (Underlying reason -- ros-apartment can hold on to a selected tenant between requests when there is no elevator middleware.)
          ActionView::TemplateRenderer.class_exec do
            private

              alias _brick_render_template render_template
              def render_template(view, template, layout_name, *args)
                layout_name = nil if (is_brick = template.instance_variable_get(:@is_brick)) && layout_name.is_a?(Proc)
                result = _brick_render_template(view, template, layout_name, *args)
                Apartment::Tenant.switch!(::Brick.apartment_default_tenant) if is_brick && ::Brick.apartment_multitenant
                result
              end
          end # TemplateRenderer
        end

        if ::Brick.enable_routes?
          ActionDispatch::Routing::RouteSet.class_exec do
            # In order to defer auto-creation of any routes that already exist, calculate Brick routes only after having loaded all others
            prepend ::Brick::RouteSet
          end
          # Do the root route before the Rails Welcome one would otherwise take precedence
          if (route = ::Brick.config.default_route_fallback).present?
            action = "#{route}#{'#index' unless route.index('#')}"
            if ::Brick.config.path_prefix
              ::Rails.application.routes.append do
                send(:namespace, ::Brick.config.path_prefix) do
                  send(:root, action)
                end
              end
            elsif ::Rails.application.routes.named_routes.send(:routes)[:root].nil?
              ::Rails.application.routes.append do
                send(:root, action)
              end
            end
          end
        end

        # Just in case it hadn't been done previously when we tried to load the brick initialiser,
        # go make sure we've loaded additional references (virtual foreign keys and polymorphic associations).
        # (This should only happen if for whatever reason the initializer file was not exactly config/initializers/brick.rb.)
        ::Brick.load_additional_references

        # If the RailsAdmin gem is present, add our auto-creatable model names into its list of viable models.
        if Object.const_defined?('RailsAdmin')
          RailsAdmin::Config.class_exec do
            class << self

            private

              alias _brick_viable_models viable_models
              def viable_models
                return _brick_viable_models if class_variables.include?(:@@system_models)

                @@system_models = (vm = _brick_viable_models) + (::Brick.auto_models - vm)
              end
            end
          end

          RailsAdmin::Config::Actions::Show.class_exec do
            register_instance_option :enabled? do
              !(bindings[:object] && bindings[:object].class.is_view?)
            end
          end

          RailsAdmin::Config::Actions::HistoryShow.class_exec do
            register_instance_option :enabled? do
              !(bindings[:object] && bindings[:object].class.is_view?)
            end
          end

          RailsAdmin.config do |config|
            ::Brick.relations.select { |_k, v| v.key?(:isView) }.each do |_k, relation|
              config.model(relation[:class_name]) do # new_model_class
                list do
                  sort_by (sort_col = relation[:cols].first.first)
                end
              end
            end
          end
        end
      end
    end
  end
end
