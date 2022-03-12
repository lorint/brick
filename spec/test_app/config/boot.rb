# frozen_string_literal: true

require 'rubygems'

# When you run rake locally (not on travis) in this test app, set the
# BUNDLE_GEMFILE env. variable to ensure that the correct version of AR is used
# for e.g. migrations. See examples in CONTRIBUTING.md.
unless ENV.key?('BUNDLE_GEMFILE')
  gemfile = File.expand_path('../../../Gemfile', __dir__)
  if File.exist?(gemfile)
    puts "Booting DF test app: Using gemfile: #{gemfile}"
    ENV['BUNDLE_GEMFILE'] = gemfile
  end
end
require 'bundler'
Bundler.setup

$LOAD_PATH.unshift(File.expand_path('../../../lib', __dir__))
