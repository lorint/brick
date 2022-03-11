# frozen_string_literal: true

module Brick
  module Rails
    # See http://guides.rubyonrails.org/engines.html
    class Engine < ::Rails::Engine
      # paths['app/models'] << 'lib/brick/frameworks/active_record/models'
      config.brick = ActiveSupport::OrderedOptions.new
      initializer 'brick.initialisation' do |app|
        # Auto-routing behaviour
        if (::Brick.enable_routes = app.config.brick.fetch(:enable_routes, true))
          ::Brick.append_routes
        end
        # Brick.enable_models = app.config.brick.fetch(:enable_models, true)
        # Brick.enable_controllers = app.config.brick.fetch(:enable_controllers, true)
        # Brick.enable_views = app.config.brick.fetch(:enable_views, true)
      end
    end
  end
end
