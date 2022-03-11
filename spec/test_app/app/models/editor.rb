# frozen_string_literal: true

# to demonstrate a has_through association to something that does not have brick enabled
class Editor < ActiveRecord::Base
  has_many :editorships, dependent: :destroy
end
