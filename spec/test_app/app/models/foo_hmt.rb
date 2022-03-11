# frozen_string_literal: true

class FooHmt < ActiveRecord::Base
  has_many :foo_hmt_widgets
  has_many :widgets, through: :foo_hmt_widgets
end
