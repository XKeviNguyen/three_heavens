# Each upload action (one chosen file submitted from one page) carries a random
# request key, so a replayed or duplicated delivery resolves to the import it
# already created instead of storing a second copy. Imports created before
# this migration have no key. SourceImports expire within a day, so the table
# stays small and a plain index build holds its lock only briefly.
class AddRequestKeyToSourceImports < ActiveRecord::Migration[8.1]
  def change
    add_column :source_imports, :request_key, :string
    add_check_constraint :source_imports, "request_key IS NULL OR request_key ~ '^[0-9a-f]{32}$'",
                         name: "source_imports_request_key_check"
    add_index :source_imports, %i[user_id request_key], unique: true, where: "request_key IS NOT NULL",
              name: "index_source_imports_on_user_and_request_key"
  end
end
