# frozen_string_literal: true

module Kitchen
  class Ingredient < ActiveRecord::Base
    IMPORT_TEMPLATE = {
      uniques: [:name, :recipes_name],
      required: [],
      all: [:name,
        { recipes: [:name] }],
      as: {}
    }.freeze

    has_many :ingredient_recipes
    has_many :recipes, through: :ingredient_recipes
  end
end
