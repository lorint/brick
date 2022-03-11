# frozen_string_literal: true

# Demonstrates the `if` and `unless` configuration options.
class Translation < ActiveRecord::Base
  # Has a `type` column, but it's not used for STI.
  # TODO: rename column
  self.inheritance_column = nil
end
