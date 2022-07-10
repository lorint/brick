# frozen_string_literal: true

class BrickSpecMigrator
  def initialize(migrations_path)
    @migrations_path = migrations_path
  end

  def migrate
    if ::ActiveRecord.const_defined?(:MigrationContext)
      options = [@migrations_path]
      options << ::ActiveRecord::SchemaMigration if ::ActiveRecord.version >= ::Gem::Version.new('6.0')
      armc = ::ActiveRecord::MigrationContext.new(*options)
      armc.migrate if armc.needs_migration?
    else
      ::ActiveRecord::Migrator.migrate(@migrations_path)
    end
  end
end
