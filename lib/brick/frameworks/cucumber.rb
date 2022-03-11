# frozen_string_literal: true

# before hook for Cucumber
Before do
  # Brick.enable_routes = true
  # Brick.enable_models = true
  # Brick.enable_controllers = true
  # Brick.enable_views = true
  Brick.request.whodunnit = nil
  Brick.request.controller_info = {} if defined?(::Rails)
end

module Brick
  module Cucumber
    # Helper method for disabling Brick in Cucumber features
    module Extensions
      def without_brick
        was_enable_routes = ::Brick.enable_routes?
        # was_enable_models = ::Brick.enable_models?
        # was_enable_controllers = ::Brick.enable_controllers?
        # was_enable_views = ::Brick.enable_views?
        ::Brick.enable_routes = false
        # ::Brick.enable_models = false
        # ::Brick.enable_controllers = false
        # ::Brick.enable_views = false
        begin
          yield
        ensure
          ::Brick.enable_routes = was_enable_routes
          # ::Brick.enable_models = was_enable_models
          # ::Brick.enable_controllers = was_enable_controllers
          # ::Brick.enable_views = was_enable_views
        end
      end
    end
  end
end

World Brick::Cucumber::Extensions
