# frozen_string_literal: true

class FooHabtm < ActiveRecord::Base
  has_and_belongs_to_many :widgets
  accepts_nested_attributes_for :widgets
end
