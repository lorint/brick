# frozen_string_literal: true

ruby '3.2.6'

source 'https://rubygems.org'
gemspec
gem 'activerecord', '~> 8.0'
# gem 'rails-controller-testing', '~> 1.0.2'
# gem 'nokogiri', '~> 1.10.10'
gem 'duty_free'
gem 'rswag-ui'
begin
  if (ar_ver = Gem::Specification.find_by_name('activerecord').version) >= Gem::Version.new('7.1.0')
    require 'active_record/deprecator'
    # ActiveSupport's >= 7.1.2 core_ext/*.rb extensions don't innately get loaded unless we do this
    if ar_ver >= Gem::Version.new('7.1.2')
      require 'active_support'
      require 'active_support/core_ext'
    end
  end
# If ActiveRecord has never been bundled yet, avoid "There was an error parsing `Gemfile`: Could not find 'activerecord' (>= 0) among 92 total gem(s)"
rescue Gem::MissingSpecError => e
end
