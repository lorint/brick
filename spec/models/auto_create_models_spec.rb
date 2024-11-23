# frozen_string_literal: true

require 'spec_helper'

RSpec.describe 'Auto-creation of models' do
  before(:each) do
    require_relative '../support/brick_spec_migrator'
    db_directory = "#{Rails.root}/db"
    brick_migrations_path = File.expand_path("#{db_directory}/migrate/", __FILE__)
    ::BrickSpecMigrator.new(brick_migrations_path).migrate
    ActiveRecord::Base.connection.close
  end

  it 'should auto-create models with has_many and belongs_to associations' do
    # Kitchen.unload_class('IngredientRecipe')
    expect(::Brick.relations.keys).to eq([:db_name])
    expect(Object.const_defined?('Recipe')).to be_falsey

    # Reads the existing database and populates ::Brick.relations
    ActiveRecord::Base.establish_connection(:test)

    expect((::Brick.relations.keys & ['recipes', 'ingredients', 'ingredient_recipes']).length).to eq(3)
    # Expect that Recipe has_many IngredientRecipe
    expect((recipe_associations = Recipe.reflect_on_all_associations).length).to eq(1)
    expect(recipe_associations.first.macro).to eq(:has_many)
    expect(recipe_associations.first.name).to eq(:ingredient_recipes)

    # At this point just enumerating a has_many has not created any additional models
    expect(Object.const_defined?('IngredientRecipe')).to be_falsey
    expect(Object.const_defined?('Ingredient')).to be_falsey

    # Trying to reference the associative model IngredientRecipe will build that model out,
    # as well as Ingredient because it relates with a belongs_to.
    expect((ingredient_recipe_associations = IngredientRecipe.reflect_on_all_associations).length).to eq(2)
    expect(ingredient_recipe_associations.map(&:macro)).to eq([:belongs_to, :belongs_to])
    expect(Object.const_defined?('Ingredient')).to be_truthy
  end
end
