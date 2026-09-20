class HardenAutomaticPipelineLaunchAndReconciliation < ActiveRecord::Migration[8.1]
  def change
    create_table :translation_workspace_submissions do |t|
      t.references :user, null: false, foreign_key: { on_delete: :restrict }
      t.references :experiment,
                   foreign_key: { on_delete: :restrict },
                   index: { unique: true, where: "experiment_id IS NOT NULL" }
      t.string :token_digest, null: false
      t.string :status, null: false, default: "available"
      t.datetime :expires_at, null: false
      t.datetime :consumed_at

      t.timestamps
    end

    add_index :translation_workspace_submissions,
              :token_digest,
              unique: true
    add_index :translation_workspace_submissions,
              [ :user_id, :status ]
    add_index :translation_workspace_submissions,
              [ :status, :expires_at ]
    add_check_constraint :translation_workspace_submissions,
                         "char_length(token_digest) = 64",
                         name: "translation_workspace_submissions_digest_check"
    add_check_constraint :translation_workspace_submissions,
                         "status IN ('available', 'consumed')",
                         name: "translation_workspace_submissions_status_check"
    add_check_constraint :translation_workspace_submissions,
                         "expires_at > created_at",
                         name: "translation_workspace_submissions_expiry_check"
    add_check_constraint :translation_workspace_submissions,
                         "(status = 'available' AND consumed_at IS NULL AND experiment_id IS NULL) OR " \
                           "(status = 'consumed' AND consumed_at IS NOT NULL AND experiment_id IS NOT NULL)",
                         name: "translation_workspace_submissions_lifecycle_check"

    add_column :pipeline_runs, :last_reconciled_at, :datetime
    add_index :pipeline_runs,
              [ :status, :last_reconciled_at, :id ],
              name: "index_pipeline_runs_for_fair_reconciliation"
  end
end
