# frozen_string_literal: true

module Brick
  module Rails
    # See http://guides.rubyonrails.org/engines.html
    class Engine < ::Rails::Engine
      # paths['app/models'] << 'lib/brick/frameworks/active_record/models'
      config.brick = ActiveSupport::OrderedOptions.new
      initializer 'brick.initialisation' do |app|
        Brick.enable_models = app.config.brick.fetch(:enable_models, true)
        Brick.enable_controllers = app.config.brick.fetch(:enable_controllers, true)

        # ====================================
        # Dynamically create generic templates
        # ====================================
        if (Brick.enable_views = app.config.brick.fetch(:enable_views, true))
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
                inline = case args.first
                when 'index'
                  # Something like:  <%= @categories.inspect %>
                  "<%= @#{@_brick_model.name.underscore.pluralize}.inspect %>"
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

        if (::Brick.enable_routes = app.config.brick.fetch(:enable_routes, true))
          ActionDispatch::Routing::RouteSet.class_exec do
            alias _brick_finalize_routeset! finalize!
            def finalize!(*args, **options)
              unless @finalized
                existing_controllers = routes.each_with_object({}) { |r, s| c = r.defaults[:controller]; s[c] = nil if c }
                # TODO: honour .api_only?
                # (also for controllers)
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
        if (ars = (::Brick.additional_references = app.config.brick.fetch(:additional_references, nil)))
          ars = ars.call if ars.is_a?(Proc)
          ars = ars.to_a unless ars.is_a?(Array)
          ars = [ars] unless ars.empty? || ars.first.is_a?(Array)
          ars.each do |fk|
            ::Brick._add_bt_and_hm(fk[0..2])
          end
        end
      end
    end
  end
end
