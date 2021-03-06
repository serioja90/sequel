# frozen-string-literal: true

module Sequel
  module Plugins
    # The pg_auto_constraint_validations plugin automatically converts some constraint
    # violation exceptions that are raised by INSERT/UPDATE queries into validation
    # failures.  This can allow for using the same error handling code for both
    # regular validation errors (checked before attempting the INSERT/UPDATE), and
    # constraint violations (raised during the INSERT/UPDATE).
    #
    # This handles the following constraint violations:
    #
    # * NOT NULL
    # * CHECK
    # * UNIQUE (except expression/functional indexes)
    # * FOREIGN KEY (both referencing and referenced by)
    #
    # If the plugin cannot convert the constraint violation error to a validation
    # error, it just reraises the initial exception, so this should not cause
    # problems if the plugin doesn't know how to convert the exception.
    #
    # This plugin is not intended as a replacement for other validations,
    # it is intended as a last resort.  The purpose of validations is to provide nice
    # error messages for the user, and the error messages generated by this plugin are
    # fairly generic.  The error messages can be customized using the :messages plugin
    # option, but there is only a single message used per constraint type.
    #
    # This plugin only works on the postgres adapter when using the pg 0.16+ driver,
    # PostgreSQL 9.3+ server, and PostgreSQL 9.3+ client library (libpq). In other cases
    # it will be a no-op.
    #
    # Example:
    #
    #   album = Album.new(:artist_id=>1) # Assume no such artist exists
    #   begin
    #     album.save
    #   rescue Sequel::ValidationFailed
    #     album.errors.on(:artist_id) # ['is invalid']
    #   end
    # 
    # Usage:
    #
    #   # Make all model subclasses automatically convert constraint violations
    #   # to validation failures (called before loading subclasses)
    #   Sequel::Model.plugin :pg_auto_constraint_validations
    #
    #   # Make the Album class automatically convert constraint violations
    #   # to validation failures
    #   Album.plugin :pg_auto_constraint_validations
    module PgAutoConstraintValidations
      (
      # The default error messages for each constraint violation type.
      DEFAULT_ERROR_MESSAGES = {
        :not_null=>"is not present",
        :check=>"is invalid",
        :unique=>'is already taken',
        :foreign_key=>'is invalid',
        :referenced_by=>'cannot be changed currently'
      }.freeze).each_value(&:freeze)

      # Setup the constraint violation metadata.  Options:
      # :messages :: Override the default error messages for each constraint
      #              violation type (:not_null, :check, :unique, :foreign_key, :referenced_by)
      def self.configure(model, opts=OPTS)
        model.instance_exec do
          setup_pg_auto_constraint_validations
          @pg_auto_constraint_validations_messages = (@pg_auto_constraint_validations_messages || DEFAULT_ERROR_MESSAGES).merge(opts[:messages] || OPTS).freeze
        end
      end

      module ClassMethods
        # Hash of metadata checked when an instance attempts to convert a constraint
        # violation into a validation failure.
        attr_reader :pg_auto_constraint_validations

        # Hash of error messages keyed by constraint type symbol to use in the
        # generated validation failures.
        attr_reader :pg_auto_constraint_validations_messages

        Plugins.inherited_instance_variables(self, :@pg_auto_constraint_validations=>nil, :@pg_auto_constraint_validations_messages=>nil)
        Plugins.after_set_dataset(self, :setup_pg_auto_constraint_validations)

        private

        # Get the list of constraints, unique indexes, foreign keys in the current
        # table, and keys in the current table referenced by foreign keys in other
        # tables.  Store this information so that if a constraint violation occurs,
        # all necessary metadata is already available in the model, so a query is
        # not required at runtime.  This is both for performance and because in
        # general after the constraint violation failure you will be inside a
        # failed transaction and not able to execute queries.
        def setup_pg_auto_constraint_validations
          return unless @dataset

          case @dataset.first_source_table
          when Symbol, String, SQL::Identifier, SQL::QualifiedIdentifier
           convert_errors = db.respond_to?(:error_info)
          end

          unless convert_errors
            # Might be a table returning function or subquery, skip handling those.
            # Might have db not support error_info, skip handling that. 
            @pg_auto_constraint_validations = nil
            return
          end

          checks = {}
          indexes = {}
          foreign_keys = {}
          referenced_by = {}

          db.check_constraints(table_name).each do |k, v|
            checks[k] = v[:columns].dup.freeze
          end
          db.indexes(table_name, :include_partial=>true).each do |k, v|
            if v[:unique]
              indexes[k] = v[:columns].dup.freeze
            end
          end
          db.foreign_key_list(table_name, :schema=>false).each do |fk|
            foreign_keys[fk[:name]] = fk[:columns].dup.freeze
          end
          db.foreign_key_list(table_name, :reverse=>true, :schema=>false).each do |fk|
            referenced_by[[fk[:schema], fk[:table], fk[:name]].freeze] = fk[:key].dup.freeze
          end

          schema, table = db[:pg_class].
            join(:pg_namespace, :oid=>:relnamespace, db.send(:regclass_oid, table_name)=>:oid).
            get([:nspname, :relname])

          (@pg_auto_constraint_validations = {
            :schema=>schema,
            :table=>table,
            :check=>checks,
            :unique=>indexes,
            :foreign_key=>foreign_keys,
            :referenced_by=>referenced_by
          }.freeze).each_value(&:freeze)
        end
      end

      module InstanceMethods
        private

        # Yield to the given block, and if a Sequel::ConstraintViolation is raised, try
        # to convert it to a Sequel::ValidationFailed error using the PostgreSQL error
        # metadata.
        def check_pg_constraint_error(ds)
          yield
        rescue Sequel::ConstraintViolation => e
          begin
            unless cv_info = model.pg_auto_constraint_validations
              # Necessary metadata does not exist, just reraise the exception.
              raise e
            end

            info = ds.db.error_info(e)
            m = ds.method(:output_identifier)
            schema = info[:schema]
            table = info[:table]
            if constraint = info[:constraint]
              constraint = m.call(constraint)
            end
            messages = model.pg_auto_constraint_validations_messages

            case e
            when Sequel::NotNullConstraintViolation
              if column = info[:column]
                add_pg_constraint_validation_error([m.call(column)], messages[:not_null])
              end
            when Sequel::CheckConstraintViolation
              if columns = cv_info[:check][constraint]
                add_pg_constraint_validation_error(columns, messages[:check])
              end
            when Sequel::UniqueConstraintViolation
              if columns = cv_info[:unique][constraint]
                add_pg_constraint_validation_error(columns, messages[:unique])
              end
            when Sequel::ForeignKeyConstraintViolation
              message_primary = info[:message_primary]
              if message_primary.start_with?('update')
                # This constraint violation is different from the others, because the constraint
                # referenced is a constraint for a different table, not for this table.  This
                # happens when another table references the current table, and the referenced
                # column in the current update is modified such that referential integrity
                # would be broken.  Use the reverse foreign key information to figure out
                # which column is affected in that case.
                skip_schema_table_check = true
                if columns = cv_info[:referenced_by][[m.call(schema), m.call(table), constraint]]
                  add_pg_constraint_validation_error(columns, messages[:referenced_by])
                end
              elsif message_primary.start_with?('insert')
                if columns = cv_info[:foreign_key][constraint]
                  add_pg_constraint_validation_error(columns, messages[:foreign_key])
                end
              end
            end
          rescue => e2
            # If there is an error trying to conver the constraint violation
            # into a validation failure, it's best to just raise the constraint
            # violation.  This can make debugging the above block of code more
            # difficult.
            raise e
          else
            unless skip_schema_table_check
              # The constraint violation could be caused by a trigger modifying 
              # a different table.  Check that the error schema and table
              # match the model's schema and table, or clear the validation error
              # that was set above.
              if schema != cv_info[:schema] || table != cv_info[:table]
                errors.clear
              end
            end

            if errors.empty?
              # If we weren't able to parse the constraint violation metadata and
              # convert it to an appropriate validation failure, or the schema/table
              # didn't match, then raise the constraint violation.
              raise e
            end

            # Integrate with error_splitter plugin to split any multi-column errors
            # and add them as separate single column errors
            if respond_to?(:split_validation_errors, true)
              split_validation_errors(errors)
            end

            vf = ValidationFailed.new(self)
            vf.set_backtrace(e.backtrace)
            vf.wrapped_exception = e
            raise vf
          end
        end

        # If there is a single column instead of an array of columns, add the error
        # for the column, otherwise add the error for the array of columns.
        def add_pg_constraint_validation_error(column, message)
          column = column.first if column.length == 1 
          errors.add(column, message)
        end

        # Convert PostgreSQL constraint errors when inserting.
        def _insert_raw(ds)
          check_pg_constraint_error(ds){super}
        end

        # Convert PostgreSQL constraint errors when inserting.
        def _insert_select_raw(ds)
          check_pg_constraint_error(ds){super}
        end

        # Convert PostgreSQL constraint errors when updating.
        def _update_without_checking(_)
          check_pg_constraint_error(_update_dataset){super}
        end
      end
    end
  end
end

