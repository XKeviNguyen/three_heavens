class StrengthenFinalTranslationIntegrity < ActiveRecord::Migration[8.1]
  def change
    add_index :translation_runs,
              [ :experiment_id, :id ],
              unique: true,
              name: "index_translation_runs_on_experiment_and_id"
    add_index :judge_rounds,
              [ :id, :winner_translation_run_id ],
              unique: true,
              name: "index_judge_rounds_on_id_and_winner"
    add_index :final_translation_versions,
              :source_finalization_run_id,
              unique: true,
              where: "source_finalization_run_id IS NOT NULL",
              name: "index_final_versions_on_unique_source_run"

    add_foreign_key :final_translations,
                    :translation_runs,
                    column: [ :experiment_id, :source_winner_translation_run_id ],
                    primary_key: [ :experiment_id, :id ],
                    name: "fk_final_translations_winner_in_experiment"
    add_foreign_key :final_translations,
                    :judge_rounds,
                    column: [ :judge_round_id, :source_winner_translation_run_id ],
                    primary_key: [ :id, :winner_translation_run_id ],
                    name: "fk_final_translations_official_judge_winner"
  end
end
