# BUGS:
#       Apparently, models get loaded twice sometimes, causing us to get duplicate declarations.
#           Only solution is probably to make sure duplicate declarations are the same.

# TODO:
#       Write docs, including how to use it, and why I created it.
#       Allow migration_code to take a hash, indicating renamed fields.
#           Allow model and attribute renames to be specified in the generator.
#       Handle belongs_to options, especially :foreign_key, which specifies the name of the field.
#       Add indexes as appropriate -- especially for associations.
#       Allow an attribute to specify that it should be indexed. Also allow indexing of multiple fields.
#           For the latter (or maybe both), use something like HoboFields' syntax:
#               index :field_1, :field_2 # declared in same place attributes are declared
#       Handle having the primary key something other than 'id'.
#       More attribute options:
#           :validate_as      Provide some validation for things like email addresses, ZIP codes, URIs, etc.
#           :display_as       Provide some display helpers (with to_html) for Markdown, Textile, BBcode, etc.
#           :human_name       Allow overriding what human_attribute_name returns for this column.

# USAGE:
#       Copy an initializer into config/initializers/attribute_declarations.rb, to check our models.
#           ./script/generate migrations
#       Create your models:
#           ./script/generate model person --skip-migration
#       Add attribute declarations to your model:
#           class Person < ActiveRecord::Base
#             attribute :name, :string, :unique => true, :required => true
#             attribute :age, :integer, :required => true
#             belongs_to :company
#           end
#       Create migrations for any attributes declared that are not in the database schema:
#           ./script/generate migrations
#       Edit the migration files created (in db/migrate); you might want to rename some fields instead of removing and adding them.
#       Run the migrations:
#           rake db:migrate


module ActiveRecord::AttributeDeclarations

  # These are all the options that can be provided in an 'attribute' declaration. They're divided up into where they are used.
  MIGRATION_OPTIONS = [:null, :default, :limit, :scale, :precision]
  ATTRIBUTE_OPTIONS = [:protected, :read_only, :serialize, :composed_of]
  VALIDATION_OPTIONS = [:confirmation, :required, :acceptance_required, :length, :min_length, :max_length, :unique, :format, :within, :not_in, :minimum, :maximum]
  DECLARATION_OPTIONS = ATTRIBUTE_OPTIONS + MIGRATION_OPTIONS + VALIDATION_OPTIONS


  def self.included(base)
    base.extend(ClassMethods)
    base.send(:include, InstanceMethods) # Have to use send(:include) because include is a private method.
  end


  # Not sure if there's a better way to do this -- but it was easy enough to write my own.
  def self.load_all_models
    #Dir[File.join(Rails.root, 'app', 'models', '**', '*.rb')].each {|file| require File.basename(file, File.extname(file)) } # The Ruby way.
    #Dir[File.join(Rails.root, 'app', 'models', '**', '*.rb')].each {|file| load File.basename(file) } # The Rails way.
    Dir[File.join(Rails.root, 'app', 'models', '**', '*.rb')].each {|file| File.basename(file, File.extname(file)).camelize.constantize } # The Rails autoload way (prevents double-loading).
  end


  # This is raised if the user tries to declare a given attribute name more than once. TODO: Should we just log/print a warning, or merge the 2? Need to consider usage with subclasses.
  class ActiveRecord::DuplicateAttributeDeclaration < ActiveRecord::ActiveRecordError
  end


  module InstanceMethods
    # None for now.
  end


  module ClassMethods

    # Defining this by hand, because cattr_accessor didn't work here.
    def attribute_declarations
      @attribute_declarations ||= ActiveSupport::OrderedHash.new # Use an OrderedHash, so we can index by attribute name, but keep them in order they're entered.
    end  


    # This is the main (declarative) method used within models, to define what attributes the model should have.
    def attribute(name, type, options={})
      name = name.to_sym
      type = type.to_sym
      if attribute_declarations.include?(name)
        #raise ActiveRecord::DuplicateAttributeDeclaration, "Duplicate declaration of attribute :#{name.to_s} in #{self.name} model."
        puts "WARNING: Duplicate declaration of attribute :#{name.to_s} in #{self.name} model."
      end
      attribute_declarations[name] = options.merge(:type => type)
      add_validations_from_attribute_declaration(name)
      add_attribute_modifiers_from_attribute_declaration(name)
      # TODO: It'd be nice to add some database constraints to match validation constraints. But I'm not sure if migrations can handle that.
    end


    # Basically a copy of ActiveRecord::ConnectionAdapters::TableDefinition#timestamps.
    def timestamps(*args)
      options = args.extract_options!
      attribute :created_at, :datetime, options
      attribute :updated_at, :datetime, options
    end


    # This method is used in our Rails initializer, to check that all the models have attribute declarations matching the database schema. 
    def attribute_declarations_match_model_columns?
      # If no attributes have been declared in the model, ignore the model.
      return true if attribute_declarations.empty?

      # If there's no database table, and some attributes have been declared, then we need to create a migration to create the table.
      return false if !table_exists?

      # Abstract classes don't have database tables, so we can assume they're fine.
      return true if abstract_class?

      # If all the column names and attribute names are not the same, return false.
      return false if column_names_minus.sort != attribute_names_plus.sort

      # If there are no added columns, removed columns, or changed columns, then we've got a match.
      return added_columns == [] && removed_columns == [] && changed_columns == []
    end


    # Return a string of code that can be saved to a migration file and run.
    # TODO: Should we use an ERB template here, or move this to the generator and make migration_code_up/down public? Leaning toward the latter.
    def migration_code
      return '' if attribute_declarations_match_model_columns?
      result = ["class #{migration_name} < ActiveRecord::Migration"]
      result << '  def self.up'
      result << migration_code_up
      result << '  end'
      result << '  def self.down'
      result << migration_code_down
      result << '  end'
      result << 'end'
      result.join("\n")
    end


    # Note: This returns a class name, but the underscored version is also used as a file name.
    def migration_name
      # We add the current DateTime to the migration class name, as migration names have to be unique.
      table_exists? ? "Update#{table_name.camelize}#{migration_time}" : "Create#{table_name.camelize}"
    end

    def migration_time
      # We memoize the time, so multiple calls (to migration_time or migration_name) always return the same result.
      @migration_time ||= DateTime.now.to_s(:number)
    end


    # Returns an array of strings of the keys included in attribute_declarations.
    def attribute_names
      result = attribute_declarations.keys.collect{|sym| sym.to_s}
    end

    # Returns an array of strings of the keys included in attribute_declarations, plus belongs_to_names.
    def attribute_names_plus
      attribute_names + belongs_to_names
    end

    # Returns an array of strings of the column names, minus the primary key.
    def column_names_minus
      column_names.reject{|name| name == primary_key}
    end

    # Returns an array of strings of the field names (including the _id suffix) of any belongs_to associations.
    def belongs_to_names
      # TODO: The belongs_to may define a different field name than the default.
      reflect_on_all_associations.reject{|assn| assn.macro != :belongs_to}.collect{|assn| "#{assn.name}_id"}
    end


    # Returns an array of strings, listing columns that are in the attribute declarations, but not in the database schema.
    def added_columns
      attribute_names_plus.reject{|name| column_names.include?(name)}
    rescue ActiveRecord::StatementInvalid
      attribute_names_plus
    end

    # Returns an array of strings, listing columns that are in the database schema, but not in the attribute declarations.
    def removed_columns
      column_names_minus.reject{|name| attribute_names_plus.include?(name)}
    rescue ActiveRecord::StatementInvalid
      []
    end

    # Returns an array of strings, listing columns that are in both the attribute declarations and the database schema, but have a different type or options.
    def changed_columns
      changed = []
      # We only need to look at columns that we know have not been added or removed.
      (attribute_names - added_columns - removed_columns).each do |name|
        changed << name if migration_options_from_attribute_or_association(name) != migration_options_from_column(name)
      end
      return changed
    end


  private


    def add_validations_from_attribute_declaration(name)
      decl = attribute_declarations[name]
      validates_numericality_of name, :only_integer => true                         if :integer == decl[:type]
      validates_numericality_of name                                                if [:float, :decimal].include?(decl[:type])
      validates_uniqueness_of name                                                  if decl[:unique]
      validates_presence_of name                                                    if decl[:required]
      validates_confirmation_of name                                                if decl[:confirmation]
      validates_acceptance_of name                                                  if decl[:acceptance_required]
      validates_length_of name, :in => decl[:length]                                if decl[:length]
      validates_length_of name, :minimum => decl[:min_length]                       if decl[:min_length]
      validates_length_of name, :maximum => decl[:max_length]                       if decl[:max_length]
      validates_format_of name, :with => decl[:format]                              if decl[:format]
      validates_inclusion_of name, :in => decl[:within]                             if decl[:within]
      validates_exclusion_of name, :in => decl[:not_in]                             if decl[:not_in]
      validates_numericality_of name, :greater_than_or_equal_to => decl[:minimum]   if decl[:minimum]
      validates_numericality_of name, :less_than_or_equal_to => decl[:maximum]      if decl[:maximum]
      # TODO: Should we validate belongs_to or has_many associations (using validates_associated)? (NOTE: Choose one or the other, or you get infinite recursion.)
    end

    def add_attribute_modifiers_from_attribute_declaration(name)
      decl = attribute_declarations[name]
      attr_protected name                     if decl[:protected]
      attr_readonly name                      if decl[:read_only]
      serialize name                          if decl[:serialize] && decl[:serialize] == true
      serialize name, decl[:serialize]        if decl[:serialize] && decl[:serialize] != true
      composed_of name, decl[:composed_of]    if decl[:composed_of]
    end


    # Note that this returns an array of lines.
    def migration_code_up
      # NOTE: Have to include a block in create_table, due to Rails bug #2221 (up through 2.3.5).
      result = table_exists? ? [] : ["    create_table(:#{table_name}) {}"] # TODO: Determine if we need :id, :primary_key, or :options.
      result << added_columns.collect do |name|
        "    add_column    :#{table_name}, :#{name}, #{migration_options_from_attribute_or_association(name)}"
      end
      result << changed_columns.collect do |name|
        "    change_column :#{table_name}, :#{name}, #{migration_options_from_attribute_or_association(name)}"
      end
      result << removed_columns.collect do |name|
        "    remove_column :#{table_name}, :#{name}"
      end
      result.reject{|x| x.empty?}
    end

    # Note that this returns an array of lines.
    def migration_code_down
      if !table_exists?
        return "    drop_table    :#{table_name}"
      end
      result = added_columns.collect do |name|
        "    remove_column :#{table_name}, :#{name}"
      end
      result << changed_columns.collect do |name|
        "    change_column :#{table_name}, :#{name}, #{migration_options_from_column(name)}"
      end
      result << removed_columns.collect do |name|
        "    add_column    :#{table_name}, :#{name}, #{migration_options_from_column(name)}"
      end
      result.reject{|x| x.empty?}
    end


    # Generate a string representing an add_column or change_column migration (the part after the column name, including the type).
    # The 'name' param may be a string or symbol.
    # TODO: We should cache/memoize these (by name).
    def migration_options_from_attribute_or_association(name)
      decl = attribute_declarations[name.to_sym]
      # If we don't have an attribute_declaration, then it must be from a belongs_to association.
      if !decl
        decl = {:type => :integer}
      end
      type = decl[:type]
      result = [":#{type.to_s}"]
      MIGRATION_OPTIONS.each do |opt|
        result << ":#{opt.to_s} => #{to_output(decl[opt])}" if !decl[opt].nil?
      end
      return migration_options_remove_defaults(result).join(', ')
    end

    # Generate a string representing an add_column or change_column migration (the part after the column name, including the type).
    # The 'name' param may be a string or symbol.
    # TODO: We should cache/memoize these (by name).
    def migration_options_from_column(name)
      col = columns_hash[name.to_s]
      type = col.type
      result = [":#{type.to_s}"]
      MIGRATION_OPTIONS.each do |opt|
        result << ":#{opt.to_s} => #{to_output(col.send(opt))}" if !col.send(opt).nil?
      end
      return migration_options_remove_defaults(result).join(', ')
    end

    # Remove any options that have the default values.
    def migration_options_remove_defaults(a)
      a.reject!{|s| s == ':null => true'}
      a.reject!{|s| s == ':limit => 255'} if a[0] == ':string'
      a.reject!{|s| s =~ /:limit => /}    if a[0] == ':decimal'
      a
    end

    # We're outputting code, so we need special handling for strings and symbols.
    def to_output(val)
      case val
        when String then "'#{val}'" # TODO: We probably need to escape any doube-quotes in the string.
        when Symbol then ":#{val}"
        else val.to_s
      end
    end

  end

end


ActiveRecord::Base.class_eval do
  include ActiveRecord::AttributeDeclarations
end



# Look into these interesting AR class methods:
#   aggregate_mapping
#   alias_attribute
#   read_inheritable_attribute
#   reflect_on_all_*
#   reset_inheritable_attributes
#   valid_keys_for_*

