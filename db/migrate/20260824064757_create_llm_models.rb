class CreateLlmModels < ActiveRecord::Migration[8.1]
  def change
    create_table :llm_models do |t|
      t.string :gateway, null: false
      t.string :provider, null: false
      t.string :model_identifier, null: false
      t.string :display_name, null: false
      t.boolean :active, null: false, default: true

      t.timestamps
    end

    add_index :llm_models,
          [ :gateway, :model_identifier ],
          unique: true
  end
end
