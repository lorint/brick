# frozen_string_literal: true

module Brick
  class << self
    attr_accessor :routes_done
  end

  module RouteMapper
    def add_brick_routes
      routeset_to_use = ::Rails.application.routes
      path_prefix = ::Brick.config.path_prefix
      existing_controllers = routeset_to_use.routes.each_with_object({}) do |r, s|
        if (r.verb == 'GET' || (r.verb.is_a?(Regexp) && r.verb.source == '^GET$')) &&
           (controller_name = r.defaults[:controller])
          path = r.path.ast.to_s
          path = path[0..((path.index('(') || 0) - 1)]
          # Skip adding this if it's the default_route_fallback set from the initializers/brick.rb file
          next if "#{path}##{r.defaults[:action]}" == ::Brick.established_drf ||
                  # or not a GET request
                  [:index, :show, :new, :edit].exclude?(action = r.defaults[:action].to_sym)

          # Attempt to backtrack to original
          c_parts = controller_name.split('/')
          while c_parts.length > 0
            c_dotted = c_parts.join('.')
            if (relation = ::Brick.relations.fetch(c_dotted, nil)) # Does it match up with an existing Brick table / resource name?
              # puts path
              # puts "  #{c_dotted}##{r.defaults[:action]}"
              if (route_name = r.name&.to_sym) != :root
                relation[:existing][action] = route_name
              else
                relation[:existing][action] ||= path
              end
              s[c_dotted.tr('.', '/')] = nil
              break
            end
            c_parts.shift
          end
          s[controller_name] = nil if c_parts.length.zero?
        end
      end

      tables = []
      views = []
      table_class_length = 38 # Length of "Classes that can be built from tables:"
      view_class_length = 37 # Length of "Classes that can be built from views:"

      brick_namespace_create = lambda do |path_names, res_name, options, ind = 0|
        if path_names&.present?
          if (path_name = path_names.pop).is_a?(Array)
            module_name = path_name[1]
            path_name = path_name.first
          end
          scope_options = { module: module_name || path_name, path: path_name, as: path_name }
          # if module_name.nil? || module_name == path_name
          #   puts "#{'  ' * ind}namespace :#{path_name}"
          # else
          #   puts "#{'  ' * ind}scope #{scope_options.inspect}"
          # end
          send(:scope, scope_options) do
            brick_namespace_create.call(path_names, res_name, options, ind + 1)
          end
        else
          # puts "#{'  ' * ind}resources :#{res_name} #{options.inspect unless options.blank?}"
          send(:resources, res_name.to_sym, **options)
        end
      end

      # %%% TODO: If no auto-controllers then enumerate the controllers folder in order to build matching routes
      # If auto-controllers and auto-models are both enabled then this makes sense:
      controller_prefix = (path_prefix ? "#{path_prefix}/" : '')
      sti_subclasses = ::Brick.config.sti_namespace_prefixes.each_with_object(Hash.new { |h, k| h[k] = [] }) do |v, s|
                         # Turn something like {"::Spouse"=>"Person", "::Friend"=>"Person"} into {"Person"=>["Spouse", "Friend"]}
                         s[v.last] << v.first[2..-1] unless v.first.end_with?('::')
                       end
      versioned_views = {} # Track which views have already been done for each api_root
      ::Brick.relations.each do |k, v|
        next if k.is_a?(Symbol)

        if (schema_name = v.fetch(:schema, nil))
          schema_prefix = "#{schema_name}."
        end

        resource_name = v.fetch(:resource, nil) || k
        next if !resource_name ||
                existing_controllers.key?(
                  "#{controller_prefix}#{schema_prefix&.tr('.', '/')}#{resource_name}".pluralize
                )

        object_name = k.split('.').last # Take off any first schema part

        # # What about:
        # full_schema_prefix = if (aps2 = v.fetch(:auto_prefixed_schema, nil))
        #                        # Used to be:  aps = aps[0..-2] if aps[-1] == '_'
        #                        aps2 = aps2[0..-2] if aps2[-1] == '_'
        #                        aps = v[:auto_prefixed_class].underscore

        full_schema_prefix = if (aps = v.fetch(:auto_prefixed_schema, nil))
                               aps = aps[0..-2] if aps[-1] == '_'
                               # %%% If this really is nil then should be an override
                               aps2 = v[:auto_prefixed_class]&.underscore
                               (schema_prefix&.dup || +'') << "#{aps}."
                             else
                               schema_prefix
                             end

        # Track routes being built
        if (class_name = v.fetch(:class_name, nil))
          if v.key?(:isView)
            view_class_length = class_name.length if class_name.length > view_class_length
            views
          else
            table_class_length = class_name.length if class_name.length > table_class_length
            tables
          end << [class_name, aps, "#{"#{schema_name}/" if schema_name}#{resource_name}"]
        end

        options = {}
        options[:only] = [:index, :show] if v.key?(:isView)

        # First do the normal routes
        prefixes = []
        # Second term used to be:   v[:class_name]&.split('::')[-2]&.underscore
        prefixes << [aps, aps2] if aps
        prefixes << schema_name if schema_name
        prefixes << path_prefix if path_prefix
        brick_namespace_create.call(prefixes, resource_name, options)
        sti_subclasses.fetch(class_name, nil)&.each do |sc| # Add any STI subclass routes for this relation
          brick_namespace_create.call(prefixes, sc.underscore.tr('/', '_').pluralize, options)
        end

        # Now the API routes if necessary
        full_resource = nil
        ::Brick.api_roots&.each do |api_root|
          api_done_views = (versioned_views[api_root] ||= {})
          found = nil
          test_ver_num = nil
          view_relation = nil
          # If it's a view then see if there's a versioned one available by searching for resource names
          # versioned with the closest number (equal to or less than) compared with our API version number.
          if v.key?(:isView)
            if (ver = object_name.match(/^v([\d_]*)/)&.captures&.first) && ver[-1] == '_'
              core_object_name = object_name[ver.length + 1..-1]
              next if api_done_views.key?(unversioned = "#{schema_prefix}v_#{core_object_name}")

              # Expect that the last item in the path generally holds versioning information
              api_ver = api_root.split('/')[-1]&.gsub('_', '.')
              vn_idx = api_ver.rindex(/[^\d._]/) # Position of the first numeric digit at the end of the version number
              # Was:  .to_d
              test_ver_num = api_ver_num = api_ver[vn_idx + 1..-1].gsub('_', '.').to_i # Attempt to turn something like "v3" into the decimal value 3
              # puts [api_ver, vn_idx, api_ver_num, unversioned].inspect

              next if ver.to_i > api_ver_num # Don't surface any newer views in an older API

              test_ver_num -= 1 until test_ver_num.zero? ||
                                      (view_relation = ::Brick.relations.fetch(
                                        found = "#{schema_prefix}v#{test_ver_num}_#{core_object_name}", nil
                                      ))
              api_done_views[unversioned] = nil # Mark that for this API version this view is done

              # puts "Found #{found}" if view_relation
              # If we haven't found "v3_view_name" or "v2_view_name" or so forth, at the last
              # fall back to simply looking for "v_view_name", and then finally  "view_name".
              no_v_prefix_name = "#{schema_prefix}#{core_object_name}"
              standard_prefix = 'v_'
            else
              core_object_name = object_name
            end
            if (rvp = ::Brick.config.api_remove_view_prefix) && core_object_name.start_with?(rvp)
              core_object_name.slice!(0, rvp.length)
            end
            no_prefix_name = "#{schema_prefix}#{core_object_name}"
            unversioned = "#{schema_prefix}#{standard_prefix}#{::Brick.config.api_add_view_prefix}#{core_object_name}"
          else
            unversioned = k
          end

          view_relation ||= ::Brick.relations.fetch(found = unversioned, nil) ||
                            (no_v_prefix_name && ::Brick.relations.fetch(found = no_v_prefix_name, nil)) ||
                            (no_prefix_name && ::Brick.relations.fetch(found = no_prefix_name, nil))
          if view_relation
            actions = view_relation.key?(:isView) ? [:index, :show] : ::Brick::ALL_API_ACTIONS # By default all actions are allowed
            # Call proc that limits which endpoints get surfaced based on version, table or view name, method (get list / get one / post / patch / delete)
            # Returning nil makes it do nothing, false makes it skip creating this endpoint, and an array of up to
            # these 3 things controls and changes the nature of the endpoint that gets built:
            # (updated api_name, name of different relation to route to, allowed actions such as :index, :show, :create, etc)
            proc_result = if (filter = ::Brick.config.api_filter).is_a?(Proc)
                            begin
                              num_args = filter.arity.negative? ? 6 : filter.arity
                              filter.call(*[unversioned, k, view_relation, actions, api_ver_num, found, test_ver_num][0...num_args])
                            rescue StandardError => e
                              puts "::Brick.api_filter Proc error: #{e.message}"
                            end
                          end
            # proc_result expects to receive back: [updated_api_name, to_other_relation, allowed_actions]

            case proc_result
            when NilClass
              # Do nothing differently than what normal behaviour would be
            when FalseClass # Skip implementing this endpoint
              view_relation[:api][api_ver_num] = nil
              next
            when Array # Did they give back an array of actions?
              unless proc_result.any? { |pr| ::Brick::ALL_API_ACTIONS.exclude?(pr) }
                proc_result = [unversioned, to_relation, proc_result]
              end
              # Otherwise don't change this array because it's probably legit
            when String
              proc_result = [proc_result] # Treat this as the surfaced api_name (path) they want to use for this endpoint
            else
              puts "::Brick.api_filter Proc warning: Unable to parse this result returned: \n  #{proc_result.inspect}"
              proc_result = nil # Couldn't understand what in the world was returned
            end

            if proc_result&.present?
              if proc_result[1] # to_other_relation
                if (new_view_relation = ::Brick.relations.fetch(proc_result[1], nil))
                  k = proc_result[1] # Route this call over to this different relation
                  view_relation = new_view_relation
                else
                  puts "::Brick.api_filter Proc warning: Unable to find new suggested relation with name #{proc_result[1]} -- sticking with #{k} instead."
                end
              end
              if proc_result.first&.!=(k) # updated_api_name -- a different name than this relation would normally have
                found = proc_result.first
              end
              actions &= proc_result[2] if proc_result[2] # allowed_actions
            end
            (view_relation[:api][api_ver_num] ||= {})[unversioned] = actions # Add to the list of API paths this resource responds to

            # view_ver_num = if (first_part = k.split('_').first) =~ /^v[\d_]+/
            #                  first_part[1..-1].gsub('_', '.').to_i
            #                end
            controller_name = if (last = view_relation.fetch(:resource, nil)&.pluralize)
                                "#{full_schema_prefix}#{last}"
                              else
                                found
                              end.tr('.', '/')

            { :index => 'get', :create => 'post' }.each do |action, method|
              if actions.include?(action)
                # Normally goes to something like:  /api/v1/employees
                send(method, "#{api_root}#{unversioned.tr('.', '/')}", { to: "#{controller_prefix}#{controller_name}##{action}" })
              end
            end
            # %%% We do not yet surface the #show action
            if (id_col = view_relation[:pk]&.first) # ID-dependent stuff
              { :update => ['put', 'patch'], :destroy => ['delete'] }.each do |action, methods|
                if actions.include?(action)
                  methods.each do |method|
                    send(method, "#{api_root}#{unversioned.tr('.', '/')}/:#{id_col}", { to: "#{controller_prefix}#{controller_name}##{action}" })
                  end
                end
              end
            end
          end
        end

        # Trestle compatibility
        if Object.const_defined?('Trestle') && ::Trestle.config.options&.key?(:site_title) &&
            !Object.const_defined?("#{(res_name = resource_name.tr('/', '_')).camelize}Admin")
          begin
            ::Trestle.resource(res_sym = res_name.to_sym, model: class_name&.constantize) do
              menu { item res_sym, icon: "fa fa-star" }
            end
          rescue
          end
        end
      end

      if (named_routes = instance_variable_get(:@set).named_routes).respond_to?(:find)
        if ::Brick.config.add_status && (status_as = "#{controller_prefix.tr('/', '_')}brick_status".to_sym)
          (
            !(status_route = instance_variable_get(:@set).named_routes.find { |route| route.first == status_as }&.last) ||
            !status_route.ast.to_s.include?("/#{controller_prefix}brick_status/")
          )
          get("/#{controller_prefix}brick_status", to: 'brick_gem#status', as: status_as.to_s)
        end

        # # ::Brick.config.add_schema &&
        # # Currently can only do adding columns
        # if (schema_as = "#{controller_prefix.tr('/', '_')}brick_schema".to_sym)
        #   (
        #     !(schema_route = instance_variable_get(:@set).named_routes.find { |route| route.first == schema_as }&.last) ||
        #     !schema_route.ast.to_s.include?("/#{controller_prefix}brick_schema/")
        #   )
        #   post("/#{controller_prefix}brick_schema", to: 'brick_gem#schema_create', as: schema_as.to_s)
        # end

        if ::Brick.config.add_orphans && (orphans_as = "#{controller_prefix.tr('/', '_')}brick_orphans".to_sym)
          (
            !(orphans_route = instance_variable_get(:@set).named_routes.find { |route| route.first == orphans_as }&.last) ||
            !orphans_route.ast.to_s.include?("/#{controller_prefix}brick_orphans/")
          )
          get("/#{controller_prefix}brick_orphans", to: 'brick_gem#orphans', as: 'brick_orphans')
        end
      end

      if instance_variable_get(:@set).named_routes.names.exclude?(:brick_crosstab)
        get("/#{controller_prefix}brick_crosstab", to: 'brick_gem#crosstab', as: 'brick_crosstab')
        get("/#{controller_prefix}brick_crosstab/data", to: 'brick_gem#crosstab_data')
      end

      if ((rswag_ui_present = Object.const_defined?('Rswag::Ui')) &&
          (rswag_path = routeset_to_use.routes.find { |r| r.app.app == ::Rswag::Ui::Engine }
                                              &.instance_variable_get(:@path_formatter)
                                              &.instance_variable_get(:@parts)&.join) &&
          (doc_endpoints = ::Rswag::Ui.config.config_object[:urls])) ||
         (doc_endpoints = ::Brick.instance_variable_get(:@swagger_endpoints))
        last_endpoint_parts = nil
        doc_endpoints.each do |doc_endpoint|
          puts "Mounting OpenApi 3.0 documentation endpoint for \"#{doc_endpoint[:name]}\" on #{doc_endpoint[:url]}" unless ::Brick.routes_done
          send(:get, doc_endpoint[:url], { to: 'brick_openapi#index' })
          endpoint_parts = doc_endpoint[:url]&.split('/')
          last_endpoint_parts = endpoint_parts
        end
      end
      return if ::Brick.routes_done

      if doc_endpoints.present?
        if rswag_ui_present
          if rswag_path
            puts "API documentation now available when navigating to:  /#{last_endpoint_parts&.find(&:present?)}/index.html"
          else
            puts "In order to make documentation available you can put this into your routes.rb:"
            puts "  mount Rswag::Ui::Engine => '/#{last_endpoint_parts&.find(&:present?) || 'api-docs'}'"
          end
        else
          puts "Having this exposed, one easy way to leverage this to create HTML-based API documentation is to use Scalar.
It will jump to life when you put these two lines into a view template or other HTML resource:
  <script id=\"api-reference\" data-url=\"#{last_endpoint_parts.join('/')}\"></script>
  <script src=\"https://cdn.jsdelivr.net/@scalar/api-reference\"></script>
Alternatively you can add the rswag-ui gem."
        end
      elsif rswag_ui_present
        sample_path = rswag_path || '/api-docs'
        puts
        puts "Brick:  rswag-ui gem detected -- to make OpenAPI 3.0 documentation available from a path such as  '#{sample_path}/v1/swagger.json',"
        puts '        put code such as this in an initializer:'
        puts '  Rswag::Ui.configure do |config|'
        puts "    config.swagger_endpoint '#{sample_path}/v1/swagger.json', 'API V1 Docs'"
        puts '  end'
        unless rswag_path
          puts
          puts '        and put this into your routes.rb:'
          puts "  mount Rswag::Ui::Engine => '/api-docs'"
        end
      end

      puts "\n" if tables.present? || views.present?
      if tables.present?
        puts "Classes that can be built from tables:#{' ' * (table_class_length - 38)}  Path:"
        puts "======================================#{' ' * (table_class_length - 38)}  ====="
        ::Brick.display_classes(controller_prefix, tables, table_class_length)
      end
      if views.present?
        puts "Classes that can be built from views:#{' ' * (view_class_length - 37)}  Path:"
        puts "=====================================#{' ' * (view_class_length - 37)}  ====="
        ::Brick.display_classes(controller_prefix, views, view_class_length)
      end
      ::Brick.routes_done = true
    end
  end
end
