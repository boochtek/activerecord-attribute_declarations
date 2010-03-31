# Load all models and check that the attribute declarations match the database schema.

# NOTE: It'd be better to have the check done right after the model is loaded.
# But there does not appear to be any hook that would allow that.
# We tried the inherited hook on ActiveRecord::Base, but it runs before any of the attributes are set, so that doesn't work.
# We tried overriding ActiveRecord::Base.connection, but that didn't work either.


# Only run this if the plugin has been loaded, and we're not in a generator.
if defined?(ActiveRecord::AttributeDeclarations) && !defined?(Rails::Generator)
  ActiveRecord::AttributeDeclarations.load_all_models

  # Check each AR model class. We have to use send, because subclasses is a protected method.
  ActiveRecord::Base.send(:subclasses).each do |model|
    if !model.attribute_declarations_match_model_columns?
      warning = "WARNING: Attribute declaration does not match database schema in #{model.name} model.\n" +
                "  Consider running './script/generate migrations'."
      Rails.logger.warn warning
      puts warning
    end
  end
end
