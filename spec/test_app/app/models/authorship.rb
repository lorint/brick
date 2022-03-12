# frozen_string_literal: true

class Authorship < ActiveRecord::Base
  belongs_to :book
  belongs_to :author, class_name: 'Person'
end
