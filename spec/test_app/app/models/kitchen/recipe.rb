# frozen_string_literal: true

module Kitchen
  class Recipe < ActiveRecord::Base
    IMPORT_TEMPLATE = {
      uniques: [:name, :ingredients_name],
      required: [],
      all: [:name,
        { ingredients: [:name] }],
      as: {}
    }.freeze

    has_many :ingredient_recipes
    has_many :ingredients, through: :ingredient_recipes
  end
end
