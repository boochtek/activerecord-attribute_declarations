# NOTE: Move this file directly into lib if/when we make this into a gem.

require File.expand_path(File.dirname(__FILE__) + '/../../lib/activerecord_attribute_declarations')
ActiveRecord::AttributeDeclarations.load_all_models

class MigrationsGenerator < Rails::Generator::Base
  def manifest
    record do |m|
      m.file 'initializer.rb', 'config/initializers/attribute_declarations.rb'
      m.directory 'db/migrate'
      migrations_created = 0
      # Check each AR model class. We have to use send, because subclasses is a protected method.
      ActiveRecord::Base.send(:subclasses).each do |model|
        # Check that the model columns defined in the datbase schema match the attribute declarations.
        if !model.attribute_declarations_match_model_columns?
          m.template 'migration.rb.erb', "db/migrate/#{model.migration_time}_#{model.migration_name.underscore}.rb", :assigns => {:migration_code => model.migration_code}
          migrations_created += 1
        end
      end
      m.puts "Edit the newly created migration files, then run 'rake db:migrate' to migrate the database schema." if migrations_created > 0
    end
  end
end
