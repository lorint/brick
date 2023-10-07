# frozen_string_literal: true

if ActiveRecord.version > ::Gem::Version.new('4.2')
  TestApp::Application.routes.draw do
    # resources :articles, only: [:create]
    # resources :widgets, only: %i[create update destroy]
    mount Rswag::Ui::Engine => '/api-docs'
  end

  # Set up documentation endpoint
  Rswag::Ui.configure do |config|
    config.swagger_endpoint '/api-docs/v1/swagger.json', 'API V1 Docs'
  end
end
