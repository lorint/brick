# frozen_string_literal: true

module Brick
  module Rails
    class << self
      def display_value(col_type, val)
        is_mssql_geography = nil
        # Some binary thing that really looks like a Microsoft-encoded WGS84 point?  (With the first two bytes, E6 10, indicating an EPSG code of 4326)
        if col_type == :binary && val && val.length < 31 && (val.length - 6) % 8 == 0 && val[0..5].bytes == [230, 16, 0, 0, 1, 12]
          col_type = 'geography'
          is_mssql_geography = true
        end
        case col_type
        when 'geometry', 'geography'
          if Object.const_defined?('RGeo')
            @is_mysql = ['Mysql2', 'Trilogy'].include?(ActiveRecord::Base.connection.adapter_name) if @is_mysql.nil?
            @is_mssql = ActiveRecord::Base.connection.adapter_name == 'SQLServer' if @is_mssql.nil?
            val_err = nil

            if @is_mysql || (is_mssql_geography ||=
                              (@is_mssql ||
                                (val && val.length < 31 && (val.length - 6) % 8 == 0 && val[0..5].bytes == [230, 16, 0, 0, 1, 12])
                              )
                            )
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
                if is_mssql_geography
                  if val[0] == 1 && (val[1] & 8 > 0) && # Single point?
                     (val.length - 2) % 8 == 0 && val.length < 27 # And containing up to three 8-byte values?
                    val = [0, 0, 0, 0, 1] + val[2..-1].reverse
                  else
                    val_err = '(Microsoft internal SQL geography type)'
                  end
                end
              end
            end
            unless val_err || val.nil?
              if (geometry = RGeo::WKRep::WKBParser.new.parse(val.pack('c*'))).is_a?(RGeo::Cartesian::PointImpl) &&
                 !(geometry.y == 0.0 && geometry.x == 0.0)
                # Create a POINT link to this style of Google maps URL:  https://www.google.com/maps/place/38.7071296+-121.2810649/@38.7071296,-121.2810649,12z
                geometry = "<a href=\"https://www.google.com/maps/place/#{geometry.y}+#{geometry.x}/@#{geometry.y},#{geometry.x},12z\" target=\"blank\">#{geometry.to_s}</a>"
              end
              val = geometry
            end
            val_err || val
          else
            '(Add RGeo gem to parse geometry detail)'
          end
        when :binary
          ::Brick::Rails.display_binary(val) if val
        else
          if col_type
            ::Brick::Rails::FormBuilder.hide_bcrypt(val, col_type == :xml)
          else
            '?'
          end
        end
      end

      def display_binary(val)
        @image_signatures ||= { (+"\xFF\xD8\xFF\xEE").force_encoding('ASCII-8BIT') => 'jpeg',
                                (+"\xFF\xD8\xFF\xE0\x00\x10\x4A\x46\x49\x46\x00\x01").force_encoding('ASCII-8BIT') => 'jpeg',
                                (+"\xFF\xD8\xFF\xDB").force_encoding('ASCII-8BIT') => 'jpeg',
                                (+"\xFF\xD8\xFF\xE1").force_encoding('ASCII-8BIT') => 'jpeg',
                                (+"\x89PNG\r\n\x1A\n").force_encoding('ASCII-8BIT') => 'png',
                                '<svg' => 'svg+xml', # %%% Not yet very good detection for SVG
                                (+'BM').force_encoding('ASCII-8BIT') => 'bmp',
                                (+'GIF87a').force_encoding('ASCII-8BIT') => 'gif',
                                (+'GIF89a').force_encoding('ASCII-8BIT') => 'gif' }

        if val[0..1] == "\x15\x1C" # One of those goofy Microsoft OLE containers?
          package_header_length = val[2..3].bytes.reverse.inject(0) {|m, b| (m << 8) + b }
          # This will often be just FF FF FF FF
          # object_size = val[16..19].bytes.reverse.inject(0) {|m, b| (m << 8) + b }
          friendly_and_class_names = val[20...package_header_length].split("\0")
          object_type_name_length = val[package_header_length + 8..package_header_length+11].bytes.reverse.inject(0) {|m, b| (m << 8) + b }
          friendly_and_class_names << val[package_header_length + 12...package_header_length + 12 + object_type_name_length].strip
          # friendly_and_class_names will now be something like:  ['Bitmap Image', 'Paint.Picture', 'PBrush']
          real_object_size = val[package_header_length + 20 + object_type_name_length..package_header_length + 23 + object_type_name_length].bytes.reverse.inject(0) {|m, b| (m << 8) + b }
          object_start = package_header_length + 24 + object_type_name_length
          val = val[object_start...object_start + real_object_size]
        end

        if (signature = @image_signatures.find { |k, _v| val[0...k.length] == k }) ||
           (val[0..3] == 'RIFF' && val[8..11] == 'WEBP' && (signature = 'webp'))
          if val.length < 500_000
            "<img src=\"data:image/#{signature.last};base64,#{Base64.encode64(val)}\">"
          else
            "&lt;&nbsp;#{signature.last} image, #{val.length} bytes&nbsp;>"
          end
        else
          "&lt;&nbsp;Binary, #{val.length} bytes&nbsp;>"
        end
      end
    end

    # See http://guides.rubyonrails.org/engines.html
    class Engine < ::Rails::Engine
      JS_CHANGEOUT = "function changeout(href, param, value, trimAfter) {
  var hrefParts = href.split(\"?\");
  var params = hrefParts.length > 1 ? hrefParts[1].split(\"&\") : [];
  if (param === undefined || param === null || param === -1) {
    hrefParts = hrefParts[0].split(\"://\");
    var pathParts = hrefParts[hrefParts.length - 1].split(\"/\").filter(function (pp) {return pp !== \"\";});
    if (value === undefined) {
      // A couple possibilities if it's namespaced, starting with two parts in the path -- and then try just one
      if (pathParts.length > 3)
        return [pathParts.slice(1, 4).join('/'), pathParts.slice(1, 3).join('/')];
      else
        return [pathParts.slice(1, 3).join('/'), pathParts[1]];
    } else {
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

// This PageTransitionEvent fires when the page first loads, as well as after any other history
// transition such as when using the browser's Back and Forward buttons.
window.addEventListener(\"pageshow\", linkSchemas);
var brickSchema,
    brickTestSchema;
function linkSchemas() {
  var schemaSelect = document.getElementById(\"schema\");
  var tblSelect = document.getElementById(\"tbl\");
  if (tblSelect) { // Always present for Brick pages
    // Used to be:  var i = # {::Brick.config.path_prefix ? '0' : 'schemaSelect ? 1 : 0'},
    var changeoutList = changeout(location.href);
    for (var i = 0; i < changeoutList.length; ++i) {
      tblSelect.value = changeoutList[i];
      if (tblSelect.value !== \"\") break;
    }

    tblSelect.addEventListener(\"change\", function () {
      var lhr = changeout(location.href, null, this.value);
      if (brickSchema) lhr = changeout(lhr, \"_brick_schema\", schemaSelect.value);
      location.href = lhr;
    });

    if (schemaSelect) { // First drop-down is only present if multitenant
      if (brickSchema = changeout(location.href, \"_brick_schema\")) {
        [... document.getElementsByTagName(\"A\")].forEach(function (a) { a.href = changeout(a.href, \"_brick_schema\", brickSchema); });
      }
      if (schemaSelect.options.length > 1) {
        schemaSelect.value = brickSchema || brickTestSchema || \"public\";
        schemaSelect.addEventListener(\"change\", function () {
          // If there's an ID then remove it (trim after selected table)
          location.href = changeout(location.href, \"_brick_schema\", this.value, tblSelect.value);
        });
      }
    }
    tblSelect.focus();

    [... document.getElementsByTagName(\"FORM\")].forEach(function (form) {
      if (brickSchema)
        form.action = changeout(form.action, \"_brick_schema\", brickSchema);
      form.addEventListener('submit', function (ev) {
        [... ev.target.getElementsByTagName(\"SELECT\")].forEach(function (select) {
          if (select.value === \"^^^brick_NULL^^^\") select.value = null;
        });
        // Take outer <div> tag off the HTML being returned by any Trix editor
        [... document.getElementsByTagName(\"TRIX-EDITOR\")].forEach(function (trix) {
          var trixHidden = trix.inputElement;
          if (trixHidden) trixHidden.value = trixHidden.value.slice(5, -6);
        });
        return true;
      });
    });
  }
};
"
      BRICK_SVG = "<svg version=\"1.1\" style=\"display: inline; padding-left: 0.5em;\" xmlns=\"http://www.w3.org/2000/svg\" xmlns:xlink=\"http://www.w3.org/1999/xlink\"
  viewBox=\"0 0 58 58\" height=\"1.4em\" xml:space=\"preserve\">
<g>
  <polygon style=\"fill:#C2615F;\" points=\"58,15.831 19.106,35.492 0,26.644 40,6\"/>
  <polygon style=\"fill:#6D4646;\" points=\"19,52 0,43.356 0,26.644 19,35\"/>
  <polygon style=\"fill:#894747;\" points=\"58,31.559 19,52 19,35 58,15.831\"/>
</g>
</svg>
".html_safe

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

        # Treat ActiveStorage::Blob metadata as JSON
        if ::Brick.config.table_name_prefixes.fetch('active_storage_', nil) == 'ActiveStorage' &&
           ActiveStorage.const_defined?('Blob')
          unless (md = (::Brick.config.model_descrips ||= {})).key?('ActiveStorage::Blob')
            md['ActiveStorage::Blob'] = '[filename]'
          end
          unless (asbm = (::Brick.config.json_columns['active_storage_blobs'] ||= [])).include?('metadata')
            asbm << 'metadata'
          end
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

            # class Fields::TextField
            #   alias _original_initialize initialize
            #   def initialize(id, **args, &block)
            #     if instance_of?(::Avo::Fields::TextField) || instance_of?(::Avo::Fields::TextareaField)
            #       args[:format_using] ||= ->(value) do
            #         if value.is_a?(String) && value.encoding != Encoding::UTF_8
            #           value = value.encode!("UTF-8", invalid: :replace, undef: :replace, replace: "?")
            #         end
            #         value
            #       end
            #     end
            #     _original_initialize(id, **args, &block)
            #   end
            # end

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
                      unless existing.key?(class_name = v[:class_name]) || Brick.config.exclude_tables.include?(k) ||
                             class_name.blank? || class_name.include?('::')
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
                if ::Brick.instance_variable_get(:@_brick_avo_js) == view_renderer.object_id
                  _brick_content
                else
                  ::Brick.instance_variable_set(:@_brick_avo_js, view_renderer.object_id)
                  # Avo's logo partial fails if there is not a URL helper called exactly "root_path"
                  # (Finicky line over there is:  avo/app/views/avo/partials/_logo.html.erb:1)
                  unless ::Rails.application.routes.named_routes.names.include?(:root) || ActionView::Base.respond_to?(:root_path)
                    ActionView::Base.class_exec do
                      def root_path
                        Avo.configuration.root_path
                      end
                    end
                  end
"<script>
#{JS_CHANGEOUT}
document.addEventListener(\"turbo:render\", linkSchemas);
window.addEventListener(\"popstate\", linkSchemas);
// [... document.getElementsByTagName('turbo-frame')].forEach(function (a) { a.addEventListener(\"turbo:frame-render\", linkSchemas); });
</script>
#{_brick_content}".html_safe
                end
              end
            end

            # When available, add a clickable brick icon to go to the Brick version of the page
            PanelComponent.class_exec do
              alias _brick_init initialize
              def initialize(*args, **kwargs)
                _brick_init(*args, **kwargs)
                @name = BrickTitle.new(@name, self)
              end
            end

            class BrickTitle
              def initialize(name, view_component)
                @vc = view_component
                @_name = name || ''
              end
              def to_s
                @_name.to_s.html_safe + @vc.instance_variable_get(:@__vc_helpers)&.link_to_brick(nil,
                  BRICK_SVG,
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

            module Concerns::HasFields
              class_methods do
                alias _brick_field field
                def field(name, *args, **kwargs, &block)
                  kwargs.merge!(args.pop) if args.last.is_a?(Hash)
                  _brick_field(name, **kwargs, &block)
                end
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
                begin
                  _brick_url_for(options, *args)
                rescue
                  # Last-ditch effort in case we were in yet a different RouteSet
                  unless (rar = ::Rails.application.routes) == self
                    rar.url_for(options, *args)
                  end
                end
              end
            end
          end
        end # Avo compatibility

        # ActiveAdmin compatibility
        if Object.const_defined?('ActiveAdmin') && ::ActiveAdmin.application&.site_title.present?
          ::ActiveAdmin.class_exec do
            class << self
              ActiveAdmin.load!
              alias _brick_routes routes
              def routes(*args)
                ::Brick.relations.each do |k, v|
                  next if k == 'active_admin_comments'

                  begin
                    if (class_name = Object.const_get(v.fetch(:class_name, nil)))
                      ::ActiveAdmin.register(class_name) { config.clear_batch_actions! }
                    end
                  rescue
                  end
                end
                _brick_routes(*args)
              end
            end
          end
          ::ActiveAdmin::Views::TitleBar.class_exec do
            alias _brick_build_title_tag build_title_tag
            def build_title_tag
              if klass = begin
                           aa_id = helpers.instance_variable_get(:@current_tab)&.id
                           ::Brick.relations.fetch(aa_id, nil)&.fetch(:class_name, nil)&.constantize
                         rescue
                         end
                h2((@title + link_to_brick(nil,
                  BRICK_SVG, # This would do well to be sized a bit smaller
                  { title: "#{@_name} in Brick" }
                )).html_safe)
              else
                _brick_build_title_tag # Revert to the original
              end
            end
          end
          # Build out the main dashboard with default boilerplate if it's missing
          if (namespace = ::ActiveAdmin.application.namespaces.names.first&.to_s) &&
             !Object.const_defined?("#{namespace.camelize}::Dashboard")
            ::ActiveAdmin.register_page "Dashboard" do
              menu priority: 1, label: proc { I18n.t("active_admin.dashboard") }
              content title: proc { I18n.t("active_admin.dashboard") } do
                div class: "blank_slate_container", id: "dashboard_default_message" do
                  span class: "blank_slate" do
                    span I18n.t("active_admin.dashboard_welcome.welcome")
                    small I18n.t("active_admin.dashboard_welcome.call_to_action")
                  end
                end
              end
            end
          end
        end

        # Forest Admin compatibility
        if Object.const_defined?('ForestLiana')
          ForestLiana::Bootstrapper.class_exec do
            alias _brick_fetch_models fetch_models
            def fetch_models
              # Auto-create Brick models
              ::Brick.relations.each do |k, v|
                next if k == 'active_admin_comments'

                begin
                  v[:class_name].constantize
                rescue
                end
              end
              _brick_fetch_models
            end
          end
        end

        # MotorAdmin compatibility
        if Object.const_defined?('Motor') && ::Motor.const_defined?('BuildSchema')
          ::Motor::BuildSchema::LoadFromRails.class_exec do
            class << self
              alias _brick_models models
              def models
                # If RailsAdmin is also present and had already cached its list of models, this builds out the MotorAdmin
                # models differently, so invalidate RailsAdmin's cached list.
                if Object.const_defined?('RailsAdmin') && ::RailsAdmin::Config.class_variable_defined?(:@@system_models)
                  ::RailsAdmin::Config.remove_class_variable(:@@system_models)
                  ::RailsAdmin::AbstractModel.reset
                end

                eager_load_models!
                # Auto-create Brick models (except for those related to Motor::ApplicationRecord)
                mar_tables = Motor::ApplicationRecord.descendants.map(&:table_name)
                # Add JSON fields
                if mar_tables.include?('motor_api_configs')
                  mac = (::Brick.config.json_columns['motor_api_configs'] ||= [])
                  mac += ['preferences', 'credentials']
                end
                (::Brick.config.json_columns['motor_audits'] ||= []) << 'audited_changes' if mar_tables.include?('motor_audits')
                (::Brick.config.json_columns['motor_configs'] ||= []) << 'value' if mar_tables.include?('motor_configs')
                ::Brick.relations.each do |k, v|
                  next if mar_tables.include?(k) || k == 'motor_audits'

                  v[:class_name].constantize
                end
                _brick_models.reject { |m| mar_tables.include?(m.table_name) || m.table_name == 'motor_audits' }
              end
            end
          end
        end

        # Unconfigured Mobility gem?
        if Object.const_defined?('Mobility') && Mobility.respond_to?(:translations_class)
          # Find the current defaults
          defs = if Mobility.instance_variable_defined?(:@translations_class)
                   ::Mobility.translations_class.defaults
                 else
                   {}
                 end
          # Fill in the blanks for any missing defaults
          ::Mobility.configure do |config|
            config.plugins do
              # Default initializer would also set these:
              #  :backend_reader=>true
              #  :query=>:i18n
              #  :cache=>true
              #  :presence=>true
              backend :key_value, type: :string unless defs.key?(:backend)
              reader unless defs.key?(:reader)
              writer unless defs.key?(:writer)
              active_record unless ::Mobility::Plugins.instance_variable_get(:@plugins)&.key?(:active_record)
              fallbacks false unless defs.key?(:fallbacks)
              default nil unless defs.key?(:default)
            end
          end
        end

        # Spina compatibility
        if Object.const_defined?('Spina')
          # Add JSON fields
          (::Brick.config.json_columns['spina_accounts'] ||= []) << 'json_attributes' if ::Spina.const_defined?('Account')
          (::Brick.config.json_columns['spina_pages'] ||= []) << 'json_attributes' if ::Spina.const_defined?('Page')
        end

        # ====================================
        # Dynamically create generic templates
        # ====================================
        if ::Brick.enable_views?
          # Add the params to the lookup_context so that we have context about STI classes when setting @_brick_model
          ActionView::ViewPaths.class_exec do
            alias :_brick_lookup_context :lookup_context
            def lookup_context(*args)
              ret = _brick_lookup_context(*args)
              @_lookup_context.instance_variable_set(:@_brick_req_params, params)
              ret
            end
          end

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
               set_brick_model(args, @_brick_req_params))
            end

            def set_brick_model(find_args, params)
              # Return an appropriate model for a given view template request.
              # find_args will generally be something like:  ["index", ["categories"]]
              # and must cycle through all of find_args[1] because in some cases such as with Devise we get something like:
              # ["create", ["users/sessions", "sessions", "devise/sessions", "devise", "application"], false, []]
              find_args[1]&.any? do |resource_name|
                if (class_name = (resource_parts = resource_name.split('/')).last&.singularize)
                  resource_parts[-1] = class_name # Make sure the last part, defining the class name, is singular
                  begin
                    if (model = Object.const_get(resource_parts.map(&:camelize).join('::')))&.is_a?(Class) && (
                         ['index', 'show'].include?(find_args.first) || # Everything has index and show
                         # Only CUD stuff has create / update / destroy
                         (!model.is_view? && ['new', 'create', 'edit', 'update', 'destroy'].include?(find_args.first))
                       )
                      @_brick_model = model.real_model(params)
                    end
                  rescue
                  end
                end
              end
              @_brick_model
            end

            def path_keys(hm_assoc, fk_name, pk)
              pk.map!(&:to_sym)
              keys = if fk_name.is_a?(Array) && pk.is_a?(Array) # Composite keys?
                       fk_name.zip(pk)
                     else
                       [[fk_name, pk.length == 1 ? pk.first : pk.inspect]]
                     end
              if hm_assoc.options.key?(:as)
                poly_type = if hm_assoc.active_record.column_names.include?(hm_assoc.active_record.inheritance_column)
                              '[sti_type]'
                            else
                              hm_assoc.active_record.name
                            end
                keys << [hm_assoc.inverse_of.foreign_type, poly_type]
              end
              keys.to_h
            end

            alias :_brick_find_template :find_template
            def find_template(*args, **options)
              find_template_err = nil
              unless (model_name = @_brick_model&.name) ||
                     (is_status = ::Brick.config.add_status && args[0..1] == ['status', ['brick_gem']]) ||
                     (is_orphans = ::Brick.config.add_orphans && args[0..1] == ['orphans', ['brick_gem']]) ||
                     (is_crosstab = args[0..1] == ['crosstab', ['brick_gem']])
                begin
                  if (possible_template = _brick_find_template(*args, **options))
                    return possible_template
                  end
                rescue StandardError => e
                  # Search through the routes to confirm that something might match (Devise stuff for instance, which has its own view templates),
                  # and bubble the same exception (probably an ActionView::MissingTemplate) if a legitimate option is found.
                  raise if ::Rails.application.routes.set.find { |x| args[1].include?(x.defaults[:controller]) && args[0] == x.defaults[:action] }

                  find_template_err = e
                end
                # Used to also have:  ActionView.version < ::Gem::Version.new('5.0') &&
                model_name = set_brick_model(args, @_brick_req_params)&.name
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
                                  if hm_assoc.klass.column_names.include?(hm_fk_name) ||
                                     (hm_fk_name.is_a?(String) && hm_fk_name.include?('.')) # HMT?  (Could do a better check for this)
                                    predicates = path_keys(hm_assoc, hm_fk_name, pk).map do |k, v|
                                                   if v == '[sti_type]'
                                                     "'#{k}': (@#{obj_name}.#{hm_assoc.active_record.inheritance_column}).constantize.base_class.name"
                                                   else
                                                     v.is_a?(String) ? "'#{k}': '#{v}'" : "'#{k}': @#{obj_name}.#{v}"
                                                   end
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
              table_options = ::Brick.relations.each_with_object({}) do |rel, s|
                                next if ::Brick.config.exclude_tables.include?(rel.first)

                                tbl_parts = rel.first.split('.')
                                if (aps = rel.last.fetch(:auto_prefixed_schema, nil))
                                  tbl_parts << tbl_parts.last[aps.length..-1]
                                  aps = aps[0..-2] if aps[-1] == '_'
                                  tbl_parts[-2] = aps
                                end
                                if tbl_parts.first == apartment_default_schema
                                  tbl_parts.shift
                                end
                                # %%% When table_name_prefixes are use then during rendering empty non-TNP
                                # entries get added at some point when an attempt is made to find the table.
                                # Will have to hunt that down at some point.
                                s[tbl_parts.join('.')] = nil unless rel.last[:cols].empty?
                              end.keys.sort.each_with_object(+'') do |v, s|
                                s << "<option value=\"#{prefix}#{v.underscore.gsub('.', '/')}\">#{v}</option>"
                              end.html_safe
              table_options << "<option value=\"#{prefix}brick_status\">(Status)</option>".html_safe if ::Brick.config.add_status
              table_options << "<option value=\"#{prefix}brick_orphans\">(Orphans)</option>".html_safe if is_orphans
              table_options << "<option value=\"#{prefix}brick_orphans\">(Crosstab)</option>".html_safe if is_crosstab
              css = +"<style>
#titleSticky {
  position: sticky;
  display: inline-block;
  left: 0;
}

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
<script>
  if (window.history.state && window.history.state.turbo)
    window.addEventListener(\"popstate\", function () { location.reload(true); });
</script>

<%
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
}\".html_safe
  aa_png = \"<img src=\\\"data:image/png;base64,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\\\">\".html_safe
%>"

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
var #{table_name}HtColumns;

// Add \"Are you sure?\" behaviour to any data-confirm buttons out there
document.querySelectorAll(\"input[type=submit][data-confirm]\").forEach(function (btn) {
  btn.addEventListener(\"click\", function (evt) {
    if (!confirm(this.getAttribute(\"data-confirm\"))) {
      evt.preventDefault();
      return false;
    }
  });
});

#{JS_CHANGEOUT}#{
  "\nbrickTestSchema = \"#{::Brick.test_schema}\";" if ::Brick.test_schema
}
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
  if (grid.clientWidth > window.outerWidth)
    document.getElementById(\"titleBox\").style.width = grid.clientWidth;
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
     is_has_one = #{@_brick_model.name}.reflect_on_association(bt.first)&.inverse_of&.macro == :has_one ||
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
 @_brick_monetized_attributes = model.respond_to?(:monetized_attributes) ? model.monetized_attributes.values : {}
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
<title><%= (model = #{model_name}).name %><%
     if (description = (relation = Brick.relations[model.table_name])&.fetch(:description, nil)).present?
       %> - <%= description
%><% end
%></title>
</head>
<body>
<div id=\"titleBox\"><div id=\"titleSticky\">
<p style=\"color: green\"><%= notice if request.respond_to?(:flash) %></p>#{"
#{schema_options}" if schema_options}
<select id=\"tbl\">#{table_options}</select>
<table id=\"resourceName\"><tr>
  <td><h1><%= td_count = 2
              model.name %></h1></td>
  <td id=\"imgErd\" title=\"Show ERD\"></td>
  <% if Object.const_defined?('Avo') && ::Avo.respond_to?(:railtie_namespace) && model.name.exclude?('::')
       td_count += 1 %>
    <td><%= link_to_brick(
        avo_svg,
        { index_proc: Proc.new do |_avo_model, relation|
                        path_helper = \"resources_#\{relation.fetch(:auto_prefixed_schema, nil)}#\{model.model_name.route_key}_path\".to_sym
                        ::Avo.railtie_routes_url_helpers.send(path_helper) if ::Avo.railtie_routes_url_helpers.respond_to?(path_helper)
                      end,
          title: \"#\{model.name} in Avo\" }
      ) %></td>
  <% end %>
  <% if Object.const_defined?('ActiveAdmin')
       ActiveAdmin.application.namespaces.names.each do |ns|
         td_count += 1 %>
      <td><%= link_to_brick(
          aa_png,
          { index_proc: Proc.new do |aa_model, relation|
                          path_helper = \"#\{ns}_#\{relation.fetch(:auto_prefixed_schema, nil)}#\{rk = aa_model.model_name.route_key}_path\".to_sym
                          send(path_helper) if respond_to?(path_helper)
                        end,
            title: \"#\{model.name} in ActiveAdmin\" }
        ) %></td>
  <%   end
     end %>
</tr>

<%= if model < (base_model = model.base_class)
      this_model = model
      parent_links = []
      until this_model == base_model do
        this_model = this_model.superclass
        path = send(\"#\{this_model._brick_index}_path\")
        path << \"?#\{base_model.inheritance_column}=#\{this_model.name}\" unless this_model == base_model
        parent_links << link_to(this_model.name, path)
      end
      \"<tr><td colspan=\\\"#\{td_count}\\\">Parent: #\{parent_links.join(' ')}</tr>\".html_safe
    end
%><%= if (children = model.descendants).present?
  child_links = children.map do |child|
    path = send(\"#\{child._brick_index}_path\") + \"?#\{base_model.inheritance_column}=#\{child.name}\"
    link_to(child.name, path)
  end
  \"<tr><td colspan=\\\"#\{td_count}\\\">Children: #\{child_links.join(' ')}</tr>\".html_safe
end
%><%= if (page_num = @#{table_name}._brick_page_num)
           \"<tr><td colspan=\\\"#\{td_count}\\\">Page #\{page_num}</td></tr>\".html_safe
         end %></table>#{template_link}<%
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
          (objs = (destination = origin.reflect_on_association(destination_fk[:assoc_name])&.klass)&.find(id))
         objs = [objs] unless objs.is_a?(Array) %>
         <h3>for <% objs.each do |obj| %><%=
                      link_to \"#{"#\{obj.brick_descrip\} (#\{destination.name\})\""}, send(\"#\{destination._brick_index(:singular)\}_path\".to_sym, id)
               %><% end %></h3><%
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
</div></div>
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

#{"<hr><%= link_to(\"New #{new_path_name = "new_#{path_obj_name}_path"
                           obj_name}\", #{new_path_name}) if respond_to?(:#{new_path_name}) %>" unless @_brick_model.is_view?}
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
<p style=\"color: green\"><%= notice if request.respond_to?(:flash) %></p>#{"
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
<p style=\"color: green\"><%= notice if request.respond_to?(:flash) %></p>#{"
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
  base_model = (model = (obj = @#{obj_name})&.class).base_class
  see_all_path = send(\"#\{base_model._brick_index}_path\")
#{(inh_col = @_brick_model.inheritance_column).present? &&
"  if obj.respond_to?(:#{inh_col}) && (model_name = @#{obj_name}.#{inh_col}) != base_model.name
    see_all_path << \"?#{inh_col}=#\{model_name}\"
  end"}
  page_title = (\"#\{model_name ||= model.name}: #\{obj&.brick_descrip || controller_name}\")
%></title>
</head>
<body>

<svg id=\"revertTemplate\" version=\"1.1\" xmlns=\"http://www.w3.org/2000/svg\" xmlns:xlink=\"http://www.w3.org/1999/xlink\"
  width=\"32px\" height=\"32px\" viewBox=\"0 0 512 512\" xml:space=\"preserve\">
<path id=\"revertPath\" fill=\"#2020A0\" d=\"M271.844,119.641c-78.531,0-148.031,37.875-191.813,96.188l-80.172-80.188v256h256l-87.094-87.094
  c23.141-70.188,89.141-120.906,167.063-120.906c97.25,0,176,78.813,176,176C511.828,227.078,404.391,119.641,271.844,119.641z\" />
</svg>

<p style=\"color: green\"><%= notice if request.respond_to?(:flash) %></p>#{"
#{schema_options}" if schema_options}
<select id=\"tbl\">#{table_options}</select>
<table><td><h1><%= page_title %></h1></td>
<% if Object.const_defined?('Avo') && ::Avo.respond_to?(:railtie_namespace) %>
  <td><%= link_to_brick(
      avo_svg,
      { show_proc: Proc.new do |obj, relation|
                     path_helper = \"resources_#\{relation.fetch(:auto_prefixed_schema, nil)}#\{obj.class.base_class.model_name.singular_route_key}_path\".to_sym
                     ::Avo.railtie_routes_url_helpers.send(path_helper, obj) if ::Avo.railtie_routes_url_helpers.respond_to?(path_helper)
                   end,
        title: \"#\{page_title} in Avo\" }
    ) %></td>
<% end

   if Object.const_defined?('ActiveAdmin')
     ActiveAdmin.application.namespaces.names.each do |ns| %>
<td><%= link_to_brick(
   aa_png,
   { show_proc: Proc.new do |aa_model, relation|
                  path_helper = \"#\{ns}_#\{relation.fetch(:auto_prefixed_schema, nil)}#\{rk = aa_model.model_name.singular_route_key}_path\".to_sym
                  send(path_helper, obj) if respond_to?(path_helper)
                end,
     title: \"#\{page_title} in ActiveAdmin\" }
 ) %></td>
<%   end
   end %>
</table>
<%
if (description = (relation = Brick.relations[#{model_name}.table_name])&.fetch(:description, nil)) %><%=
  description %><br><%
end
%><%= link_to \"(See all #\{model_name.pluralize})\", see_all_path %>
#{erd_markup}
<% if obj
     # path_options = [obj.#{pk}]
     # path_options << { '_brick_schema':  } if
     options = {}
     if ::Brick.config.path_prefix
       path_helper = obj.new_record? ? #{model_name}._brick_index : #{model_name}._brick_index(:singular)
       options[:url] = send(\"#\{path_helper}_path\".to_sym, obj)
     end
%>
  <br><br>
<%= form_for(obj.becomes(#{model_name}), options) do |f| %>
  <table class=\"shadow\">
  <% has_fields = false
     @#{obj_name}.attributes.each do |k, val|
       next if !(col = #{model_name}.columns_hash[k]) ||
               (#{(pk.map(&:to_s) || []).inspect}.include?(k) && !bts.key?(k)) ||
               ::Brick.config.metadata_columns.include?(k) %>
    <tr>
    <th class=\"show-field\"<%= \" title=\\\"#\{col.comment}\\\"\".html_safe if col.respond_to?(:comment) && !col.comment.blank? %>>
<%    has_fields = true
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
      <%= f.brick_field(k, html_options = {}, val, col, bt, bt_class, bt_name, bt_pair) %>
    </td>
    </tr>
  <% end
  if has_fields %>
    <tr><td colspan=\"2\"><%= f.submit({ class: 'update' }) %></td></tr>
  <% else %>
    <tr><td colspan=\"2\">(No displayable fields)</td></tr>
  <% end %>
  </table>#{
  "<%= ::Brick::Rails.display_binary(obj.blob&.download).html_safe %>" if model_name == 'ActiveStorage::Attachment'}
<%  end %>

#{unless args.first == 'new'
  # Was:  confirm_are_you_sure = ActionView.version < ::Gem::Version.new('7.0') ? "data: { confirm: 'Delete #\{model_name} -- Are you sure?' }" : "form: { data: { turbo_confirm: 'Delete #\{model_name} -- Are you sure?' } }"
  confirm_are_you_sure = "data: { confirm: 'Delete #\{model_name} -- Are you sure?' }"
  hms_headers.each_with_object(+'') do |hm, s|
    # %%% Would be able to remove this when multiple foreign keys to same destination becomes bulletproof
    next if hm.first.options[:through] && !hm.first.through_reflection

    if (pk = hm.first.klass.primary_key)
      hm_singular_name = (hm_name = hm.first.name.to_s).singularize.underscore
      obj_pk = (pk.is_a?(Array) ? pk : [pk]).each_with_object([]) { |pk_part, s| s << "#{hm_singular_name}.#{pk_part}" }.join(', ')
      poly_fix = if (poly_type = (hm.first.options[:as] && hm.first.type))
                   "
                     # Let's fix an unexpected \"feature\" of AR -- when going through a polymorphic has_many
                     # association that points to an STI model then filtering for the __able_type column is done
                     # with a .where(). And the polymorphic class name it points to is the base class name of
                     # the STI model instead of its subclass.
                     poly_type = #{poly_type.inspect}
#{                   (inh_col = @_brick_model.inheritance_column).present? &&
"                    if poly_type && @#{obj_name}.respond_to?(:#{inh_col}) &&
                        (base_type = collection.where_values_hash[poly_type])
                       collection = collection.rewhere(poly_type => [base_type, @#{obj_name}.#{inh_col}])
                     end"}"
                 end
      s << "<table id=\"#{hm_name}\" class=\"shadow\">
        <tr><th>#{hm[1]}#{' poly' if hm[0].options[:as]} #{hm[3]}</th></tr>
        <% collection = @#{obj_name}.#{hm_name}
        collection = case collection
                     when ActiveRecord::Associations::CollectionProxy#{
                       poly_fix}
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
                       else # args.first isn't index / show / edit / new / orphans / status
                         if find_template_err # Can surface when gems have their own view templates
                           raise find_template_err
                         else # Can surface if someone made their own controller which has a screwy action
                           puts "Couldn't work with action #{args.first}"
                         end
                       end
              unless is_crosstab
                inline << "
<% if @_date_fields_present %>
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

<% if false # @_dropdown_fields_present %>
<script src=\"https://cdnjs.cloudflare.com/ajax/libs/slim-select/1.27.1/slimselect.min.js\"></script>
<link rel=\"stylesheet\" type=\"text/css\" href=\"https://cdnjs.cloudflare.com/ajax/libs/slim-select/1.27.1/slimselect.min.css\">
<% end %>

<% if @_text_fields_present %>
<script src=\"https://cdn.jsdelivr.net/npm/trix@2.0/dist/trix.umd.min.js\"></script>
<link rel=\"stylesheet\" type=\"text/css\" href=\"https://cdn.jsdelivr.net/npm/trix@2.0/dist/trix.min.css\">
<% end %>

<% # Started with v0.14.4 of vanilla-jsoneditor
   if @_json_fields_present %>
<link rel=\"stylesheet\" type=\"text/css\" href=\"https://cdn.jsdelivr.net/npm/vanilla-jsoneditor/themes/jse-theme-default.min.css\">
<script type=\"module\">
  import { JSONEditor } from \"https://cdn.jsdelivr.net/npm/vanilla-jsoneditor/index.min.js\";
  document.querySelectorAll(\"input.jsonpicker\").forEach(function (inp) {
    var jsonDiv;
    if (jsonDiv = document.getElementById(\"_br_json_\" + inp.id)) {
      new JSONEditor({
        target: jsonDiv,
        props: {
          // Instead of text can also do: { json: JSONValue }
          // Other options:  name: \"taco\", mode: \"tree\", navigationBar: false, mainMenuBar: false, statusBar: false, search: false, templates:, history: false
          content: {text: inp.value.replace(/`/g, '\"').replace(/\\^\\^br_btick__/g, \"`\")},
          onChange: (function (inp2) {
            return function (updatedContent, previousContent, contentErrors, patchResult) {
              // console.log('onChange', updatedContent.json, updatedContent.text);
              inp2.value = (updatedContent.text || JSON.stringify(updatedContent.json)).replace(/`/g, \"\\^\\^br_btick__\").replace(/\"/g, '`');
            };
          })(inp)
        }
      });
    } else {
      console.log(\"Could not find JSON picker for \" + inp.id);
    }
  });
</script>
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
    mermaidErd.style.display = \"block\";
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
                return _brick_viable_models if ::RailsAdmin::Config.class_variables.include?(:@@system_models)

                brick_models = ::Brick.relations.map { |_k, v| v[:class_name] }

                # The original from RailsAdmin (now aliased as _brick_viable_models) loads all classes
                # in the whole project. This Brick approach is a little more tame.
                ::Brick.eager_load_classes
                # All tables used by non-Brick models
                ar_tables = (arbd = ActiveRecord::Base.descendants).each_with_object([]) do |ar, s|
                  s << ar.table_name unless brick_models.include?(ar.name)
                end
                viable = arbd.each_with_object([]) do |ar, s|
                  # Include all the app's models, plus any Brick models which describe tables not covered by the app's models
                  unless ar.abstract_class? || (brick_models.include?(ar.name) && ar_tables.include?(ar.table_name))
                    s << ar.name
                  end
                end
                RailsAdmin::Config.class_variable_set(:@@system_models, viable)
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
