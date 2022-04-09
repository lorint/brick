# frozen_string_literal: true

class ApplicationController < ActionController::Base
  protect_from_forgery

  if respond_to?(:before_action)
    # Some applications and libraries modify `current_user`. Their changes need
    # to be reflected in `whodunnit`, so the `set_brick_whodunnit` below
    # must happen after this.
    before_action :modify_current_user

    # Brick used to add this callback automatically. Now people are required to add
    # it themselves, like this, allowing them to control the order of callbacks.
    # The `modify_current_user` callback above shows why this control is useful.
    before_action :set_brick_whodunnit
  else # Rails < 4.0 uses #before_filter instead of #before_action
    before_filter :modify_current_user
    before_filter :set_brick_whodunnit
  end

  def rescue_action(e)
    raise e
  end

  # Returns id of hypothetical current user
  attr_reader :current_user

  def info_for_brick
    { ip: request.remote_ip, user_agent: request.user_agent }
  end

private

  def modify_current_user
    @current_user = OpenStruct.new(id: 153)
  end
end
