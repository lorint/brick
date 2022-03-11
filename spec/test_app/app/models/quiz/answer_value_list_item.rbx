# frozen_string_literal: true

module Quiz
  class AnswerValueListItem < ActiveRecord::Base
    belongs_to :answer
    belongs_to :value_list_item
  end
end
