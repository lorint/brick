# frozen_string_literal: true

ruby '2.7.8'

source 'https://rubygems.org'
gemspec

# gem "rails-controller-testing", "~> 1.0.2"
# gem 'nokogiri', '~> 1.10.10'

if Gem::Specification.all.find{|gs| gs.name == 'activerecord'}.version < Gem::Version.new("7.1.0")
  gem 'rswag-ui'
else # Rails >= 7.1
  require 'active_record/deprecator'
end
