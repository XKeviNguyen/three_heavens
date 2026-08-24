class CreateProjects < ActiveRecord::Migration[8.1]
  def change
    create_table :projects do |t|
      t.string :name, null: false
      t.text :description
      t.string :source_language, null: false
      t.string :target_language, null: false

      t.timestamps
    end
  end
end
