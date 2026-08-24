class CreateTranslationRuns < ActiveRecord::Migration[8.1]
  def change
    create_table :translation_runs do |t|
      t.references :experiment, null: false, foreign_key: true
      t.string :provider, null: false
      t.string :model_identifier, null: false
      t.string :status, null: false, default: "pending"
      t.text :translated_text

      t.timestamps
    end
  end
end
