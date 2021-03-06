module SchemaPlus
  module ActiveRecord
    module ConnectionAdapters
      # SchemaPlus includes a MySQL implementation of the AbstractAdapter
      # extensions.  (This works with both the <tt>mysql</t> and
      # <tt>mysql2</tt> gems.)
      module MysqlAdapter

        #:enddoc:
        
        def self.included(base)
          base.class_eval do
            alias_method_chain :tables, :schema_plus
            alias_method_chain :remove_column, :schema_plus
            alias_method_chain :rename_table, :schema_plus
          end

          base.class_eval do
            include ::ActiveRecord::ConnectionAdapters::SchemaStatements::AddIndex
          end
        end

        def tables_with_schema_plus(name=nil, *args)
          tables_without_schema_plus(name, *args) - views(name)
        end

        def remove_column_with_schema_plus(table_name, column_name, type=nil, options={})
          foreign_keys(table_name).select { |foreign_key| foreign_key.column_names.include?(column_name.to_s) }.each do |foreign_key|
            remove_foreign_key(table_name, foreign_key.name)
          end
          remove_column_without_schema_plus(table_name, column_name, type, options)
        end

        def rename_table_with_schema_plus(oldname, newname)
          rename_table_without_schema_plus(oldname, newname)
          rename_indexes_and_foreign_keys(oldname, newname)
        end

        # implement cascade by removing foreign keys
        def drop_table(name, options={})
          if options[:cascade]
            reverse_foreign_keys(name).each do |foreign_key|
              remove_foreign_key(foreign_key.table_name, foreign_key.name)
            end
          end

          sql = 'DROP'
          sql += ' TEMPORARY' if options[:temporary]
          sql += ' TABLE'
          sql += ' IF EXISTS' if options[:if_exists]
          sql += " #{quote_table_name(name)}"

          execute sql
        end

        def remove_index_sql(table_name, options)
          return [] if options.delete(:if_exists) and not index_exists?(table_name, options)
          super
        end

        def remove_foreign_key_sql(table_name, *args)
          case ret = super
          when String then ret.sub(/DROP CONSTRAINT/, 'DROP FOREIGN KEY')
          else ret
          end
        end

        def remove_foreign_key(table_name, *args)
          case sql = remove_foreign_key_sql(table_name, *args)
          when String then execute "ALTER TABLE #{quote_table_name(table_name)} #{sql}"
          end
        end

        def foreign_keys(table_name, name = nil)
          results = select_all("SHOW CREATE TABLE #{quote_table_name(table_name)}", name)

          table_name = table_name.to_s
          namespace_prefix = table_namespace_prefix(table_name)

          foreign_keys = []

          results.each do |result|
            create_table_sql = result["Create Table"]
            create_table_sql.lines.each do |line|
              if line =~ /^  CONSTRAINT [`"](.+?)[`"] FOREIGN KEY \([`"](.+?)[`"]\) REFERENCES [`"](.+?)[`"] \((.+?)\)( ON DELETE (.+?))?( ON UPDATE (.+?))?,?$/
                name = $1
                column_names = $2
                references_table_name = $3
                references_table_name = namespace_prefix + references_table_name if table_namespace_prefix(references_table_name).blank?
                references_column_names = $4
                on_update = $8
                on_delete = $6
                on_update = on_update ? on_update.downcase.gsub(' ', '_').to_sym : :restrict
                on_delete = on_delete ? on_delete.downcase.gsub(' ', '_').to_sym : :restrict

                options = { :name => name,
                            :on_delete => on_delete,
                            :on_update => on_update,
                            :column_names => column_names.gsub('`', '').split(', '),
                            :references_column_names => references_column_names.gsub('`', '').split(', ') }

                foreign_keys << ForeignKeyDefinition.new(namespace_prefix + table_name,
                                                         references_table_name,
                                                         options)
              end
            end
          end

          foreign_keys
        end

        def reverse_foreign_keys(table_name, name = nil)
          results = select_all(<<-SQL, name)
        SELECT constraint_name, table_name, column_name, referenced_table_name, referenced_column_name
          FROM information_schema.key_column_usage
         WHERE table_schema = #{table_schema_sql(table_name)}
           AND referenced_table_schema = table_schema
         ORDER BY constraint_name, ordinal_position;
          SQL

          constraints = results.to_a.group_by do |r|
            r.values_at('constraint_name', 'table_name', 'referenced_table_name')
          end

          from_table_constraints = constraints.select do |(_, _, to_table), _|
            table_name_without_namespace(table_name).casecmp(to_table) == 0
          end

          from_table_constraints.map do |(constraint_name, from_table, to_table), columns|
            from_table = table_namespace_prefix(from_table) + from_table
            to_table = table_namespace_prefix(to_table) + to_table

            options = {
              :name => constraint_name,
              :column_names => columns.map { |row| row['column_name'] },
              :references_column_names => columns.map { |row| row['referenced_column_name'] }
            }

            ForeignKeyDefinition.new(from_table, to_table, options)
          end
        end

        def views(name = nil)
          views = []
          select_all("SELECT table_name FROM information_schema.views WHERE table_schema = SCHEMA()", name).each do |row|
            views << row["table_name"]
          end
          views
        end

        def view_definition(view_name, name = nil)
          results = select_all("SELECT view_definition, check_option FROM information_schema.views WHERE table_schema = SCHEMA() AND table_name = #{quote(view_name)}", name)
          return nil unless results.any?
          row = results.first
          sql = row["view_definition"]
          sql.gsub!(%r{#{quote_table_name(current_database)}[.]}, '')
          case row["check_option"]
          when "CASCADED" then sql += " WITH CASCADED CHECK OPTION"
          when "LOCAL" then sql += " WITH LOCAL CHECK OPTION"
          end
          sql
        end

        module AddColumnOptions
          def default_expr_valid?(expr)
            false # only the TIMESTAMP column accepts SQL column defaults and rails uses DATETIME
          end

          def sql_for_function(function)
            case function
            when :now then 'CURRENT_TIMESTAMP'
            end
          end
        end

        private

        def table_namespace_prefix(table_name)
          table_name.to_s =~ /(.*[.])/ ? $1 : ""
        end

        def table_schema_sql(table_name)
          table_name.to_s =~ /(.*)[.]/ ? "'#{$1}'" : "SCHEMA()"
        end

        def table_name_without_namespace(table_name)
          table_name.to_s.sub /.*[.]/, ''
        end

      end
    end
  end
end
