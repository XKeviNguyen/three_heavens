require "test_helper"
require_relative "../support/final_translation_test_helper"

class FinalTranslationFlowTest < ActionDispatch::IntegrationTest
  include ActiveJob::TestHelper
  include FinalTranslationTestHelper

  setup do
    @final_translation = create_final_translation_workspace
    @finalizer = create_finalizer
  end

  test "completed judge page creates or opens an idempotent workspace" do
    get judge_round_path(@final_translation.judge_round)
    assert_response :success
    assert_select "a[href='#{final_translation_path(@final_translation)}']", text: /Open final translation workspace/

    review_round = create_completed_review_round
    judge = create_judge_model
    judge_round = Judging::Start.call(review_round: review_round, judge_ids: [ judge.id ])
    clear_enqueued_jobs
    complete_judge_run(judge_round.judge_runs.first)
    Judging::ReconcileRound.call(judge_round)

    get judge_round_path(judge_round)
    assert_select "form[action='#{judge_round_final_translation_path(judge_round)}']"
    assert_difference -> { FinalTranslation.count }, 1 do
      post judge_round_final_translation_path(judge_round)
    end
    workspace = judge_round.reload.final_translation
    assert_redirected_to final_translation_path(workspace)
    assert_no_difference -> { FinalTranslation.count } do
      post judge_round_final_translation_path(judge_round)
    end
    assert_redirected_to final_translation_path(workspace)
  end

  test "workspace renders source instruction current draft evidence and escaped text" do
    experiment = @final_translation.experiment
    experiment.document.update!(source_text: "<script>source()</script> हिन्दी")
    experiment.update!(instruction_prompt: "<img src=x onerror=instruction()>")
    winner_evaluation = @final_translation.source_winner_translation_run.review_evaluations.first
    winner_evaluation.update!(issues: "<script>feedback()</script>")

    get final_translation_path(@final_translation)

    assert_response :success
    assert_select "h1", text: experiment.name
    assert_select "textarea[name='final_translation[content]']", text: @final_translation.current_version.content
    assert_includes response.body, "&lt;script&gt;source()&lt;/script&gt; हिन्दी"
    assert_includes response.body, "&lt;img src=x onerror=instruction()&gt;"
    assert_includes response.body, "&lt;script&gt;feedback()&lt;/script&gt;"
    assert_not_includes response.body, "<script>feedback()</script>"
    assert_select "a[href='#{review_round_path(@final_translation.judge_round.review_round)}']"
  end

  test "manual save and stale conflict preserve submitted text" do
    seed = @final_translation.current_version
    patch save_revision_final_translation_path(@final_translation), params: {
      final_translation: {
        content: "Browser revision",
        expected_version_number: seed.version_number,
        change_note: "Browser save"
      }
    }
    assert_redirected_to final_translation_path(@final_translation)
    assert_equal "Browser revision", @final_translation.reload.current_version.content

    patch save_revision_final_translation_path(@final_translation), params: {
      final_translation: {
        content: "Unsaved stale text <script>keep()</script>",
        expected_version_number: seed.version_number
      }
    }
    assert_response :conflict
    assert_select "[role='alert']", text: /changed after/
    assert_select "textarea", text: "Unsaved stale text <script>keep()</script>"
    assert_includes response.body, "&lt;script&gt;keep()&lt;/script&gt;"
    assert_equal "Browser revision", @final_translation.reload.current_version.content
  end

  test "revision history restores an old snapshot as a new version" do
    seed = @final_translation.current_version
    manual = FinalTranslations::SaveRevision.call(
      final_translation: @final_translation,
      content: "Manual version",
      expected_version_number: seed.version_number
    )

    get final_translation_path(@final_translation)
    assert_select "article", text: /Version 1 · Seed/
    assert_select "form[action='#{restore_revision_final_translation_path(@final_translation)}']"

    post restore_revision_final_translation_path(@final_translation), params: {
      restore: { version_id: seed.id, expected_version_number: manual.version_number }
    }
    assert_redirected_to final_translation_path(@final_translation)
    assert @final_translation.reload.current_version.restored?
    assert_equal seed.content, @final_translation.current_version.content
  end

  test "finalizer selector allows active OpenRouter only and pending rounds poll" do
    inactive = create_finalizer(active: false)
    direct = create_finalizer(gateway: "direct")
    get final_translation_path(@final_translation)

    assert_select "input[type='checkbox'][value='#{@finalizer.id}']", count: 1
    assert_select "input[type='checkbox'][value='#{inactive.id}']", count: 0
    assert_select "input[type='checkbox'][value='#{direct.id}']", count: 0

    assert_enqueued_jobs 1, only: FinalizationRunJob do
      post refine_final_translation_path(@final_translation), params: {
        refinement: { finalizer_ids: [ @finalizer.id ] }
      }
    end
    assert_redirected_to final_translation_path(@final_translation)
    get final_translation_path(@final_translation)
    assert_select "meta[http-equiv='refresh'][content='5']", count: 1
    assert_select "[role='status']", text: /refreshes automatically/
    assert_select "article", text: /Refinement from version 1/
    assert_select "section", text: /#{Regexp.escape(@finalizer.display_name)}/
  end

  test "completed and failed proposals render escaped details telemetry and explicit apply" do
    round = Finalizations::Start.call(
      final_translation: @final_translation,
      finalizer_ids: [ @finalizer.id ]
    )
    clear_enqueued_jobs
    run = complete_finalization_run(
      round.finalization_runs.first,
      proposal: "<script>proposal()</script> refined"
    )
    run.update!(
      change_summary: [ "<img src=x onerror=summary()>" ],
      terminology_notes: [ "Term note" ],
      warnings: [ "Warning" ],
      prompt_tokens: 100,
      completion_tokens: 50,
      total_tokens: 150,
      cost: BigDecimal("0.00125")
    )

    get final_translation_path(@final_translation)
    assert_includes response.body, "&lt;script&gt;proposal()&lt;/script&gt; refined"
    assert_includes response.body, "&lt;img src=x onerror=summary()&gt;"
    assert_not_includes response.body, "<script>proposal()</script>"
    assert_select "form[action='#{apply_proposal_final_translation_path(@final_translation)}']"
    assert_select "section", text: /Prompt tokens.*100/m

    post apply_proposal_final_translation_path(@final_translation), params: {
      proposal: { finalization_run_id: run.id }
    }
    assert_redirected_to final_translation_path(@final_translation)
    assert @final_translation.reload.current_version.ai_applied?

    other_round = @final_translation.finalization_rounds.create!(
      base_version: @final_translation.current_version,
      selection_key: "f" * 64
    )
    failed = other_round.finalization_runs.create!(finalizer_llm_model: create_finalizer)
    failed.update!(
      status: :failed,
      completed_at: Time.current,
      error_code: "provider_error",
      error_message: "Bearer secret-value <script>error()</script>"
    )
    Finalizations::ReconcileRound.call(other_round)
    get final_translation_path(@final_translation)
    assert_includes response.body, "[FILTERED]"
    assert_not_includes response.body, "secret-value"
    assert_includes response.body, "&lt;script&gt;error()&lt;/script&gt;"
  end

  test "finalize disables every mutation control and reopen preserves history" do
    version_count = @final_translation.versions.count
    patch finalize_final_translation_path(@final_translation)
    assert_redirected_to final_translation_path(@final_translation)

    get final_translation_path(@final_translation)
    assert_select "textarea", count: 0
    assert_select "input[type='checkbox'][name='refinement[finalizer_ids][]']", count: 0
    assert_select "form[action='#{restore_revision_final_translation_path(@final_translation)}']", count: 0
    assert_select "form[action='#{reopen_final_translation_path(@final_translation)}']", count: 1

    patch save_revision_final_translation_path(@final_translation), params: {
      final_translation: { content: "Forbidden", expected_version_number: 1 }
    }
    assert_response :unprocessable_content
    assert_equal version_count, @final_translation.reload.versions.count

    patch reopen_final_translation_path(@final_translation)
    assert_redirected_to final_translation_path(@final_translation)
    assert @final_translation.reload.draft?
    assert_equal version_count, @final_translation.versions.count
  end

  test "download is UTF-8 plain text with a safe deterministic attachment filename" do
    unicode = "Bản dịch cuối cùng — 神学"
    FinalTranslations::SaveRevision.call(
      final_translation: @final_translation,
      content: unicode,
      expected_version_number: 1
    )

    get download_final_translation_path(@final_translation)

    assert_response :success
    assert_equal unicode, response.body.force_encoding(Encoding::UTF_8)
    assert_match(%r{\Atext/plain}, response.media_type)
    assert_includes response.headers.fetch("Content-Disposition"),
                    "three-heavens-final-translation-#{@final_translation.id}.txt"
    assert_not_includes response.headers.fetch("Content-Disposition"),
                        @final_translation.experiment.document.title

    FinalTranslations::ChangeStatus.finalize(final_translation: @final_translation)
    get download_final_translation_path(@final_translation)
    assert_response :success
    assert_equal unicode, response.body.force_encoding(Encoding::UTF_8)
  end

  test "history links to the final translation and reports lifecycle" do
    get history_path
    assert_response :success
    assert_select "a[href='#{final_translation_path(@final_translation)}']", text: /Final translation \(Draft\)/
  end

  test "tampered refinement selection rejects the entire browser request" do
    inactive = create_finalizer(active: false)
    assert_no_difference [ -> { FinalizationRound.count }, -> { FinalizationRun.count } ] do
      post refine_final_translation_path(@final_translation), params: {
        refinement: { finalizer_ids: [ @finalizer.id, inactive.id ] }
      }
    end
    assert_response :unprocessable_content
    assert_select "[role='alert']", text: /active OpenRouter/
  end

  test "deactivated finalizer disappears from selection but historical proposal remains readable" do
    round = Finalizations::Start.call(
      final_translation: @final_translation,
      finalizer_ids: [ @finalizer.id ]
    )
    clear_enqueued_jobs
    complete_finalization_run(round.finalization_runs.first)
    @finalizer.update!(active: false)

    get final_translation_path(@final_translation)

    assert_response :success
    assert_select "input[type='checkbox'][value='#{@finalizer.id}']", count: 0
    assert_select "section", text: /#{Regexp.escape(@finalizer.display_name)}/
    assert_includes response.body, "Polished final translation"
  end

  test "malformed nested parameter shapes are rejected instead of coerced" do
    patch save_revision_final_translation_path(@final_translation), params: {
      final_translation: {
        content: { nested: "not text" },
        expected_version_number: 1
      }
    }
    assert_response :bad_request
    assert_equal 1, @final_translation.reload.versions.count

    post refine_final_translation_path(@final_translation), params: {
      refinement: { finalizer_ids: { nested: @finalizer.id } }
    }
    assert_response :bad_request
    assert_empty @final_translation.finalization_rounds
  end
end
