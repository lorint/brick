# frozen_string_literal: true

# This file is used by Rack-based servers to start the application.

require ::File.expand_path('config/environment', __dir__)
run TestApp::Application
Rails.application.load_server if ActiveRecord.version >= ::Gem::Version.new('7.0')
