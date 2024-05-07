# frozen_string_literal: true

$LOAD_PATH.unshift File.expand_path('lib', __dir__)
require 'brick/version_number'

gem_spec = Gem::Specification.new do |s|
  s.name = 'brick'
  s.version = Brick::VERSION::STRING
  s.platform = Gem::Platform::RUBY
  s.summary = 'Create a Rails app from data alone'
  s.description = <<~EOS
    Auto-create models, views, controllers, and routes with this slick Rails extension
  EOS
  s.homepage = 'https://github.com/lorint/brick'
  s.authors = ['Lorin Thwaits']
  s.email = 'lorint@gmail.com'
  s.license = 'MIT'

  s.files = `git ls-files -z`.split("\x0").select do |f|
    f.match(%r{^(Gemfile|LICENSE|lib|brick.gemspec)/})
  end
  s.executables = []
  s.require_paths = ['lib']

  s.required_rubygems_version = '>= 1.3.6'
  # rubocop:disable Gemspec/RequiredRubyVersion
  s.required_ruby_version = '>= 2.3.8'
  # rubocop:enable Gemspec/RequiredRubyVersion

  require 'brick/util'

  # While only Rails 4.2 and above are officially supported, there are some useful patches
  # that will work in older versions of Rails.
  s.add_dependency 'activerecord', ['>= 3.1.1']
  s.add_dependency 'fancy_gets'

  s.add_development_dependency 'appraisal', '~> 2.2'
  s.add_development_dependency 'pry-byebug', '~> 3.7.0'
  # s.add_development_dependency 'byebug'
  s.add_development_dependency 'ffaker', '~> 2.11'
  s.add_development_dependency 'generator_spec', '~> 0.9.4'
  s.add_development_dependency 'memory_profiler', '~> 0.9.14'
  s.add_development_dependency 'rake', '~> 13.0'
  s.add_development_dependency 'rspec-rails'
  s.add_development_dependency 'rubocop', '~> 0.93'
  s.add_development_dependency 'rubocop-rspec', '~> 1.42.0'

  # Check for presence of libmysqlclient-dev, default-libmysqlclient-dev, libmariadb-dev, mysql-devel, etc
  require 'mkmf'
  have_mysql = false
  # begin
  #   ['/usr/local/lib', '/usr/local/opt/mysql/lib', '/usr/lib/mysql', '/opt/homebrew/opt/mysql/lib'].each do |lib_path|
  #     break if (have_mysql = find_library('mysqlclient', nil, lib_path))
  #   end
  # rescue
  # end
  s.add_development_dependency 'mysql2', '~> 0.5' if have_mysql
  s.add_development_dependency 'pg', '>= 0.18', '< 2.0'
  s.add_development_dependency 'sqlite3', '~> 1.4'
end

gem_spec
