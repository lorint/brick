# frozen_string_literal: true

::Brick.config.mode = :on
::Brick.enable_routes = true
::Brick.enable_controllers = true
::Brick.enable_api = true
::Brick.api_roots = ['/api/v1/', '/api/v2/'] # Paths from which to serve out API resources

if ActiveRecord.version > Gem::Version.new('4.2') && ActiveRecord.version < Gem::Version.new('7.2')
  require 'rswag/ui'

  Rswag::Ui.configure do |config|
    config.swagger_endpoint '/api-docs/v1/swagger.json', 'API V1 Docs'
  end
end
