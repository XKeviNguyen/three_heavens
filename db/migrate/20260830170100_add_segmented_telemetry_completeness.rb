class AddSegmentedTelemetryCompleteness < ActiveRecord::Migration[8.1]
  RUN_TABLES = %i[
    translation_runs review_runs judge_runs finalization_runs
  ].freeze

  def change
    RUN_TABLES.each do |table|
      add_column table, :telemetry_complete, :boolean, null: false, default: true
    end
  end
end
