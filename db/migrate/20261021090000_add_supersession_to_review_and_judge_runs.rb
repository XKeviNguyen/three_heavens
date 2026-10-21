# A failed reviewer or judge can be replaced by another model inside the same
# round. The failed run keeps its status, attempts and cost; it is marked as
# superseded by the replacement, and rounds then aggregate only runs that are
# not superseded. Only a failed run can be superseded, both columns are set
# together, and (by a composite foreign key) the replacement belongs to the
# same round.
class AddSupersessionToReviewAndJudgeRuns < ActiveRecord::Migration[8.1]
  RUNS = { review_runs: :review_round_id, judge_runs: :judge_round_id }.freeze
  # prevent_completed_record_mutation() refuses a completed round that holds
  # a failed run; a superseded failed run no longer counts. Each original must
  # occur in the installed function exactly once.
  COMPLETED_ROUND_CHECKS = [
    [
      "SELECT 1 FROM review_runs WHERE review_round_id = NEW.id AND status = 'failed'",
      "SELECT 1 FROM review_runs WHERE review_round_id = NEW.id AND status = 'failed' AND superseded_at IS NULL"
    ],
    [
      "SELECT 1 FROM judge_runs WHERE judge_round_id = NEW.id AND status = 'failed'",
      "SELECT 1 FROM judge_runs WHERE judge_round_id = NEW.id AND status = 'failed' AND superseded_at IS NULL"
    ],
    [
      "WHERE runs.judge_round_id = NEW.id\n               AND evaluations.translation_run_id = NEW.winner_translation_run_id",
      "WHERE runs.judge_round_id = NEW.id AND runs.superseded_at IS NULL\n               AND evaluations.translation_run_id = NEW.winner_translation_run_id"
    ]
  ].freeze

  def up
    execute "SET LOCAL lock_timeout = '1s'"
    RUNS.each do |table, round_column|
      add_column table, :superseded_at, :datetime
      add_column table, :superseded_by_id, :bigint
      add_index table, [ round_column, :id ], unique: true, name: "index_#{table}_on_round_and_id"
      add_index table, :superseded_by_id, unique: true, where: "superseded_by_id IS NOT NULL",
        name: "index_#{table}_on_superseded_by_id"
      execute <<~SQL
        ALTER TABLE #{table}
        ADD CONSTRAINT fk_#{table}_superseded_by_same_round
        FOREIGN KEY (#{round_column}, superseded_by_id) REFERENCES #{table} (#{round_column}, id)
      SQL
      add_check_constraint table,
        "(superseded_at IS NULL AND superseded_by_id IS NULL) OR " \
        "(superseded_at IS NOT NULL AND superseded_by_id IS NOT NULL AND status = 'failed' AND superseded_by_id <> id)",
        name: "#{table}_supersession_check"
    end
    rewrite_completed_round_checks(COMPLETED_ROUND_CHECKS)
  end

  # Rounds completed after a replacement still hold the replaced failed run;
  # the stricter checks would no longer hold for them, so refuse to roll back.
  def down
    RUNS.each_key do |table|
      if select_value("SELECT 1 FROM #{table} WHERE superseded_at IS NOT NULL LIMIT 1")
        raise ActiveRecord::IrreversibleMigration, "#{table} has replaced runs; rolling back would lose their history"
      end
    end
    rewrite_completed_round_checks(COMPLETED_ROUND_CHECKS.map(&:reverse))
    RUNS.each_key do |table|
      remove_check_constraint table, name: "#{table}_supersession_check"
      execute "ALTER TABLE #{table} DROP CONSTRAINT fk_#{table}_superseded_by_same_round"
      remove_index table, name: "index_#{table}_on_superseded_by_id"
      remove_index table, name: "index_#{table}_on_round_and_id"
      remove_column table, :superseded_by_id
      remove_column table, :superseded_at
    end
  end

  private

  # Whitespace in the installed body may differ from the literal, so each
  # literal matches with flexible whitespace and must occur exactly once.
  def rewrite_completed_round_checks(pairs)
    definition = select_value("SELECT pg_get_functiondef('public.prevent_completed_record_mutation()'::regprocedure)")
    pairs.each do |from, to|
      pattern = Regexp.new(from.split(/\s+/).map { |part| Regexp.escape(part) }.join("\\s+"))
      matches = definition.scan(pattern).size
      raise "prevent_completed_record_mutation: expected one #{from.inspect}, found #{matches}" unless matches == 1

      definition = definition.sub(pattern) { to }
    end
    execute definition
  end
end
