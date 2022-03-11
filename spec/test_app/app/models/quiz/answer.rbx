# frozen_string_literal: true

module Quiz
  class Answer < ActiveRecord::Base
    belongs_to :response
    belongs_to :question
    belongs_to :parent, class_name: 'Answer', foreign_key: :parent_id

    has_many :answer_value_list_items
    has_many :value_list_items, through: :answer_value_list_items, dependent: :destroy
    has_many :table_rows, foreign_key: 'parent_id', dependent: :destroy

    accepts_nested_attributes_for :value_list_items, allow_destroy: true, reject_if: :all_blank
    # accepts_nested_attributes_for :comments, allow_destroy: true, reject_if: :all_blank
    accepts_nested_attributes_for :table_rows, allow_destroy: true
  end
end
