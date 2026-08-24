class CreateDocuments < ActiveRecord::Migration[8.1]
  def change
    create_table :documents do |t|
      t.references :project, null: false, foreign_key: true
      t.string :title, null: false
      t.text :source_text, null: false

      t.timestamps
    end
  end
end
