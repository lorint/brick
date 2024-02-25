# frozen_string_literal: true

module Brick
  module Rails
    class << self
      def display_value(col_type, val, lat_lng = nil)
        is_mssql_geography = nil
        # Some binary thing that really looks like a Microsoft-encoded WGS84 point?  (With the first two bytes, E6 10, indicating an EPSG code of 4326)
        if col_type == :binary && val && ::Brick.is_geography?(val)
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
                                (val && ::Brick.is_geography?(val))
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
              val = if ((geometry = RGeo::WKRep::WKBParser.new.parse(val.pack('c*'))).is_a?(RGeo::Cartesian::PointImpl) ||
                        geometry.is_a?(RGeo::Geos::CAPIPointImpl)) &&
                       !(geometry.y == 0.0 && geometry.x == 0.0)
                      # Create a POINT link to this style of Google maps URL:  https://www.google.com/maps/place/38.7071296+-121.2810649/@38.7071296,-121.2810649,12z
                      "<a href=\"https://www.google.com/maps/place/#{geometry.y}+#{geometry.x}/@#{geometry.y},#{geometry.x},12z\" target=\"blank\">#{geometry.to_s}</a>"
                    end
            end
            val_err || val
          else
            '(Add RGeo gem to parse geometry detail)'
          end
        when :binary
          ::Brick::Rails.display_binary(val)
        else
          if col_type
            if lat_lng && !(lat_lng.first.zero? && lat_lng.last.zero?)
              # Create a link to this style of Google maps URL:  https://www.google.com/maps/place/38.7071296+-121.2810649/@38.7071296,-121.2810649,12z
              "<a href=\"https://www.google.com/maps/place/#{lat_lng.first}+#{lat_lng.last}/@#{lat_lng.first},#{lat_lng.last},12z\" target=\"blank\">#{val}</a>"
            elsif val.is_a?(Numeric) && ::ActiveSupport.const_defined?(:NumberHelper)
              ::ActiveSupport::NumberHelper.number_to_delimited(val, delimiter: ',')
            else
              ::Brick::Rails::FormBuilder.hide_bcrypt(val, col_type == :xml)
            end
          else
            '?'
          end
        end
      end

      def display_binary(val, max_size = 100_000)
        return unless val

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

        if ((signature = @image_signatures.find { |k, _v| val[0...k.length] == k }&.last) ||
            (val[0..3] == 'RIFF' && val[8..11] == 'WEBP' && binding.local_variable_set(:signature, 'webp'))) &&
           val.length < max_size
          "<img src=\"data:image/#{signature.last};base64,#{Base64.encode64(val)}\">"
        else
          "&lt;&nbsp;#{signature ? "#{signature} image" : 'Binary'}, #{val.length} bytes&nbsp;>"
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
"

      # paths['app/models'] << 'lib/brick/frameworks/active_record/models'
      config.brick = ActiveSupport::OrderedOptions.new
      ActiveSupport.on_load(:before_initialize) do |app|
        if ::Rails.application.respond_to?(:reloader)
          ::Rails.application.reloader.to_prepare { Module.class_exec &::Brick::ADD_CONST_MISSING }
        else # For Rails < 5.0, just load it once at the start
          Module.class_exec &::Brick::ADD_CONST_MISSING
        end
        require 'brick/join_array'
        is_development = (ENV['RAILS_ENV'] || ENV['RACK_ENV'])  == 'development'
        ::Brick.enable_models = app.config.brick.fetch(:enable_models, true)
        ::Brick.enable_controllers = app.config.brick.fetch(:enable_controllers, is_development)
        ::Brick.enable_views = app.config.brick.fetch(:enable_views, is_development)
        ::Brick.enable_routes = app.config.brick.fetch(:enable_routes, is_development)
        ::Brick.skip_database_views = app.config.brick.fetch(:skip_database_views, false)

        # Specific database tables and views to omit when auto-creating models
        ::Brick.exclude_tables = app.config.brick.fetch(:exclude_tables, [])

        # When table names have specific prefixes, automatically place them in their own module with a table_name_prefix.
        ::Brick.config.table_name_prefixes ||= app.config.brick.fetch(:table_name_prefixes, {})

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

        # accepts_nested_attributes_for relationships
        ::Brick.nested_attributes = app.config.brick.fetch(:nested_attributes, nil)

        # Polymorphic associations
        ::Brick.polymorphics = app.config.brick.fetch(:polymorphics, nil)
      end

      # After we're initialized and before running the rest of stuff, put our configuration in place
      ActiveSupport.on_load(:after_initialize) do |app|
        # assets_path = File.expand_path("#{__dir__}/../../../../vendor/assets")
        # if (app_config = app.config).respond_to?(:assets)
        #   (app_config.assets.precompile ||= []) << "#{assets_path}/images/brick_erd.png"
        #   (app.config.assets.paths ||= []) << assets_path
        # end

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
              alias _brick_resources_path resources_path
              # Accommodate STI resources
              def resources_path(resource:, **kwargs)
                resource ||= if (klass = resource.model_class)
                               Avo::App.resources.find { |r| r.model_class > klass }
                             end
                _brick_resources_path(resource: resource, **kwargs)
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

            if self.const_defined?('Resources') &&
               self::Resources.const_defined?('ResourceManager') # Avo 3.x?
              self::Resources::ResourceManager.class_exec do
                class << self
                  alias _brick_fetch_resources fetch_resources
                  def fetch_resources
                    Avo._brick_avo_resources
                    _brick_fetch_resources
                  end
                end
              end
            elsif self::App.respond_to?(:eager_load) # Avo 2.x (compatible with 2.20.0 and up)
              App.class_exec do
                class << self
                  alias _brick_eager_load eager_load
                  def eager_load(entity)
                    Avo._brick_avo_resources(true) if entity == :resources
                    _brick_eager_load(entity)
                  end
                end
              end
            end

            def self._brick_avo_resources(is_2x = nil)
              possible_schema, _x1, _x2 = ::Brick.get_possible_schemas
              if possible_schema
                orig_tenant = Apartment::Tenant.current
                Apartment::Tenant.switch!(possible_schema)
              end
              existing = Avo::BaseResource.descendants.each_with_object({}) do |r, s|
                           s[r.name[0..-9]] = nil if r.name.end_with?('Resource')
                         end
              ::Brick.relations.each do |k, v|
                unless k.is_a?(Symbol) || existing.key?(class_name = v[:class_name]) || Brick.config.exclude_tables.include?(k) ||
                       class_name.blank? || class_name.include?('::') ||
                       ['ActiveAdminComment', 'MotorAlert', 'MotorAlertLock', 'MotorApiConfig', 'MotorAudit', 'MotorConfig', 'MotorDashboard', 'MotorForm', 'MotorNote', 'MotorNoteTag', 'MotorNoteTagTag', 'MotorNotification', 'MotorQuery', 'MotorReminder', 'MotorResource', 'MotorTag', 'MotorTaggableTag'].include?(class_name)
                  if is_2x # Avo 2.x?
                    "::#{class_name}Resource".constantize
                  else # Avo 3.x
                    unless ::Avo::BaseResource.constants.include?(class_name.to_sym) ||
                           ::Avo::Resources.constants.include?(class_name.to_sym)
                      ::Brick.avo_3x_resource(Object.const_get(class_name), class_name)
                    end
                  end
                end
              end
              Apartment::Tenant.switch!(orig_tenant) if orig_tenant
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
                  BRICK_SVG.html_safe,
                  { title: "#{@_name} in Brick" }
                )
              end
            end

            class Fields::IndexComponent
              if respond_to?(:resource_view_path)
                alias _brick_resource_view_path resource_view_path
                def resource_view_path
                  mdl_class = @resource.respond_to?(:model_class) ? @resource.model_class : @resource.model&.class
                  return if mdl_class&.is_view?

                  _brick_resource_view_path
                end
              end
            end

            module Concerns::HasFields
              class << self
                if respond_to?(:field)
                  alias _brick_field field
                  def field(name, *args, **kwargs, &block)
                    kwargs.merge!(args.pop) if args.last.is_a?(Hash)
                    _brick_field(name, **kwargs, &block)
                  end
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
                  next if k.is_a?(Symbol) || k == 'active_admin_comments'

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
                  BRICK_SVG.html_safe, # This would do well to be sized a bit smaller
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
                next if k.is_a?(Symbol) || k == 'active_admin_comments'

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
                  next if k.is_a?(Symbol) || mar_tables.include?(k) || k == 'motor_audits'

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
          if ActionView.const_defined?('ViewPaths')
            ActionView::ViewPaths.class_exec do
              alias :_brick_lookup_context :lookup_context
              def lookup_context(*args)
                ret = _brick_lookup_context(*args)
                @_lookup_context.instance_variable_set(:@_brick_req_params, params) if self.class < AbstractController::Base && params
                ret
              end
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
                    resource_parts.shift if resource_parts.first == ::Brick.config.path_prefix
                    if (model = Object.const_get(resource_parts.map { |p| ::Brick.namify(p, :underscore).camelize }.join('::')))&.is_a?(Class) && (
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
              if hm_assoc.options.key?(:as) && !(hmaar = hm_assoc.active_record).abstract_class?
                poly_type = if hmaar.column_names.include?(hmaar.inheritance_column)
                              '[sti_type]'
                            else
                              hmaar.name
                            end
                # %%% Might only need hm_assoc.type and not the first part :)
                type_col = hm_assoc.inverse_of&.foreign_type || hm_assoc.type
                keys << [type_col, poly_type]
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
                  raise if ActionView.version >= ::Gem::Version.new('5.0') &&
                           ::Rails.application.routes.set.find { |x| args[1].include?(x.defaults[:controller]) && args[0] == x.defaults[:action] }

                  find_template_err = e
                end
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

                                 # Should handle standard HMT, which is HM -> BT, as well as HM -> HM style HMT
                                 tbl_nm = hm_assoc.source_reflection&.inverse_of&.name
                                 # If there is no inverse available for the source belongs_to association, infer one based on the class name
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
                    predicates = nil
                    hm_stuff << if hm_fk_name
                                  if (hm_fk_name.is_a?(Array) && # Composite key?
                                      hm_fk_name.all? { |hm_fk_part| hm_assoc.klass.column_names.include?(hm_fk_part) }) ||
                                     hm_assoc.klass.column_names.include?(hm_fk_name.to_s) ||
                                     (hm_fk_name.is_a?(String) && hm_fk_name.include?('.')) # HMT?  (Could do a better check for this)
                                    predicates = path_keys(hm_assoc, hm_fk_name, pk).map do |k, v|
                                                   if v == '[sti_type]'
                                                     "'__#{k}': (@#{obj_name}.#{hm_assoc.active_record.inheritance_column})&.constantize&.base_class&.name"
                                                   else
                                                     v.is_a?(String) ? "'__#{k}': '#{v}'" : "'__#{k}': @#{obj_name}.#{v}"
                                                   end
                                                 end.join(', ')
                                    "<%= link_to '#{assoc_name}', #{hm_assoc.klass._brick_index}_path(predicates = { #{predicates} }) %>\n"
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
              table_rels = if ::Brick.config.omit_empty_tables_in_dropdown
                             ::Brick.relations.reject { |k, v| k.is_a?(Symbol) || v[:rowcount] == 0 }
                           else
                             ::Brick.relations
                           end
              table_options = table_rels.sort do |a, b|
                                a[0] = '' if a[0].is_a?(Symbol)
                                b[0] = '' if b[0].is_a?(Symbol)
                                a.first <=> b.first
                              end.each_with_object(+'') do |rel, s|
                                next if rel.first.blank? || rel.last[:cols].empty? ||
                                        ::Brick.config.exclude_tables.include?(rel.first)

                                # %%% When table_name_prefixes are use then during rendering empty non-TNP
                                # entries get added at some point when an attempt is made to find the table.
                                # Will have to hunt that down at some point.
                                if (rowcount = rel.last.fetch(:rowcount, nil))
                                  rowcount = rowcount > 0 ? " (#{rowcount})" : nil
                                end
                                s << "<option value=\"#{::Brick._brick_index(rel.first, nil, '/', nil, true)}\">#{rel.first}#{rowcount}</option>"
                              end.html_safe
              prefix = "#{::Brick.config.path_prefix}/" if ::Brick.config.path_prefix
              table_options << "<option value=\"#{prefix}brick_status\">(Status)</option>".html_safe if ::Brick.config.add_status
              table_options << "<option value=\"#{prefix}brick_orphans\">(Orphans)</option>".html_safe if is_orphans
              table_options << "<option value=\"#{prefix}brick_crosstab\">(Crosstab)</option>".html_safe if is_crosstab
              css = +"<style>
#titleSticky {
  position: sticky;
  display: inline-block;
  left: 0;
  z-index: 2;
}

.flashNotice {
  color: green;
}
.flashAlert {
  color: red;
}

h1, h3 {
  margin-bottom: 0;
}
#rowCount {
  display: table-cell;
  height: 32px;
  vertical-align: middle;
  font-size: 0.9em;
  font-family: sans-serif;
}
#imgErd {
  display: table-cell;
  background-image:url(data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAE0AAABNCAMAAADU1xmCAAAABGdBTUEAALGPC/xhBQAAAAFzUkdCAK7OHOkAAARxaVRYdFhNTDpjb20uYWRvYmUueG1wAAAAAAA8eDp4bXBtZXRhIHhtbG5zOng9ImFkb2JlOm5zOm1ldGEvIiB4OnhtcHRrPSJYTVAgQ29yZSA2LjAuMCI+CiAgIDxyZGY6UkRGIHhtbG5zOnJkZj0iaHR0cDovL3d3dy53My5vcmcvMTk5OS8wMi8yMi1yZGYtc3ludGF4LW5zIyI+CiAgICAgIDxyZGY6RGVzY3JpcHRpb24gcmRmOmFib3V0PSIiCiAgICAgICAgICAgIHhtbG5zOnRpZmY9Imh0dHA6Ly9ucy5hZG9iZS5jb20vdGlmZi8xLjAvIgogICAgICAgICAgICB4bWxuczp4bXBNTT0iaHR0cDovL25zLmFkb2JlLmNvbS94YXAvMS4wL21tLyIKICAgICAgICAgICAgeG1sbnM6c3RSZWY9Imh0dHA6Ly9ucy5hZG9iZS5jb20veGFwLzEuMC9zVHlwZS9SZXNvdXJjZVJlZiMiCiAgICAgICAgICAgIHhtbG5zOnhtcD0iaHR0cDovL25zLmFkb2JlLmNvbS94YXAvMS4wLyI+CiAgICAgICAgIDx0aWZmOllSZXNvbHV0aW9uPjcyPC90aWZmOllSZXNvbHV0aW9uPgogICAgICAgICA8dGlmZjpYUmVzb2x1dGlvbj43MjwvdGlmZjpYUmVzb2x1dGlvbj4KICAgICAgICAgPHRpZmY6T3JpZW50YXRpb24+MTwvdGlmZjpPcmllbnRhdGlvbj4KICAgICAgICAgPHhtcE1NOkRlcml2ZWRGcm9tIHJkZjpwYXJzZVR5cGU9IlJlc291cmNlIj4KICAgICAgICAgICAgPHN0UmVmOmluc3RhbmNlSUQ+eG1wLmlpZDoxN0U3OEI3RjAzN0MxMUU3QTZDMDhBQjVCRDc2QkZCQjwvc3RSZWY6aW5zdGFuY2VJRD4KICAgICAgICAgICAgPHN0UmVmOmRvY3VtZW50SUQ+eG1wLmRpZDoxN0U3OEI4MDAzN0MxMUU3QTZDMDhBQjVCRDc2QkZCQjwvc3RSZWY6ZG9jdW1lbnRJRD4KICAgICAgICAgPC94bXBNTTpEZXJpdmVkRnJvbT4KICAgICAgICAgPHhtcE1NOkRvY3VtZW50SUQ+eG1wLmRpZDoxN0U3OEI4MjAzN0MxMUU3QTZDMDhBQjVCRDc2QkZCQjwveG1wTU06RG9jdW1lbnRJRD4KICAgICAgICAgPHhtcE1NOkluc3RhbmNlSUQ+eG1wLmlpZDoxN0U3OEI4MTAzN0MxMUU3QTZDMDhBQjVCRDc2QkZCQjwveG1wTU06SW5zdGFuY2VJRD4KICAgICAgICAgPHhtcDpDcmVhdG9yVG9vbD5BZG9iZSBQaG90b3Nob3AgQ1M1IFdpbmRvd3M8L3htcDpDcmVhdG9yVG9vbD4KICAgICAgPC9yZGY6RGVzY3JpcHRpb24+CiAgIDwvcmRmOlJERj4KPC94OnhtcG1ldGE+ChMBcXgAAAAJcEhZcwAACxMAAAsTAQCanBgAAAL9UExURUdwTDRRc1EVG6ioqFJSUmJiYn+AgURWa2uEkauorszGwmtrawonUKzY7DMRIlFTVWV9m4qKiwaN0G1raJSQiJjV7jWh2HmizPLs6CaV0QohSmdoaVdXWLWsomFdYmIgD4WCfQWa2WIoFUxylldpekeRuGtrajhztIuLizV3qc3DvThDVEyFs31+fiRViVRNViVWjwsvWxIzXxZEekeL1FZIVVRdeEZrk359fj52ppubm3l6e4qbqJOTlBlGfM3k3Nzc3K6lnk9RWaenp0FjikGDyJGRkWJiYk2L0Li4uJubnH5+flFbeNPT02tpac3NzVBGJkCCyMvLy9LS0oxETk2U3tLS0tXV1cPDw+Xl5amDftbX19na2uLj4+jo6dzd3OXl511dXd/g31paWlZXV9TU1HBwcOvr687OzdDQ0u/u7fTx79PSzcrJx6KiooWFhujn5NvW05WUk7S1t3R1d7y9vcLCv37J68vMzVJTVOLY1gMiSpmamnt7e7K6zHq+43LQ9Vyez+Pf3LGyscXGybzD1sXDw46v02vI8I+Pj7vEtNvIx7q4ubnZ54a3it3f5s+8vGS/6L6trK+6qICs1H+33cXc6KiuwAOr48fN20ee0Fao0lyz4W6s1qyrrKKlt3XdkoqnyyFoqzuTy6ixosuVeobA4YHNl8TOv3/Ck9bc4I3P7Uqq3tDIxz2FwzN/vF+VxdDe59mIfU+OxJmovxl+wX7S9WjbhovW9jihyKGalIq31uNyY36exJCatJONhTm36nKj0B2q4Mqxsae2zc/U3tvf1cqKa7zAyJS4npqyyTh2tUhMT1drj5ixtN98cEfC8U2Y5vf39355cSN0s4mDfKaomlrG8b2cmcFvaGx/m2CeZge68HG64YCNntSgoVHUdJzKnIHIh6c+BalVVaPM5qrG2CZZkyaHH3WRtYrdn5nH2rxoP22+gN1VQTyxW1aXl0iO2GaxtFuzaCCAQyXSWDOKlDZwkxIINVZPP52Io3uldtIoC1uGVxmzRP6PHn8AAADVdFJOUwAmEf6t/v4EAQVR/oT+Hl4U/v1bR/7+Kf7+a/76Q4Y2Wf1b4j71sXm0y2hF/bBwbtXN/fyGl8Sxiu382Preqfzia9iIkdP51/Povnineu+9n6H7ov5ksLfYy/7////////+/////////////////////v/////////////////////////////////////////////////////////////////////////////+/////////////////////////////////////////////////////r5xM8kAAA0qSURBVFjDpZh3WFNnG8YDMZOiLEFEsVhn1Vq1Vq1abWv3br+dc5IQsklCSEiIyAoJyAhb9h4ishVQcCAIOLC4UBFxr7bu0X6dX6/vec8JikIptecPVrh+576f5z3vez+HQmGyKBSK28eT4SsL/fiXLiaFwmD/E5NzPmU7wG8s5l/DOXy8+vhxLg8TcN5/yw0JZPwV2GoJH+fjPI7UHBWV/8HzwGIynlkgm+vv788RiURSs06bT6WuJAQynlEgO+JaUzoWhGAWE1X1mkqlmYUEMp5JIBs7ejYz3L4iyN+gy1epVMGvaYI1K5faIIF/nsfuPDr325LMo5XpvCCFThUMrHccY2L85j2TQHZna11kZFGd19lo+4oI/yiqJiYmxtGP7kdf/gwC2bLWuix1RWTX7uzMo+PTI4KkJo0fXPSQkBDxDOc/KZBtaK3P4uLqrPXri+rcz4YjgbpgegidHhIgDhC/6/mnBLLNVTWdclzdmbYTeAMClVS6OCAgQGxnZ0cbM4dBPDKjoh2oqo309ZV3ppWV7UTAur1nw+MrIhRaRzsPsdiDRqN5v+lpO0oc0OrrirLkiWGVZVYeIXBLRFBUsNiH5kHz9vHxeZMxOhxb51pTZ6zZ3ZUcvi2wrCwtbecGABqRQF6EIj9E6O3tI5wknE8Z1dPB1rrWGHPzjPWhN6MRL6wsbQPw1rdZBeo8fLyFa9eOGTWttqo3N9co8zd3hEWHBwaGpaURwCJj5tlt8bh2LdCEo6WZXGtLent7c2Q8zN8QmgYCw8LCEA+Abe5n4xV2QuGknz4b3bKbTHVtLD5RcjRXoOZhmL/0wM7k5PBAK29nkdc2RcBP3cfqlzBGtbNMVpU0nmgsLq6N5MrVAgzjKMxF56If8bKjDWIhbe79YzWfT6P88daHaI3u7o3FBRmRiSTvgLIDDBPADcZkpVjo85Nwyec1NctmEs/FSMDJwSWN7q2u7rVRSm1GaIVEgmORYDh0ZzISmJaTHAW0ScLPKA4zZx8qfvklhxEdI1pja2uru1kkVeoyOrK4kiwexvFXHOg61xseWJWsF/t4T4KewmWz5uWvv359DlHC4Wkumhr34uLGva6YWiSTGvQZGZFZyDAHCthxLroqV2elEQ6Z015ftGjRc3N+Txui1ZScKC7uSOTimEwmjdK2IMOIJ6oONeZaEM0HrTcm4dB23OsLFy6YOPyT5hJTW5JdlV1yqKCgo5Or5oHADEtBBhiGc4zj3zaIRvQU7SdjJy5cN/w+4OJYm53bW1VVYlboAMLnCkShUMCChshECazAthyT2PsxbWCRPLdu+G3Axa+2qj63t7dKhokUURkA4WYRhk0FYFg9lIZ4QPsdbfQTVXX19bm5iRIeR6RQagtCI0nD8GNGZ152PtB8nqBRSNpwbXUJOZGbl2esqyfXGkck1bWQhmUyMFyfQx2i7Q9oYWHn8owHDoR2wsMFAg+QhnGOTFbdlq0Sw+7rPWawsRFoASdyy5oCw/I4EbIDoVl8OVcQySEMVyDDiGZn52E3Sm22n/xQVVlZ2RRYgQt4HHMotLKTNIw6rN5QsgOdNgGj1EZx9qiNbqqsLOP6cnGBADOEhkZKCMNEh/OABidryIynaWOHpTEpNp4v1Ec3jbdPlPvK+SBQlkEahmdBqTXWa0LgqPZ7RGOOSEN/ZE19dVlueJP9FomvHARmEYblqMP+eTUxITGOjjFWGmRZSLYj0Mj9ZcriF4zR28an8319uZ2E4chOiZzPy6vZQ4ecEzyDwiITMtqRWCPQrA+L7dRX5yaDwER5ImmY6HBarR8dUphqHoWJxE3+cvU/2AzKiLQnBDbZp5OGiQ6fqz1Jp6pU+fNAkMOL/5Yf5/Oxf73FmjgyzSrQrfvNuclgmAuGcVyASfNqQ/xM+fmmefDZagnchCcyGJTvL//RBuXtYXclpnVQYFHcaieOXfxCTnhTPHQY4nVE2YkeP4vWpJtFobwogYQsEskMeouW/uPKNxyGDU9EcYlBgUlxOzSRqOD05G32W2DFSIDmqNdZ9IhWEQ4J2V9h1pnyHRcGq96Z5YJ4rKdZDDY5yZA0awVzosdDAa8Vix3NUWYRoqWfdcqEAAqBlhoM8VijiVn+4RCBbh+vlmCfok6xSNpAi0FgfFqxXYxIpAweB7R4r5bDdV6tkJD99RBoNbAOHenzpg0+FVlf8o774hgmJSaZAW0MtLVOWbzMtbHbY49+pedYuBPQMiKkWshjSGA1CrSQj+khy+c/PhXZEgxNH1/oddrXPnAhtQ20mAkCxXZnlpAFAdphHMdjDzYY94LACIUFBdoQ2BQ+mTHNapjdGT5+S5C/0oKGhR0rUBcGCoEEMqdMO/YKmr2Adt3rsJzPL084ePDwbtfM6PjEoCgVXSxGeZb27nxb1EV2fGbJ3sB4DEoRrNGsOOExeJJBAllAI2r6xnWvFft8j5dv3rQZ8YxEvlOY/DxoQKPRJi0eC9riS9otdXt7QaAyP8bxjF+M3+BBgUFxGES7139wX3nhjU2bNiccPNzQ5roXCdRrPIQAE6I4y77uXq32t7Rktwam8xQmDR1dA4MCEo9oLILW4XXvYX//L5sKSR4Ai0iB1VQ7CKCT1s4BmpNMwo/beLrAmJlsvwVmhQCU7e2IQYFppYFloHU53bt4+2GCIvZSYWHhAA8EBsYLlDQfiLPjEC1Jfjxu/8aNp/N3u6LFVK0KoXnYedAmjZmDNg6HY+8RSYukbb+YgGEy/aXC7YWbNm8G4OGuDTmZgbzgr7wJWof71f1xcbu2boQrH5qPBKb4eU+i+fgI56CK/f3t+zWzIWlNbnD64Zu7Fy9zUcZTpm7aXoiAILBrd2Y89StIx+Mok7uc+m7d6rtw5MhWBDxd0EYIVMYIyWSEOus2c1nx168vPQy0777pV6hhV8Y40tTL27eTvATXa6eAJiRpu27t51RfOLLryNb9+4FXVLU3OZ5HX2uloWXMgKQVsMLpv7/d/e5/qanlAgkfw5RK/SUrL/sRrcHp6p07W+EMkLZv3QWGAZjflUdqt56ixFPDWAq077//rV9q1pbG7uNKpFJMFHUJCbzcfG2Hldbi9LcrV/oiYB/kyJKARwqsqzz1mEb21AVo39z9/jZPJDXoSlMVCh6OjjVkuPnmjrVQGIJ29cqVqylJQWo+D0tKshr++UkaWsbPnwca1I3DFwBPbzoVK4D8yOFIYxMe01Y4Xf311z6DLqU9DufGwe5zAQTu+jkQtPs8Tbt3F+oGsnCcI5VpT5Wmcrh8yIzVzTsHaOfB6a99OCaNsqTExfHhbob2rXd+DoPPh9AeXLx49xeZvrS0XMAX6PUG7alUKc4XKJrXa4QEzeU84TQpCOfJzJbT7UFq4MmSWoah+bk/eLj94mWor9lUGssTKTiogKXleETz+j1CCHkEre/OlauWlHZ/XMBJsaSkxOFQwIa8ITRnuvuD/v6HCWqJgCMyWEpPlfMhlEEILU1tLtrjQyNoZ7z67tw5UiHTo8JVi+B7SlKEuiEPtHs/SQtwf3D7dv8vscRyE4lST8HC4/NgLEh1RzRvgub6n1u3jvD5PJE5JeVCEKR8szYlqSVvzzC0nYWbbidwlLHl+yR8QblSCYb38QUcZfPuPTBk04DW7Xq671ZfUlwEpCLDaVgpuEBkaD/fhu42KLUxKNPEjWU3bhReQod2bKxCwhFhyHCqgs8Dmp3YTkzQLuw6spFTjXj8JClhWIC1GPfQaB5PJHGKZ3dV080bl3zlkPNE+tjYfXIcg8qUppY3f3syAA4IZ4rDJyXXLxzZCg+yNCkpKA4nDFdHNNTtEZ85M8Y6b1iD27SPluVuG79KLZfzIUbFpiLDEBvNqUCDlzt0Z/iXV0uir0WpJ0AlRNXtcWpk2NLeUncyxHjsvVfcyAEGGUYhaex8yD2V8YIJvlw+vGSLjeVwYYZSAM0RTldndMspa6YnV6bjEyCzVBOGcUzRUn/S7/y3792//zaxVZJTLjHF/PgR5B77VWpfAQ+WqD5WgUsE2WdOxsAZ5Uz+i+3U2dmB8YkT5LCGpUlxQVx119yTGs2OGQ4z366pnW0FMqz52XY+ihWr9ql9IecRHc450xMMB6jz4+y2Zvo5+y1BpOGkoI65J4NV1HloKCWn3AEgyoEU5tSPwA4YRjkPOgw0VT4133lwuJw/O6cyXT0BBei4hrk91HzTLArxjtXmJZhyrcCBHAgVzAm0XzUB5TJeTncPVWsyOT8VLtdMD0OGueqOQz0mLaQ2pvWgBuCiRQsm2lAIGul66pLpydBhX7k6r7vHpNPpnh+SfkHgtS0TfCOLeyx62QcUFuVRBLJ5bgGMuQvW2ZCHBSHQEwTG4xPyusWWLwwG56fCKiFwyfSyLR3FPVKR9kMK69EnKC0CcN26OdYlTdydBQLP3azvFhtE1Hm2w8fzl2Yf6g6hLp3y1K2QwjkTGYP/hiZpz2U/BASs/HDsCPHc09l26Du8oa8uSIHOnihpsJj/B7mvTj/M63GzAAAAAElFTkSuQmCC);
  background-repeat: no-repeat;
  background-size: 100% 100%;
  width: 28px;
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

#headerTopContainer {
  position: sticky;
  display: inline-block;
  top: 0px;
  background-color: white;
  z-index: 1;
}
#headerTopAddNew {
  position: absolute;
  width: 100%;
  top: -33px;
}
#headerButtonBox {
  display: inline-block;
  position: sticky;
  right: 0px;
  float: right;
}
#headerButtonBox a, #headerButtonBox svg {
  display: table-cell;
  height: 24px;
  width: 24px;
  padding: 2px;
}
#addNew {
  background-color: #008061;
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
.col-sticky {
  position: sticky;
  left: 0;
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
.add-hm-related {
  float: right;
}
#tblAddCol {
  position: relative;
  z-index: 2;
  border: 2px solid blue;
}
tr th, tr td {
  padding: 0.2em 0.5em;
}

tr td.highlight {
  background-color: #B0B0FF;
}

table tr .col-sticky {
  background-color: #28B898;
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
table tbody tr:nth-of-type(even) .col-sticky {
  background-color: #fff;
}
table tbody tr:nth-of-type(odd) .col-sticky {
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
.right {
  text-align: right;
}
.paddingBottomZero {
  padding-bottom: 0px;
}
.paddingTopZero {
  padding-top: 0px;
}
.orphan {
  color: red;
  white-space: nowrap;
}
.thumbImg {
  max-width: 96px;
  max-height: 96px;
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
callbacks = {} %>"

              if ['index', 'show', 'new', 'update'].include?(args.first)
                poly_cols = []
                css << "<% bts = { #{
                  bt_items = bts.each_with_object([]) do |v, s|
                    foreign_models = if v.last[2] # Polymorphic?
                                       poly_cols << @_brick_model.brick_foreign_type(v[1].first)
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
// Add \"Are you sure?\" behaviour to any data-confirm buttons out there
document.querySelectorAll(\"input[type=submit][data-confirm]\").forEach(function (btn) {
  btn.addEventListener(\"click\", function (evt) {
    if (!confirm(this.getAttribute(\"data-confirm\"))) {
      evt.preventDefault();
      return false;
    }
  });
});

<%= @_brick_javascripts&.fetch(:grid_scripts, nil)&.html_safe
%>
#{JS_CHANGEOUT}#{
  "\nbrickTestSchema = \"#{::Brick.test_schema}\";" if ::Brick.test_schema
}
function doFetch(method, payload, success) {
  payload.authenticity_token = <%= session[:_csrf_token].inspect.html_safe %>;
  var action = payload._brick_action || location.href;
  delete payload._brick_action;
  if (!success) {
    success = function (p) {p.text().then(function (response) {
      var result = JSON.parse(response).result;
      if (result) location.href = location.href;
    });};
  }
  var options = {method: method, headers: {\"Content-Type\": \"application/json\"}};
  if (payload) options.body = JSON.stringify(payload);
  return fetch(action, options).then(success);
}

// Cause descriptive text to use the same font as the resource 
var brickFontFamily = document.getElementById(\"resourceName\").computedStyleMap().get(\"font-family\");
if (window.brickFontFamily) {
  [...document.getElementsByClassName(\"__brick\")].forEach(function (x){
    if (!x.style.fontFamily)
      x.style.fontFamily = brickFontFamily.toString();
  });
}
</script>
<% if (apartment_default_schema = ::Brick.apartment_multitenant && ::Brick.apartment_default_tenant)
     Apartment::Tenant.switch!(apartment_default_schema)
   end %>"

              erd_markup = if @_brick_model
                             "<div id=\"mermaidErd\">
  <div id=\"mermaidDiagram\" class=\"mermaid\">
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
   last_hm = nil
   @_brick_hm_counts&.each do |hm|
     # Skip showing self-referencing HM links since they would have already been drawn while evaluating the BT side
     next if (hm_class = hm.last&.klass) == #{@_brick_model.name}

     callbacks[hm_name = hm_class.name.split('::').last] = hm_class
     if (through = hm.last.options[:through]&.to_s) # has_many :through  (HMT)
       through_name = (through_assoc = hm.last.source_reflection).active_record.name.split('::').last
       callbacks[through_name] = through_assoc.active_record
       if last_hm == through # Same HM, so no need to build it again, and for clarity just put in a blank line
%><%=    \"\n\"
%><%   else
%>  <%= \"#\{model_short_name} ||--o{ #\{through_name}\".html_safe %> : \"\"
<%=      sidelinks(shown_classes, through_assoc.active_record).html_safe %>
<%       last_hm = through
       end
%>    <%= \"#\{through_name} }o--|| #\{hm_name}\".html_safe %> : \"\"
    <%= \"#\{model_short_name} }o..o{ #\{hm_name} : \\\"#\{hm.first}\\\"\".html_safe %><%
     else # has_many
%>  <%= \"#\{model_short_name} ||--o{ #\{hm_name} : \\\"#\{
            hm.first.to_s unless (last_hm = hm.first.to_s).downcase == hm_class.name.underscore.pluralize.tr('/', '_')
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
  </div>#{
 add_column = nil
 # Make into a server control with a javascript snippet
 # Have post back go to a common "brick_schema" endpoint, this one for add_column
"
  <table id=\"tblAddCol\"><tr>
    <td rowspan=\"2\">Add<br>Column</td>
    <td class=\"paddingBottomZero\">Type</td><td class=\"paddingBottomZero\">Name</td>
    <td rowspan=\"2\"><input type=\"button\" id=\"btnAddCol\" value=\"+\"></td>
  </tr><tr><td class=\"paddingTopZero\">
    <select id=\"ddlColType\">
   <option value=\"string\">String</option>
   <option value=\"text\">Text</option>
   <option value=\"integer\">Integer</option>
   <option value=\"bool\">Boolean</option>
 </select></td>
 <td class=\"paddingTopZero\"><input id=\"txtColName\"></td>
 </tr></table>
 <script>
 var btnAddCol = document.getElementById(\"btnAddCol\");
 btnAddCol.addEventListener(\"click\", function () {
   var txtColName = document.getElementById(\"txtColName\");
   var ddlColType = document.getElementById(\"ddlColType\");
   doFetch(\"POST\", {modelName: \"#{@_brick_model.name}\",
                      colName: txtColName.value, colType: ddlColType.value,
                      _brick_action: \"/#{prefix}brick_schema\"},
     function () { // If it returns successfully, do a page refresh
       location.href = location.href;
     }
   );
 });
 </script>
" unless add_column == false}

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
      var patchPath = <%= #{path_obj_name}_path(-1, format: :csv).inspect.html_safe %>;
      if (brickSchema) patchPath = changeout(patchPath, \"_brick_schema\", brickSchema);
      fetch(patchPath, {
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
      var client = google.accounts.oauth2.initTokenClient({
        client_id: \"487319557829-fgj4u660igrpptdji7ev0r5hb6kh05dh.apps.googleusercontent.com\",
        scope: \"https://www.googleapis.com/auth/spreadsheets https://www.googleapis.com/auth/drive.file\",
        callback: updateSignInStatus
      });
      client.requestAccessToken();
    });
  }

  async function updateSignInStatus(token) {
    await new Promise(function (resolve) {
      gapi.load(\"client\", function () {
        resolve(); // gapi client code now loaded
      });
    }).then(async function (x) {
      gapi.client.setToken(token);
      var discoveryDoc = await (await fetch(\"https://sheets.googleapis.com/$discovery/rest?version=v4\")).json();
      await gapi.client.load(discoveryDoc, function () {
        resolve(); // Spreadsheets code now loaded
      });
    });

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
      // sheetsLink.setAttribute(\"href\", sheetUrl);

      // Get JSON data
      var jsPath = <%= #{@_brick_model._brick_index}_path(format: :js).inspect.html_safe %>;
      if (brickSchema) jsPath = changeout(jsPath, \"_brick_schema\", brickSchema);
      fetch(jsPath).then(function (response) {
        response.json().then(function (resp) {
          // Expect the first row to have field names
          var colHeaders = Object.keys(resp.data[0]);;
          var ary = [colHeaders];
          // Add all the rows
          var row;
          resp.data.forEach(function (row) {
            ary.push(Object.keys(colHeaders).reduce(function(x, y) {
              x.push(row[colHeaders[y]]); return x
            }, []));
          });
          // Send to spreadsheet
          gapi.client.sheets.spreadsheets.values.append({
            spreadsheetId: spreadsheetId,
            range: 'Sheet1',
            valueInputOption: 'RAW',
            insertDataOption: 'INSERT_ROWS',
            values: ary
          }).then(function (response2) {
            // console.log('Spreadsheet created', response2);
          });
        });
      });
      window.open(sheetUrl, '_blank');
    });
  }
</script>
<script src=\"https://apis.google.com/js/api.js\"></script>
<script async defer src=\"https://accounts.google.com/gsi/client\" onload=\"gapiLoaded()\"></script>
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
<% if request.respond_to?(:flash)
     if (alert)
%><p class=\"flashAlert\"><%= alert.html_safe %></p><%
     end
     if (notice)
%><p class=\"flashNotice\"><%= notice.html_safe %></p><%
     end
end %>#{"
#{schema_options}" if schema_options}
<select id=\"tbl\">#{table_options}</select>
<table id=\"resourceName\"><tr>
  <td><h1><%= td_count = 1
              model.name %></h1></td>
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
%><%= if (page_num = @#{res_name = table_name.pluralize}&._brick_page_num)
           \"<tr><td colspan=\\\"#\{td_count}\\\">Page #\{page_num}</td></tr>\".html_safe
         end %></table>#{template_link}<%
   if description.present? %><span class=\"__brick\"><%=
     description %></span><br><%
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
         <h3 class=\"__brick\">for <% objs.each do |obj| %><%=
                      link_to \"#{"#\{obj.brick_descrip\} (#\{destination.name\})\""}, send(\"#\{destination._brick_index(:singular)\}_path\".to_sym, id)
               %><% end %></h3><%
       end
     end %>
  <span class=\"__brick\">(<%= link_to \"See all #\{model.base_class.name.split('::').last.pluralize}\", #{@_brick_model._brick_index}_path %>)</span>
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
    # If the resource is missing, has the user simply created an inappropriately pluralised name for a table?
    @#{res_name} ||= if (dym_list = instance_variables.reject do |entry|
                             entry.to_s.start_with?('@_') ||
                             ['@cache_hit', '@marked_for_same_origin_verification', '@view_renderer', '@view_flow', '@output_buffer', '@virtual_path'].include?(entry.to_s)
                           end).present?
                         msg = +\"Can't find resource \\\"#{res_name}\\\".\"
                         # Can't be sure otherwise of what is up, so check DidYouMean and offer a suggestion.
                         if (dym = DidYouMean::SpellChecker.new(dictionary: dym_list).correct('@#{res_name}')).present?
                           msg << \"\nIf you meant \\\"#\{found_dym = dym.first[1..-1]}\\\" then to avoid this message add this entry into inflections.rb:\n\"
                           msg << \"  inflect.irregular '#{obj_name}', '#\{found_dym}'\"
                           puts
                           puts \"WARNING:  #\{msg}\"
                           puts
                           @#{res_name} = instance_variable_get(dym.first.to_sym)
                         else
                           raise ActiveRecord::RecordNotFound.new(msg)
                         end
                       end

    # Starts as being just has_many columns, and will be augmented later with all the other columns
    cols = {#{hms_keys = []
              hms_headers.map do |hm|
                hms_keys << (assoc_name = (assoc = hm.first).name.to_s)
                "#{assoc_name.inspect} => [#{(assoc.options[:through] && !assoc.through_reflection).inspect}, #{assoc.klass.name}, #{hm[1].inspect}, #{hm[2].inspect}]"
              end.join(', ')}}

    # %%% Why in the Canvas LMS app does ActionView::Helpers get cleared / reloaded, or otherwise lose access to #brick_grid ???
    # Possible fix if somewhere we can implement the #include with:
    # (ActiveSupport.const_defined?('Reloader') ? ActiveSupport : ActionDispatch)::Reloader.to_prepare do ... end
    # or
    # Rails.application.reloader.to_prepare do ... end
    self.class.class_exec { include ::Brick::Rails::FormTags } unless respond_to?(:brick_grid)
    # Write out the mega-grid
    brick_grid(@#{res_name}, @_brick_sequence, @_brick_incl, @_brick_excl,
               cols, bt_descrip: @_brick_bt_descrip, poly_cols: poly_cols, bts: bts, hms_keys: #{hms_keys.inspect}, hms_cols: {#{hms_columns.join(', ')}}) %>

#{"<hr><%= link_to(\"New #{new_path_name = "new_#{path_obj_name}_path"
                           obj_name}\", #{new_path_name}, { class: '__brick' }) if respond_to?(:#{new_path_name}) %>" unless @_brick_model.is_view?}
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
<p class=\"flashNotice\"><%= notice if request.respond_to?(:flash) %></p>#{"
#{schema_options}" if schema_options}
<select id=\"tbl\">#{table_options}</select>
<h1>Status</h1>
<table id=\"resourceName\" class=\"shadow\"><thead><tr>
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
            kls = Object.const_get((rel = ::Brick.relations.fetch(r[0], nil))&.fetch(:class_name, nil))
          rescue
          end
          if kls.is_a?(Class) && (path_helper = respond_to?(bi_path = \"#\{kls._brick_index}_path\".to_sym) ? bi_path : nil)
            link_to(r[0], send(path_helper))
          else
            r[0]
          end %></td>
  <td<%= if r[1]
           ' class=\"orphan\"' unless ::Brick.relations.key?(r[1])
         else
           ' class=\"dimmed\"'
         end&.html_safe %>><%= # Table
         if (rowcount = rel&.fetch(:rowcount, nil))
           rowcount = (rowcount > 0 ? \" (#\{rowcount})\" : nil)
         end
         \"#\{r[1]}#\{rowcount}\" %></td>
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
<p class=\"flashNotice\"><%= notice if request.respond_to?(:flash) %></p>#{"
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
                           brick_path = Gem::Specification.find_by_name('brick').gem_dir
                           decipher.update(File.binread("#{brick_path}/lib/brick/frameworks/rails/crosstab.brk"))[16..-1]
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
"  if obj.respond_to?(:#{inh_col}) && (model_name = @#{obj_name}.#{inh_col}) &&
     !model_name.is_a?(Numeric) && model_name != base_model.name
    see_all_path << \"?#{inh_col}=#\{model_name}\"
  end
  model_name = base_model.name if model_name.is_a?(Numeric)"}
  page_title = (\"#\{model_name ||= model.name}: #\{obj&.brick_descrip || controller_name}\")
%></title>
</head>
<body>

<svg id=\"revertTemplate\" version=\"1.1\" xmlns=\"http://www.w3.org/2000/svg\" xmlns:xlink=\"http://www.w3.org/1999/xlink\"
  width=\"32px\" height=\"32px\" viewBox=\"0 0 512 512\" xml:space=\"preserve\">
<path id=\"revertPath\" fill=\"#2020A0\" d=\"M271.844,119.641c-78.531,0-148.031,37.875-191.813,96.188l-80.172-80.188v256h256l-87.094-87.094
  c23.141-70.188,89.141-120.906,167.063-120.906c97.25,0,176,78.813,176,176C511.828,227.078,404.391,119.641,271.844,119.641z\" />
</svg>

<% if request.respond_to?(:flash)
     if (alert)
%><p class=\"flashAlert\"><%= alert.html_safe %></p><%
     end
     if (notice)
%><p class=\"flashNotice\"><%= notice.html_safe %></p><%
     end
end %>#{"
#{schema_options}" if schema_options}
<select id=\"tbl\">#{table_options}</select>
<table id=\"resourceName\"><td><h1><%= page_title %></h1></td>
<% rel = Brick.relations[#{model_name}.table_name]
   if (in_app = rel.fetch(:existing, nil)&.fetch(:show, nil))
     begin
       in_app = send(\"#\{in_app}_path\", #{pk.is_a?(String) ? "obj.#{pk}" : '[' + pk.map { |pk_part| "obj.#{pk_part}" }.join(', ') + ']' }) if in_app.is_a?(Symbol) %>
     <td><%= link_to(::Brick::Rails::IN_APP.html_safe, in_app) %></td>
<%   rescue ActionController::UrlGenerationError
     end
   end

   if Object.const_defined?('Avo') && ::Avo.respond_to?(:railtie_namespace) %>
  <td><%= link_to_brick(
      ::Brick::Rails::AVO_SVG.html_safe,
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
   ::Brick::Rails::AA_PNG.html_safe,
   { show_proc: Proc.new do |aa_model, relation|
                  path_helper = \"#\{ns}_#\{relation.fetch(:auto_prefixed_schema, nil)}#\{aa_model.model_name.singular_route_key}_path\".to_sym
                  send(path_helper, obj) if respond_to?(path_helper)
                end,
     title: \"#\{page_title} in ActiveAdmin\" }
 ) %></td>
<%   end
   end %>
</table>
<%
if (description = rel&.fetch(:description, nil)) %>
  <span class=\"__brick\"><%= description %></span><br><%
end
%><%= link_to \"(See all #\{model_name.pluralize})\", see_all_path, { class: '__brick' } %>
#{erd_markup}
<% if obj
     # path_options = [obj.#{pk}]
     # path_options << { '_brick_schema':  } if
     options = {}
     path_helper = obj.new_record? ? #{model_name}._brick_index : #{model_name}._brick_index(:singular)
     options[:url] = send(\"#\{path_helper}_path\".to_sym, obj) if ::Brick.config.path_prefix || (path_helper != obj.class.table_name)
%>
  <br><br>

<%= # Write out the mega-form
    brick_form_for(obj, options, #{model_name}, bts, #{pk.inspect}) %>

#{unless args.first == 'new'
  # Was:  confirm_are_you_sure = ActionView.version < ::Gem::Version.new('7.0') ? "data: { confirm: \"Delete #\{model_name} -- Are you sure?\" }" : "form: { data: { turbo_confirm: \"Delete #\{model_name} -- Are you sure?\" } }"
  confirm_are_you_sure = "data: { confirm: \"Delete #\{model_name} -- Are you sure?\" }"
  ret = +"<%= button_to(\"Delete #\{@#{obj_name}.brick_descrip}\", send(\"#\{#{model_name}._brick_index(:singular)}_path\".to_sym, @#{obj_name}), { method: 'delete', class: 'danger', #{confirm_are_you_sure} }) %>"
  hms_headers.each_with_object(ret) do |hm, s|
    # %%% Would be able to remove this when multiple foreign keys to same destination becomes bulletproof
    next if hm.first.options[:through] && !hm.first.through_reflection

    if (pk = hm.first.klass.primary_key)
      hm_singular_name = (hm_name = hm.first.name.to_s).singularize.underscore
      obj_br_pk = (pk.is_a?(Array) ? pk : [pk]).each_with_object([]) { |pk_part, s| s << "br_#{hm_singular_name}.#{pk_part}" }.join(', ')
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
        <tr><th>#{hm[1]}#{' poly' if hm[0].options[:as]} #{hm[3]}
          <% if predicates && respond_to?(:new_#{partial_new_path_name = hm.first.klass._brick_index(:singular)}_path) %>
          <span class = \"add-hm-related\"><%=
            pk_val = (obj_pk = model.primary_key).is_a?(String) ? obj.send(obj_pk) : obj_pk.map { |pk_part| obj.send(pk_part) }
            pk_val_arr = [pk_val] unless pk_val.is_a?(Array)
            link_to('<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"24\" height=\"24\" viewBox=\"0 0 24 24\"><path fill=\"#fff\" d=\"M24 10h-10v-10h-4v10h-10v4h10v10h4v-10h10z\"/></svg>'.html_safe,
              new_#{partial_new_path_name}_path(predicates))
          %></span>
          <% end %>
        </th></tr>
        <% if (assoc = @#{obj_name}.class.reflect_on_association(:#{hm_name})).macro == :has_one &&
              assoc.options&.fetch(:through, nil).nil?
             # In order to apply DSL properly, evaluate this HO the other way around as if it were as a BT
             collection = assoc.klass.where(assoc.foreign_key => #{pk.is_a?(String) ? "@#{obj_name}.#{pk}" : pk.map { |pk_part| "@#{obj_name}.#{pk_part}" }.inspect})
             collection = collection.instance_exec(&assoc.scopes.first) if assoc.scopes.present?
             if assoc.klass.name == 'ActiveStorage::Attachment'
               br_descrip = begin
                              ::Brick::Rails.display_binary(obj.send(assoc.name)&.blob&.download, 500_000)&.html_safe
                            rescue
                            end
             end
           else
             collection = @#{obj_name}.#{hm_name}
           end
        err_msg = nil
        case collection
        when ActiveRecord::Relation # has_many (which comes in as a CollectionProxy) or a has_one#{
          poly_fix}
          collection2, descrip_cols = begin
                                        collection.brick_list
                                      rescue => e
                                        err_msg = '(error)'
                                        puts \"ERROR when referencing #\{collection.klass.name}:  #\{e.message}\"
                                      end
        when ActiveRecord::Base # Object from a has_one :through
          collection2 = [collection]
        else # We get an array back when AR < 4.2
          collection2 = collection.to_a.compact
        end
        if (collection2 = collection2&.brick_(:uniq)).blank? %>
          <tr><td<%= ' class=\"orphan\"'.html_safe if err_msg %>><%= err_msg || '(none)' %></td></tr>
     <% else
          collection2.each do |br_#{hm_singular_name}| %>
            <tr><td><%= br_descrip = if (dc = descrip_cols&.first&.first&.last) && br_#{hm_singular_name}.respond_to?(dc)
                                       br_#{hm_singular_name}.brick_descrip(
                                         descrip_cols&.first&.map { |col| br_#{hm_singular_name}.send(col.last) }
                                       )
                                     else # If the HM association has a scope, might not have picked up our SELECT detail
                                       pks = (klass = br_#{hm_singular_name}.class).primary_key
                                       pks = if pks.is_a?(Array)
                                               pks.map { |pk| br_#{hm_singular_name}.send(pk).to_s }
                                             else
                                               [br_#{hm_singular_name}.send(pks).to_s]
                                             end
                                       \"#\{klass.name} ##\{pks.join(', ')}\"
                                     end
                        link_to(br_descrip, #{hm.first.klass._brick_index(:singular)}_path(slashify(#{obj_br_pk}))) %></td></tr>
          <% end %>
        <% end %>
      </table>"
    else
      s
    end
  end
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

<% # Good up until v0.19.0, and then with v0.20.0 of vanilla-jsoneditor started to get:
   # Uncaught TypeError: Failed to resolve module specifier \"immutable-json-patch\". Relative references must start with either \"/\", \"./\", or \"../\".
   if @_json_fields_present %>
<link rel=\"stylesheet\" type=\"text/css\" href=\"https://cdn.jsdelivr.net/npm/vanilla-jsoneditor@0.19.0/themes/jse-theme-default.min.css\">
<script type=\"module\">
  import { JSONEditor } from \"https://cdn.jsdelivr.net/npm/vanilla-jsoneditor@0.19.0/index.min.js\";
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
  var cbs = {<%= callbacks.map do |k, v|
                   path = send(\"#\{v._brick_index}_path\".to_sym)
                   path << \"?#\{v.base_class.inheritance_column}=#\{v.name}\" unless v == v.base_class
                   \"#\{k}: \\\"#\{path}\\\"\"
                 end.join(', ').html_safe %>};
  if (imgErd) imgErd.addEventListener(\"click\", showErd);
  function showErd() {
    imgErd.style.display = \"none\";
    mermaidErd.style.display = \"block\";
    if (mermaidCode) return; // Cut it short if we've already rendered the diagram

    mermaidCode = document.createElement(\"SCRIPT\");
    mermaidCode.setAttribute(\"src\", \"https://cdn.jsdelivr.net/npm/mermaid@9.1.7/dist/mermaid.min.js\");
    mermaidCode.addEventListener(\"load\", mermaidLoaded);
    function mermaidLoaded() {
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
                  changeout(location.href, \"_brick_order\", null), // Remove any ordering
                -1, cbs[this.id].replace(/^[\/]+/, \"\")), \"_brick_erd\", \"1\");
              }
            );
          }
        }}
      });
      mermaid.contentLoaded();
      window.history.replaceState({}, \"\", changeout(location.href, \"_brick_erd\", \"1\"));
      // Add <span> at the end
      var span = document.createElement(\"SPAN\");
      span.className = \"exclude\";
      span.innerHTML = \"X\";
      span.addEventListener(\"click\", function (e) {
        e.stopPropagation();
        imgErd.style.display = \"table-cell\";
        mermaidErd.style.display = \"none\";
        window.history.replaceState({}, \"\", changeout(location.href, \"_brick_erd\", null));
      });
      mermaidErd.appendChild(span);
    }
    // If there's an error with the CDN during load, revert to our local copy
    mermaidCode.addEventListener(\"error\", function (e) {
      console.warn(\"As we're unable to load Mermaid from\\n  \" + e.srcElement.src + \" ,\\nnow reverting to copy from /assets.\");
      var mermaidCode2 = document.createElement(\"SCRIPT\");
      mermaidCode2.setAttribute(\"src\", \"/assets/mermaid.min.js\");
      mermaidCode2.addEventListener(\"load\", mermaidLoaded);
      e.srcElement.replaceWith(mermaidCode2);
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
                _brick_render_template(view, template, layout_name, *args)
              end
          end # TemplateRenderer
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

                brick_models = ::Brick.relations.each_with_object([]) { |rel, s| s << rel.last[:class_name] unless rel.first.is_a?(Symbol) }

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
            ::Brick.relations.select { |_k, v| v.is_a?(Hash) && v.key?(:isView) }.each do |_k, relation|
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
