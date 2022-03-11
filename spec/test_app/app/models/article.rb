# frozen_string_literal: true

class Article < ActiveRecord::Base
  def action_data_provider_method
    object_id.to_s
  end
end
