# frozen_string_literal: true

ruby '2.7.8'

source 'https://rubygems.org'
gemspec
# gem 'rails-controller-testing', '~> 1.0.2'
# gem 'nokogiri', '~> 1.10.10'
gem 'rswag-ui', '~> 2.11.0'
if (ar_ver = Gem::Specification.find_by_name('activerecord').version) >= Gem::Version.new('7.1.0')
  require 'active_record/deprecator'
  # ActiveSupport's >= 7.1.2 core_ext/*.rb extensions don't innately get loaded unless we do this
  if ar_ver >= Gem::Version.new('7.1.2')
    require 'active_support'
    require 'active_support/core_ext'
  end
end
