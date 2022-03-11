# frozen_string_literal: true

class BrickSpecMigrator
  def initialize(migrations_path)
    @migrations_path = migrations_path
  end

  def migrate
    if ::ActiveRecord.version >= ::Gem::Version.new('6.0')
      ::ActiveRecord::MigrationContext.new(@migrations_path, ::ActiveRecord::SchemaMigration).migrate
    elsif ::ActiveRecord.version >= ::Gem::Version.new('5.2.0.rc1')
      ::ActiveRecord::MigrationContext.new(@migrations_path).migrate
    else
      ::ActiveRecord::Migrator.migrate(@migrations_path)
    end
  end
end
