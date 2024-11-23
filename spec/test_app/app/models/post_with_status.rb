# frozen_string_literal: true

# This model tests ActiveRecord::Enum, which was added in AR 4.1
# http://edgeguides.rubyonrails.org/4_1_release_notes.html#active-record-enums
class PostWithStatus < ActiveRecord::Base
  if respond_to?(:enum)
    if method(:enum).arity.abs == 2
      enum :status, { draft: 0, published: 1, archived: 2 }
    else
      enum status: { draft: 0, published: 1, archived: 2 }
    end
  end
end
