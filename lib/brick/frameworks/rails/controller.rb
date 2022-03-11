# frozen_string_literal: true

module Brick
  module Rails
    # Extensions to rails controllers. Provides convenient ways to pass certain
    # information to the model layer, with `controller_info` and `whodunnit`.
    # Also includes a convenient on/off switch,
    # `brick_enabled_for_controller`.
    module Controller
      def self.included(controller)
        controller.before_action(
          :set_brick_enabled_for_controller,
          :set_brick_controller_info
        )
      end

    protected

      # Returns the user who is responsible for any changes that occur.
      # By default this calls `current_user` and returns the result.
      #
      # Override this method in your controller to call a different
      # method, e.g. `current_person`, or anything you like.
      #
      # @api public
      def user_for_brick
        return unless defined?(current_user)

        ActiveSupport::VERSION::MAJOR >= 4 ? current_user.try!(:id) : current_user.try(:id)
      rescue NoMethodError
        current_user
      end
    end
  end
end

if defined?(::ActionController)
  ::ActiveSupport.on_load(:action_controller) do
    include ::Brick::Rails::Controller
  end
end
