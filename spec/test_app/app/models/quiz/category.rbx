# frozen_string_literal: true

module Quiz
  class Category < ActiveRecord::Base
    has_many :quizzes
  end
end
