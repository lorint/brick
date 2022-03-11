# frozen_string_literal: true

class Animal < ActiveRecord::Base
  # Have Elephant, Cat, and Dog report a friendly name of the same instead of "Dog Animal"
  self.inheritance_column = 'species'
end
