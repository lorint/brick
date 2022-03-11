# frozen_string_literal: true

# :nodoc:
module Brick
  module Util
    # ===================================
    # Epic require patch
    def self._patch_require(module_filename, folder_matcher, search_text, replacement_text, autoload_symbol = nil, is_bundler = false)
      mod_name_parts = module_filename.split('.')
      extension = case mod_name_parts.last
                  when 'rb', 'so', 'o'
                    module_filename = mod_name_parts[0..-2].join('.')
                    ".#{mod_name_parts.last}"
                  else
                    '.rb'
                  end

      if autoload_symbol
        unless Object.const_defined?('ActiveSupport::Dependencies')
          require 'active_support'
          require 'active_support/dependencies'
        end
        alp = ActiveSupport::Dependencies.autoload_paths
        custom_require_dir = ::Brick::Util._custom_require_dir
        # Create any missing folder structure leading up to this file
        module_filename.split('/')[0..-2].inject(custom_require_dir) do |s, part|
          new_part = File.join(s, part)
          Dir.mkdir(new_part) unless Dir.exist?(new_part)
          new_part
        end
        if ::Brick::Util._write_patched(folder_matcher, module_filename, extension, custom_require_dir, nil, search_text, replacement_text) &&
           !alp.include?(custom_require_dir)
          alp.unshift(custom_require_dir)
        end
      elsif is_bundler
        puts "Bundler hack"
        require 'pry-byebug'
        binding.pry
        x = 5
        # bin_path
        # puts Bundler.require.inspect
      else
        unless (require_overrides = ::Brick::Util.instance_variable_get(:@_require_overrides))
          ::Brick::Util.instance_variable_set(:@_require_overrides, (require_overrides = {}))

          # Patch "require" itself so that when it specifically sees "active_support/values/time_zone" then
          # a copy is taken of the original, an attempt is made to find the line with a circular error, that
          # single line is patched, and then an updated version is written to a temporary folder which is
          # then required in place of the original.

          Kernel.module_exec do
            # class << self
            alias_method :orig_require, :require
            # end
            # To be most faithful to Ruby's normal behaviour, this should look like a public singleton
            define_method(:require) do |name|
              puts name if name.to_s.include?('cucu')
              if (require_override = ::Brick::Util.instance_variable_get(:@_require_overrides)[name])
                extension, folder_matcher, search_text, replacement_text, autoload_symbol = require_override
                patched_filename = "/patched_#{name.tr('/', '_')}#{extension}"
                if $LOADED_FEATURES.find { |f| f.end_with?(patched_filename) }
                  false
                else
                  is_replaced = false
                  if (replacement_path = ::Brick::Util._write_patched(folder_matcher, name, extension, ::Brick::Util._custom_require_dir, patched_filename, search_text, replacement_text))
                    is_replaced = Kernel.send(:orig_require, replacement_path)
                  elsif replacement_path.nil?
                    puts "Couldn't find #{name} to require it!"
                  end
                  is_replaced
                end
              else
                Kernel.send(:orig_require, name)
              end
            end
          end
        end
        require_overrides[module_filename] = [extension, folder_matcher, search_text, replacement_text, autoload_symbol]
      end
    end

    def self._custom_require_dir
      unless (custom_require_dir = ::Brick::Util.instance_variable_get(:@_custom_require_dir))
        ::Brick::Util.instance_variable_set(:@_custom_require_dir, (custom_require_dir = Dir.mktmpdir))
        # So normal Ruby require will now pick this one up
        $LOAD_PATH.unshift(custom_require_dir)
        # When Ruby is exiting, remove this temporary directory
        at_exit do
          FileUtils.rm_rf(::Brick::Util.instance_variable_get(:@_custom_require_dir))
        end
      end
      custom_require_dir
    end

    # Returns the full path to the replaced filename, or
    # false if the file already exists, and nil if it was unable to write anything.
    def self._write_patched(folder_matcher, name, extension, dir, patched_filename, search_text, replacement_text)
      # See if our replacement file might already exist for some reason
      name = +"/#{name}" unless name.start_with?('/')
      name << extension unless name.end_with?(extension)
      puts (replacement_path = "#{dir}#{patched_filename || name}")
      return false if File.exist?(replacement_path)

      # Dredge up the original .rb file, doctor it, and then require it instead
      num_written = nil
      orig_path = nil
      orig_as = nil
      # Using Ruby's approach to find files to require
      $LOAD_PATH.each do |path|
        orig_path = "#{path}#{name}"
        break if path.include?(folder_matcher) && (orig_as = File.open(orig_path))
      end
      puts [folder_matcher, name].inspect
      if (orig_text = orig_as&.read)
        File.open(replacement_path, 'w') do |replacement|
          num_written = replacement.write(orig_text.gsub(search_text, replacement_text))
        end
        orig_as.close
      end
      (num_written&.> 0) ? replacement_path : nil
    end
  end
end
