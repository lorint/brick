# frozen_string_literal: true

require 'spec_helper'

RSpec.describe 'Auto-creation of controllers' do
  before(:each) do
    require_relative '../support/brick_spec_migrator'
    db_directory = "#{Rails.root}/db"
    brick_migrations_path = File.expand_path("#{db_directory}/migrate/", __FILE__)
    ::BrickSpecMigrator.new(brick_migrations_path).migrate
    ActiveRecord::Base.connection.close
  end

  it 'should auto-create controllers with index, show, new, create, edit, update, and destroy actions' do
    expect(::Brick.relations.keys).to eq([:db_name])
    expect(Object.const_defined?('RecipeController')).to be_falsey

    # Reads the existing database and populates ::Brick.relations
    ActiveRecord::Base.establish_connection(:test)

    # RecipeController has all standard actions
    expect(((recipe_controller = RecipeController.new).methods &
            [:index, :show, :new, :create, :edit, :update, :destroy]).length).to eq(7)
    # RecipeController has private methods for find_recipe and recipe_params
    expect((recipe_controller.private_methods & [:find_recipe, :recipe_params]).length).to eq(2)
  end
end
