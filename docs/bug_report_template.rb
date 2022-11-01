# frozen_string_literal: true

# Use this template to report Brick bugs.
# Please include only the minimum code necessary to reproduce your issue.
require 'bundler/inline'

# STEP ONE: What versions of Ruby, ActiveRecord, and Brick are you using?
gemfile(true) do
  ruby '2.7.4'
  source 'https://rubygems.org'
  gem 'activerecord', '5.2.6'
  gem 'minitest', '5.15'
  gem 'brick', '1.0.87'
  gem 'sqlite3'
end

require 'active_record'
require 'minitest/autorun'
require 'logger'

# Please use sqlite for your bug reports if possible.
ActiveRecord::Base.establish_connection(adapter: 'sqlite3', database: ':memory:')
ActiveRecord::Base.logger = nil
ActiveRecord::Schema.define do
  # STEP TWO: Define your table(s) here.
  create_table :users, force: true do |t|
    t.text :first_name, null: false
    t.timestamps null: false
  end

  create_table :roles, force: true do |t|
    t.references :name, null: false
    t.timestamps null: false
  end

  create_table :user_roles, force: true do |t|
    t.references :user, null: false
    t.references :role, null: false
  end
end
ActiveRecord::Base.logger = Logger.new($stdout)
require 'brick'

# STEP FOUR: Define your ActiveRecord models here.
class User < ActiveRecord::Base
  has_many :user_roles
end

class Role < ActiveRecord::Base
  belongs_to :user
  belongs_to :role
end

class UserRole < ActiveRecord::Base
  has_many :user_roles
end

# STEP FIVE: Please write a test that demonstrates your issue.
class BugTest < ActiveSupport::TestCase
  def test_1
    assert_difference(-> { User.count }, +1) do
      dexter = User.create(first_name: 'Dexter')
      research = Role.create(name: 'Research')
      UserRole.create(user: dexter, role: research)
    end
  end
end

# STEP SIX: Run this script using `ruby my_bug_report.rb`
