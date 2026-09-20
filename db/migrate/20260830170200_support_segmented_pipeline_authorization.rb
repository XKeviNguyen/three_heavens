class SupportSegmentedPipelineAuthorization < ActiveRecord::Migration[8.1]
  def change
    remove_check_constraint :pipeline_runs,
                            "authorized_initial_provider_run_count = translator_count + reviewer_count + judge_count + finalizer_count",
                            name: "pipeline_runs_authorized_count_check"
    add_check_constraint :pipeline_runs,
                         <<~SQL.squish,
                           (
                             provider_work_plan = '{}'::jsonb AND
                             authorized_initial_provider_run_count = translator_count + reviewer_count + judge_count + finalizer_count
                           ) OR (
                             provider_work_plan <> '{}'::jsonb AND
                             jsonb_typeof(provider_work_plan->'roles') = 'object' AND
                             (provider_work_plan->>'authorized_initial_provider_request_slots')::integer = authorized_initial_provider_run_count AND
                             authorized_initial_provider_run_count >= translator_count + reviewer_count + judge_count + finalizer_count
                           )
                         SQL
                         name: "pipeline_runs_authorized_count_check"
  end
end
