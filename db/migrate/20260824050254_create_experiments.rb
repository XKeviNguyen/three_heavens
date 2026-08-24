class CreateExperiments < ActiveRecord::Migration[8.1]
  def change
    create_table :experiments do |t|
      t.references :document, null: false, foreign_key: true
      t.string :name
      t.string :status, null: false, default: "pending"

      t.timestamps
    end
  end
end
