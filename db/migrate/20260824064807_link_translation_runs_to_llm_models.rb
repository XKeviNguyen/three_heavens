class LinkTranslationRunsToLlmModels < ActiveRecord::Migration[8.1]
  def change
    add_reference :translation_runs,
                  :llm_model,
                  null: false,
                  foreign_key: true

    remove_column :translation_runs, :provider, :string
    remove_column :translation_runs, :model_identifier, :string
  end
end
