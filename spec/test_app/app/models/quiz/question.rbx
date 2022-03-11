# frozen_string_literal: true

module Quiz
  class Question < ActiveRecord::Base
    binding.pry
    enum question_type: [:date, :checkbox, :single_select, :multi_select, :text, :table]

    belongs_to :quiz
    belongs_to :value_list
    has_many :answers
    has_many :value_list_items, through: :value_list
    has_many :table_questions, inverse_of: :question, dependent: :destroy

    accepts_nested_attributes_for :table_questions, allow_destroy: true, reject_if: :all_blank

    validates :text, presence: true
    validates :question_type, presence: true

    amoeba do
      enable
      include_association :table_questions
    end
  end
end
