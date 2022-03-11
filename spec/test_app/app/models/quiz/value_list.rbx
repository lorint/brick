# frozen_string_literal: true

module Quiz
  class ValueList < ActiveRecord::Base
    has_many :value_list_items, dependent: :destroy
    has_many :quizzes
    has_many :questions

    accepts_nested_attributes_for :value_list_items, allow_destroy: true

    validates :name, presence: true, uniqueness: { case_sensitive: false }
  end
end
