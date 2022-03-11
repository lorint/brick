# frozen_string_literal: true

module Kitchen
  class IngredientRecipe < ActiveRecord::Base
    belongs_to :ingredient
    belongs_to :recipe
  end
end
