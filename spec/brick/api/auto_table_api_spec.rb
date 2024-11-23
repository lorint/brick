# frozen_string_literal: true

require 'spec_helper'

RSpec.describe 'Basic API usage', type: :request do
  before(:all) do
    require_relative '../../support/brick_spec_migrator'
    db_directory = "#{Rails.root}/db"
    brick_migrations_path = File.expand_path("#{db_directory}/migrate/", __FILE__)
    ::BrickSpecMigrator.new(brick_migrations_path).migrate
    ActiveRecord::Base.connection.close
    ActiveRecord::Base.establish_connection(:test)
  end

  context 'With API enabled' do
    it 'Make sure JSON documentation is available' do
      pending
      get '/api-docs/v1/swagger.json'
      expect(response.status).to eq 200

      expected_root_content = ['openapi', 'info', 'servers', 'paths']
      openapi_doc = JSON.parse(response.body)
      expect(openapi_doc.keys & expected_root_content).to match_array(expected_root_content)

      # require 'brick'
      # require 'brick/route_mapper'
      # Re-finalize routes
      # @view._routes.instance_variable_set(:@finalized, false)
      # ActionDispatch::Routing::Mapper.class_exec do
      #   include ::Brick::RouteMapper
      # end
      # @view._routes.finalize!

      # Add in routing stuff
      # (self.class._routes = ::Brick::Rails::Engine.routes).finalize!
      # class << self
      #   attr_accessor :routes
      #   # ::Rails.application.routes
      #   routes = ::Brick::Rails::Engine.routes
      # end
      # routes { ::Brick::Rails::Engine.routes }

      # self.class.instance_variable_set(:@_routes, ::Brick::Rails::Engine.routes)
      # self.class._routes.finalize!

      # Try getting info from the Employee model
      expect(openapi_doc['paths'].keys).to include('/api/v1/employees')

      # Create a sample employee
      Employee.create(first_name: 'Nancy', last_name: 'Davolio')

      # get '/api/v1/employees'
    end
  end
end
