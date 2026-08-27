require "test_helper"
require_relative "../../support/final_translation_test_helper"

class FinalTranslations::WorkflowTest < ActiveSupport::TestCase
  include ActiveJob::TestHelper
  include FinalTranslationTestHelper

  setup do
    @final_translation = create_final_translation_workspace
  end

  test "creation seeds exact official winner once and is idempotent" do
    winner = @final_translation.source_winner_translation_run
    assert_equal winner.translated_text, @final_translation.current_version.content
    assert @final_translation.current_version.seed?
    assert_equal 1, @final_translation.versions.count

    assert_no_difference [ -> { FinalTranslation.count }, -> { FinalTranslationVersion.count } ] do
      same = FinalTranslations::Create.call(judge_round: @final_translation.judge_round)
      assert_equal @final_translation, same
    end
  end

  test "creation rejects incomplete or invalid winner states and propagates programming errors" do
    review_round = create_completed_review_round
    judge = create_judge_model
    judge_round = Judging::Start.call(review_round: review_round, judge_ids: [ judge.id ])
    clear_enqueued_jobs
    judge_round.update_column(:status, "running")
    assert_raises FinalTranslations::EligibilityError do
      FinalTranslations::Create.call(judge_round: judge_round)
    end

    assert_raises ActiveRecord::RecordNotSaved do
      FinalTranslations::Create.call(judge_round: JudgeRound.new)
    end
  end

  test "manual save creates only changed versions and protects stale writes" do
    original = @final_translation.current_version
    saved = FinalTranslations::SaveRevision.call(
      final_translation: @final_translation,
      content: "Human revision",
      expected_version_number: original.version_number,
      change_note: "Clarified wording"
    )
    assert saved.manual?
    assert_equal 2, saved.version_number
    assert_equal saved, @final_translation.reload.current_version
    assert_equal original.content, original.reload.content

    assert_no_difference -> { FinalTranslationVersion.count } do
      assert_equal saved, FinalTranslations::SaveRevision.call(
        final_translation: @final_translation,
        content: "Human revision",
        expected_version_number: original.version_number
      )
    end

    error = assert_raises FinalTranslations::StaleVersionError do
      FinalTranslations::SaveRevision.call(
        final_translation: @final_translation,
        content: "Stale overwrite",
        expected_version_number: original.version_number
      )
    end
    assert_match(/changed after/, error.message)
    assert_equal "Human revision", @final_translation.reload.current_version.content
  end

  test "manual save rejects blank overlong and finalized edits" do
    [ "", " " ].each do |content|
      assert_raises FinalTranslations::InvalidStateError do
        save(content)
      end
    end
    assert_raises FinalTranslations::InvalidStateError do
      save("x" * (FinalTranslationVersion::MAX_CONTENT_LENGTH + 1))
    end

    FinalTranslations::ChangeStatus.finalize(final_translation: @final_translation)
    assert_raises FinalTranslations::InvalidStateError do
      save("Cannot edit")
    end
  end

  test "restore creates a new version without changing history and rejects stale foreign finalized restores" do
    seed = @final_translation.current_version
    manual = save("Second version")
    restored = FinalTranslations::RestoreRevision.call(
      final_translation: @final_translation,
      version_id: seed.id,
      expected_version_number: manual.version_number
    )
    assert restored.restored?
    assert_equal 3, restored.version_number
    assert_equal seed.content, restored.content
    assert_equal "Second version", manual.reload.content

    assert_raises FinalTranslations::StaleVersionError do
      FinalTranslations::RestoreRevision.call(
        final_translation: @final_translation,
        version_id: manual.id,
        expected_version_number: 2
      )
    end
    other = create_final_translation_workspace
    assert_raises ActiveRecord::RecordNotFound do
      FinalTranslations::RestoreRevision.call(
        final_translation: @final_translation,
        version_id: other.current_version_id,
        expected_version_number: 3
      )
    end
    FinalTranslations::ChangeStatus.finalize(final_translation: @final_translation)
    assert_raises FinalTranslations::InvalidStateError do
      FinalTranslations::RestoreRevision.call(
        final_translation: @final_translation,
        version_id: seed.id,
        expected_version_number: 3
      )
    end
  end

  test "finalize and reopen preserve version history without creating revisions" do
    count = @final_translation.versions.count
    FinalTranslations::ChangeStatus.finalize(final_translation: @final_translation)
    assert @final_translation.finalized?
    assert_not_nil @final_translation.finalized_at
    assert_equal count, @final_translation.versions.count

    FinalTranslations::ChangeStatus.reopen(final_translation: @final_translation)
    assert @final_translation.draft?
    assert_nil @final_translation.finalized_at
    assert_equal count, @final_translation.versions.count
  end

  private

  def save(content)
    FinalTranslations::SaveRevision.call(
      final_translation: @final_translation,
      content: content,
      expected_version_number: @final_translation.reload.current_version.version_number
    )
  end
end
