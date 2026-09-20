class CreateTerminologyGlossaries < ActiveRecord::Migration[8.1]
  def change
    create_table :glossaries do |t|
      t.references :user, null: false, foreign_key: { on_delete: :restrict }
      t.bigint :current_revision_id
      t.boolean :active, null: false, default: true

      t.timestamps
    end
    add_index :glossaries, [ :user_id, :active ]

    create_table :glossary_revisions do |t|
      t.references :glossary, null: false, foreign_key: { on_delete: :restrict }
      t.integer :version, null: false
      t.string :name, null: false
      t.string :description
      t.string :source_language, null: false
      t.string :target_language, null: false
      t.string :configuration_digest, null: false

      t.timestamps
    end
    add_index :glossary_revisions, [ :glossary_id, :version ], unique: true
    add_index :glossary_revisions, [ :glossary_id, :id ], unique: true
    add_index :glossary_revisions, :configuration_digest
    add_check_constraint :glossary_revisions, "version > 0", name: "glossary_revisions_version_check"
    add_check_constraint :glossary_revisions, "char_length(btrim(name)) BETWEEN 1 AND 150", name: "glossary_revisions_name_check"
    add_check_constraint :glossary_revisions, "description IS NULL OR char_length(description) <= 500", name: "glossary_revisions_description_check"
    add_check_constraint :glossary_revisions, "char_length(btrim(source_language)) BETWEEN 1 AND 100", name: "glossary_revisions_source_language_check"
    add_check_constraint :glossary_revisions, "char_length(btrim(target_language)) BETWEEN 1 AND 100", name: "glossary_revisions_target_language_check"
    add_check_constraint :glossary_revisions, "char_length(configuration_digest) = 64", name: "glossary_revisions_digest_check"

    add_foreign_key :glossaries, :glossary_revisions,
                    column: [ :id, :current_revision_id ], primary_key: [ :glossary_id, :id ],
                    name: "fk_glossaries_owned_current_revision"

    create_table :glossary_entries do |t|
      t.references :glossary_revision, null: false, foreign_key: { on_delete: :restrict }
      t.integer :position, null: false
      t.string :source_term, null: false
      t.string :preferred_target_term, null: false
      t.string :note

      t.timestamps
    end
    add_index :glossary_entries, [ :glossary_revision_id, :position ], unique: true
    add_index :glossary_entries, [ :glossary_revision_id, :source_term ], unique: true
    add_check_constraint :glossary_entries, "position > 0", name: "glossary_entries_position_check"
    add_check_constraint :glossary_entries, "char_length(btrim(source_term)) BETWEEN 1 AND 200", name: "glossary_entries_source_term_check"
    add_check_constraint :glossary_entries, "char_length(btrim(preferred_target_term)) BETWEEN 1 AND 200", name: "glossary_entries_target_term_check"
    add_check_constraint :glossary_entries, "note IS NULL OR char_length(note) <= 500", name: "glossary_entries_note_check"

    add_reference :experiments, :glossary_revision,
                  foreign_key: { on_delete: :restrict }, index: true, null: true
  end
end
