# frozen_string_literal: true

# This model tests ActiveRecord::Enum, which was added in AR 4.1
# http://edgeguides.rubyonrails.org/4_1_release_notes.html#active-record-enums
class PostWithStatus < ActiveRecord::Base
  enum status: { draft: 0, published: 1, archived: 2 } if respond_to?(:enum)
end
