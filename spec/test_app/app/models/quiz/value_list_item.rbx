# frozen_string_literal: true

module Quiz
  class ValueListItem < ActiveRecord::Base
    belongs_to :value_list

    has_many :answer_value_list_items
    has_many :answers, through: :answer_value_list_items

    validates :value, presence: true
  end
end
