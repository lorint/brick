# frozen_string_literal: true

module Quiz
  class TableRow < Answer
    has_many :table_cells, foreign_key: 'parent_id', dependent: :destroy

    accepts_nested_attributes_for :table_cells, allow_destroy: true
  end
end
