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
        # Load three initializers early (inflections.rb, brick.rb, apartment.rb)
        # Very first thing, load inflections since we'll be using .pluralize and .singularize on table and model names
        if File.exist?(inflections = ::Rails.root&.join('config/initializers/inflections.rb') || '')
          load inflections
        end
        require 'brick/join_array'

        # Load it once at the start for Rails >= 7.2 ...
        Module.class_exec &::Brick::ADD_CONST_MISSING if ActiveRecord.version >= Gem::Version.new('7.2.0')
        # ... and also for Rails >= 5.0, whenever the app gets reloaded
        if ::Rails.application.respond_to?(:reloader)
          ::Rails.application.reloader.to_prepare { Module.class_exec &::Brick::ADD_CONST_MISSING }
        else
          Module.class_exec &::Brick::ADD_CONST_MISSING # Older Rails -- just load at the start
        end

        # Now the Brick initializer since there may be important schema things configured
        if !::Brick.initializer_loaded && File.exist?(brick_initializer = ::Rails.root&.join('config/initializers/brick.rb') || '')
          ::Brick.initializer_loaded = load brick_initializer

          # After loading the initializer, add compatibility for ActiveStorage and ActionText if those haven't already been
          # defined.  (Further JSON configuration for ActiveStorage metadata happens later in the after_initialize hook.)
          # begin
            ['ActiveStorage', 'ActionText'].each do |ar_extension|
              if Object.const_defined?(ar_extension) &&
                 (extension = Object.const_get(ar_extension)).respond_to?(:table_name_prefix) &&
                 !::Brick.config.table_name_prefixes.key?(as_tnp = extension.table_name_prefix)
                ::Brick.config.table_name_prefixes[as_tnp] = ar_extension
              end
            end
          # rescue # NoMethodError
          # end

          # Support the followability gem:  https://github.com/nejdetkadir/followability
          if Object.const_defined?('Followability') && !::Brick.config.table_name_prefixes.key?('followability_')
            ::Brick.config.table_name_prefixes['followability_'] = 'Followability'
          end
        end
        # Load the initializer for the Apartment gem a little early so that if .excluded_models and
        # .default_schema are specified then we can work with non-tenanted models more appropriately
        if (apartment = Object.const_defined?('Apartment')) &&
           File.exist?(apartment_initializer = ::Rails.root.join('config/initializers/apartment.rb'))
          require 'apartment/adapters/abstract_adapter'
          Apartment::Adapters::AbstractAdapter.class_exec do
            if instance_methods.include?(:process_excluded_models)
              def process_excluded_models
                # All other models will share a connection (at Apartment.connection_class) and we can modify at will
                Apartment.excluded_models.each do |excluded_model|
                  begin
                    process_excluded_model(excluded_model)
                  rescue NameError => e
                    (@bad_models ||= []) << excluded_model
                  end
                end
              end
            end
          end
          unless @_apartment_loaded
            load apartment_initializer
            @_apartment_loaded = true
          end
        end

        if ::Brick.enable_routes? && Object.const_defined?('ActionDispatch')
          require 'brick/route_mapper'
          ActionDispatch::Routing::RouteSet.class_exec do
            # In order to defer auto-creation of any routes that already exist, calculate Brick routes only after having loaded all others
            prepend ::Brick::RouteSet
          end
          ActionDispatch::Routing::Mapper.class_exec do
            include ::Brick::RouteMapper
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
            ::Brick.established_drf = "/#{::Brick.config.path_prefix}#{action[action.index('#')..-1]}"
          end
        end
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
           ::ActiveStorage.const_defined?('Blob')
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
                    if ::Avo::BaseResource.constants.exclude?(class_name.to_sym) &&
                       ::Avo::Resources.constants.exclude?(class_name.to_sym) &&
                       (klass = Object.const_get(class_name)).is_a?(Class)
                      ::Brick.avo_3x_resource(klass, class_name)
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
          if (aav = ::ActiveAdmin::Views).const_defined?('TitleBar') # ActiveAdmin < 4.0
            aav::TitleBar.class_exec do
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
          else # ActiveAdmin 4.0 or later
            is_aa_4x = true
            ::ActiveAdmin::ResourceController.class_exec do
              include ActionView::Helpers::UrlHelper
              include ::Brick::Rails::FormTags
              alias _brick_default_page_title default_page_title
              def default_page_title
                dpt = _brick_default_page_title
                if klass = begin
                             ::Brick.relations.fetch(@current_menu_item&.id, nil)&.fetch(:class_name, nil)&.constantize
                           rescue
                           end
                  (dpt + link_to_brick(nil,
                    BRICK_SVG.html_safe,
                    { title: "#{dpt} in Brick" }
                  )).html_safe
                else
                  dpt
                end
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
                  end
                end unless is_aa_4x
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
                if self.class < AbstractController::Base
                  if respond_to?(:request) # ActionMailer does not have +request+
                    @_lookup_context.instance_variable_set(:@_brick_req_params, params) if request && params.present?
                  end
                end
                ret
              end
            end
          end

          ActionView::LookupContext.class_exec do
            # Used by Rails 5.0 and above
            alias :_brick_template_exists? :template_exists?
            def template_exists?(*args, **options)
              (::Brick.config.add_search && args.first == 'search') ||
              (::Brick.config.add_status && args.first == 'status') ||
              (::Brick.config.add_orphans && args.first == 'orphans') ||
              (args.first == 'crosstab') ||
              _brick_template_exists?(*args, **options) ||
              # By default do not auto-create a template when it's searching for an application.html.erb, which comes in like:  ["edit", ["games", "application"]]
              # (Although specifying a class name for controllers_inherit_from will override this.)
              ((args[1].length == 1 || ::Brick.config.controllers_inherit_from.present? || args[1][-1] != 'application') &&
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
                      @_brick_model = model.find_real_model(params)
                    end
                  rescue
                  end
                end
              end
              @_brick_model
            end

            def path_keys(hm_assoc, fk_name, pk)
              pk.map!(&:to_sym)
              keys = if hm_assoc.macro == :has_and_belongs_to_many
                       # %%% Can a HABTM use composite keys?
                       # (If so then this should be rewritten to do a .zip() )
                       name_from_other_direction = hm_assoc.klass.reflect_on_all_associations.find { |a| a.join_table == hm_assoc.join_table }&.name
                       [["#{name_from_other_direction}.#{pk.first}", pk.first]]
                     else
                       if fk_name.is_a?(Array) && pk.is_a?(Array) # Composite keys?
                         fk_name.zip(pk)
                       else
                         [[fk_name, pk.length == 1 ? pk.first : pk.inspect]]
                       end
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
              # ActiveStorage has_one_attached and has_many_attached needs additional filtering on the name
              if (as_name = hm_assoc.klass&._active_storage_name(hm_assoc.name)) # ActiveStorage HMT
                prefix = 'attachments.' if hm_assoc.through_reflection&.klass&.<= ::ActiveStorage::Attachment
                keys << ["#{prefix}name", as_name]
              end
              keys.to_h
            end

            alias :_brick_find_template :find_template
            def find_template(*args, **options)
              find_template_err = nil
              unless (model_name = @_brick_model&.name) ||
                     (
                      args[1].first == 'brick_gem' &&
                      ((is_search = ::Brick.config.add_search && args[0] == 'search' &&
                                    ::Brick.elasticsearch_existings&.length&.positive?
                       ) ||
                       (is_status = ::Brick.config.add_status && args[0] == 'status') ||
                       (is_orphans = ::Brick.config.add_orphans && args[0] == 'orphans') ||
                       (is_crosstab = args[0] == 'crosstab')
                      )
                     )
                begin
                  if (possible_template = _brick_find_template(*args, **options))
                    return possible_template
                  end
                rescue StandardError => e
                  # Search through the routes to confirm that something might match (Devise stuff for instance, which has its own view templates),
                  # and bubble the same exception (probably an ActionView::MissingTemplate) if a legitimate option is found.
                  raise if ActionView.version >= ::Gem::Version.new('5.0') && args[1] &&
                           ::Rails.application.routes.set.find { |x| args[1].include?(x.defaults[:controller]) && args[0] == x.defaults[:action] }

                  find_template_err = e
                end
                model_name = set_brick_model(args, @_brick_req_params)&.name
              end

              if @_brick_model
                pk = @_brick_model._brick_primary_key(::Brick.relations.fetch((table_name = @_brick_model.table_name.split('.').last), nil))
                rn_start = (mn_split = model_name.split('::')).length > 1 ? -2 : -1
                obj_name = mn_split[rn_start..-1].join.underscore.singularize
                res_name = obj_name.pluralize

                path_obj_name = @_brick_model._brick_index(:singular)
                table_name ||= obj_name.pluralize
                template_link = nil
                bts, hms = ::Brick.get_bts_and_hms(@_brick_model) # This gets BT and HM and also has_many :through (HMT)
                hms_columns = [] # Used for 'index'
                skip_klass_hms = ::Brick.config.skip_index_hms[model_name] || {}
                hms_headers = hms.each_with_object([]) do |hm, s|
                  hm_stuff = [(hm_assoc = hm.last),
                              "H#{case hm_assoc.macro
                                  when :has_one
                                    'O'
                                  when :has_and_belongs_to_many
                                    'ABTM'
                                  else
                                    'M'
                                  end}#{'T' if hm_assoc.options[:through]}",
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
                                    b_r_name = "b_r_#{assoc_name}_ct"
                                    # Postgres column names are limited to 63 characters
                                    b_r_name = b_r_name[0..62] if @_brick_is_postgres
                                    "'#{b_r_name}'"
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
                                next if rel.first.is_a?(Symbol) || rel.first.blank? || rel.last[:cols].empty? ||
                                        ::Brick.config.exclude_tables.include?(rel.first)

                                # %%% When table_name_prefixes are use then during rendering empty non-TNP
                                # entries get added at some point when an attempt is made to find the table.
                                # Will have to hunt that down at some point.
                                if (rowcount = rel.last.fetch(:rowcount, nil))
                                  rowcount = rowcount > 0 ? " (#{rowcount})" : nil
                                end
                                s << "<option value=\"#{::Brick._brick_index(rel.first, nil, '/', nil, true)}\">#{rel.first}#{rowcount}</option>"
                              end.html_safe
              # Options for special Brick pages
              prefix = "#{::Brick.config.path_prefix}/" if ::Brick.config.path_prefix
              [['Search', is_search],
               ['Status', ::Brick.config.add_status],
               ['Orphans', is_orphans],
               ['Crosstab', is_crosstab]].each do |table_option, show_it|
                table_options << "<option value=\"#{prefix}brick_#{table_option.downcase}\">(#{table_option})</option>".html_safe if show_it
              end
              css = +'<style>'
              css << ::Brick::Rails::BRICK_CSS
              css << "</style>
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
  payload.authenticity_token = <%= (session[:_csrf_token] || form_authenticity_token).inspect.html_safe %>;
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
%><%= if (page_num = @#{res_name}&._brick_page_num)
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
<% end
   # SEARCH BOX
   if @_brick_es&.index('r') # Must have at least Elasticsearch Read access %>
  <input type=\"text\" id=\"esSearch\" class=\"dimmed\">
  <script>
    var esSearch = document.getElementById(\"esSearch\");
    var usedTerms = {};
    var isEsFiltered = false;
    esSearch.addEventListener(\"input\", function () {
      var gridTrs;
      if (this.value.length > 2 && usedTerms[this.value] !== null) { // At least 3 letters in the search term
        var es = doFetch(\"POST\", {_brick_es: this.value},
          function (p) {p.text().then(function (response) {
            var result = JSON.parse(response).result;
            if (result.length > 0) {
              // Show only rows that have matches
              gridTrs = [... grid.querySelectorAll(\"tr\")];
              for (var i = 1; i < gridTrs.length; ++i) {
                var row = gridTrs[i];
                // Check all results to see if this one is in the list
                var rid = row.getAttribute(\"x-id\");
                var isHit = false;
                for (var j = 0; j < result.length; ++j) {
                  if (rid == result[j]._id) {
                    isHit = true;
                    break;
                  }
                }
                if (!isHit) row.style.display = \"none\";
              }
              isEsFiltered = true;
              esSearch.className = \"\";
            } else {
              if (isEsFiltered) { // Show all rows and gray the search box
                usedTerms[this.value] = null; // No results for this term
                gridTrs = [... grid.querySelectorAll(\"tr\")];
                for (var i = 1; i < gridTrs.length; ++i) {
                  gridTrs[i].style.display = \"table-row\";
                }
              }
              esSearch.className = \"dimmed\";
            }
          });}
        );
      } else {
        if (isEsFiltered) { // Show all rows and gray the search box
          gridTrs = [... grid.querySelectorAll(\"tr\")];
          for (var i = 1; i < gridTrs.length; ++i) {
            gridTrs[i].style.display = \"table-row\";
          }
          esSearch.className = \"dimmed\";
        }
      }
    });
    esSearch.addEventListener(\"keypress\", function (e) {
      if (e.keyCode == 13) {
//        debugger
        // Go to search results page
//        var es = doFetch(\"POST\", {_brick_es: this.value});
//        console.log(es);
      }
    });
  </script>
<% end %>
</div></div>
#{::Brick::Rails.erd_markup(@_brick_model, prefix) if @_brick_model}

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

    #{# Determine if we should render an N:M representation or the standard "mega_grid"
      taa = ::Brick.config.treat_as_associative&.fetch(table_name, nil)
      options = {}
      options[:prefix] = prefix unless prefix.blank?
      if taa.is_a?(String) || # Write out a constellation
         (taa.is_a?(Array) && (options[:axes] = taa[0..-2]) && (options[:dsl] = taa.last))
        representation = :constellation
        "
    brick_constellation(@#{res_name}, #{options.inspect}, bt_descrip: @_brick_bt_descrip, bts: bts)"
      elsif taa.is_a?(Symbol) # Write out a bezier representation
        "
    brick_bezier(@#{res_name}, #{options.inspect}, bt_descrip: @_brick_bt_descrip, bts: bts)"
      else # Write out the mega-grid
        representation = :grid
        "
    brick_grid(@#{res_name}, @_brick_sequence, @_brick_incl, @_brick_excl,
               cols, bt_descrip: @_brick_bt_descrip,
               poly_cols: poly_cols, bts: bts, hms_keys: #{hms_keys.inspect}, hms_cols: {#{hms_columns.join(', ')}})"
      end}
 %>

#{"<hr><%= link_to_brick(model, new: true, class: '__brick') %>" unless @_brick_model.is_view?}
#{script}
</body>
</html>
"


                       when 'search'
                         if is_search
# Search page - query across all indexes that appear to be related to models
+"#{css}
<p class=\"flashNotice\"><%= notice if request.respond_to?(:flash) %></p>#{"
#{schema_options}" if schema_options}
<select id=\"tbl\">#{table_options}</select><br><br>
<form method=\"get\">
  <input type=\"text\" name=\"qry\"<%= \" value=\\\"#\{@qry}\\\"\".html_safe unless @qry.blank? %>><input type=\"submit\", value=\"Search\">
</form>
<% if @results.present? %>
<div id=\"rowCount\"><b><%= @count %> results from: </b><%= @indexes.sort.join(', ') %></div>
<% end %>
<table id=\"resourceName\" class=\"shadow\"><thead><tr>
  <th>Resource</th>
  <th>Description</th>
  <th>Score</th>
</tr></thead>
<tbody>
<% @results&.each do |r| %>
  <tr>
  <td><%= link_to (r[3]) do %><%= r[0] %><br>
      <%= r[1] %><% end %>
  </td>
  <td><%= r[2] %></td>
  <td><%= '%.3f' % r[4] %></td>
  </tr>
<% end %>
</tbody></table>
#{script}"
                         end

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
  </tr>
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
                           decipher.update(File.binread("#{brick_path}/lib/brick/rails/crosstab.brk"))[16..-1]
                         else
                           'Crosstab Charting not yet activated -- enter a valid license key in brick.rb'
                         end

                       when 'show', 'new', 'update'
+"<html>
<head>
#{css}
<title><%=
  if (model = (obj = @#{obj_name})&.class || @lookup_context&.instance_variable_get(:@_brick_model))
    see_all_path = send(\"#\{(base_model = model.base_class)._brick_index}_path\")
#{(inh_col = @_brick_model.inheritance_column).present? &&
"  if obj.respond_to?(:#{inh_col}) && (model_name = @#{obj_name}.#{inh_col}) &&
     !model_name.is_a?(Numeric) && model_name != base_model.name
    see_all_path << \"?#{inh_col}=#\{model_name}\"
  end
  model_name = base_model.name if model_name.is_a?(Numeric)"}
  model_name = nil if model_name == ''
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
<table id=\"resourceName\"><tr><td><h1><%= page_title %></h1></td>
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
</tr></table>
<%
if (description = rel&.fetch(:description, nil)) %>
  <span class=\"__brick\"><%= description %></span><br><%
end
%><%= link_to \"(See all #\{model_name.pluralize})\", see_all_path, { class: '__brick' } %>
#{::Brick::Rails.erd_markup(@_brick_model, prefix) if @_brick_model}
<% if obj
     # path_options = [obj.#{pk}]
     # path_options << { '_brick_schema':  } if
     options = {}
     options[:url] = if obj.new_record?
                       link_to_brick(obj.class, path_only: true) # Properly supports STI, but only works for :new
                     else
                       path_helper = obj.new_record? ? #{model_name}._brick_index : #{model_name}._brick_index(:singular)
                       options[:url] = send(\"#\{path_helper}_path\".to_sym, obj) if ::Brick.config.path_prefix || (path_helper != obj.class.table_name)
                     end
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
      obj_br_pk = hm.first.klass._pk_as_array.map { |pk_part| "br_#{hm_singular_name}.#{pk_part}" }.join(', ')
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
<% end %>
"
              end
              if representation == :grid
                inline << "<script>
<% # Make column headers sort when clicked
   # %%% Create a smart javascript routine which can do this client-side %>
[... document.getElementsByTagName(\"TH\")].forEach(function (th) {
  th.addEventListener(\"click\", function (e) {
    var xOrder,
        currentOrder;
    if (xOrder = this.getAttribute(\"x-order\")) {
      if ((currentOrder = changeout(location.href, \"_brick_order\")) === xOrder)
        xOrder = \"-\" + xOrder;
      location.href = changeout(location.href, \"_brick_order\", xOrder);
    }
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
