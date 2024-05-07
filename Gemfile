# frozen_string_literal: true

ruby '3.1.4'

source 'https://rubygems.org'
gemspec
gem 'activerecord', '~> 7.2'
# gem 'rails-controller-testing', '~> 1.0.2'
# gem 'nokogiri', '~> 1.10.10'
if (ar_ver = Gem::Specification.find_by_name('activerecord').version) >= Gem::Version.new('7.1.0')
  require 'active_record/deprecator'
  # ActiveSupport's >= 7.1.2 core_ext/*.rb extensions don't innately get loaded unless we do this
  if ar_ver >= Gem::Version.new('7.1.2')
    require 'active_support'
    require 'active_support/core_ext'
  end
end
