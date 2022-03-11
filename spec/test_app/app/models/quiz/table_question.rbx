# frozen_string_literal: true

module Quiz
  class TableQuestion < Question
    belongs_to :question
  end
end
