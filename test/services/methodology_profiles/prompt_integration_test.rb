require "test_helper"
require_relative "../../support/final_translation_test_helper"
require_relative "../../support/methodology_profile_test_helper"

class MethodologyProfiles::PromptIntegrationTest < ActiveSupport::TestCase
  include ActiveJob::TestHelper
  include FinalTranslationTestHelper
  include MethodologyProfileTestHelper

  test "all stages use the exact experiment snapshot without methodology identity leakage" do
    profile = create_methodology_profile(
      name: "Private Method Name",
      guidance: "Prefer natural Japanese while preserving theological precision."
    )
    selected = profile.current_revision
    review_round = create_completed_review_round(
      methodology_profile_revision: selected,
      source_text: "Source theological text"
    )
    experiment = review_round.experiment

    MethodologyProfiles::Revise.call(
      methodology_profile: profile,
      expected_version: "1",
      attributes: methodology_profile_attributes(
        name: "Future Method Name",
        guidance: "Future guidance must not leak into the experiment."
      )
    )
    MethodologyProfiles::ChangeStatus.deactivate(methodology_profile: profile)

    translation = TranslationSegments::Prompt.build(
      experiment: experiment,
      source_text: experiment.document.source_text
    )
    assert_methodology_payload(translation, bounded: false, expected_guidance: selected.guidance)
    assert_includes translation.fetch(:system_prompt),
                    TranslationGuidance::Policy.precedence_statement(experiment.guidance_preference)
    assert_match(/Return only\s+the translation/, translation.fetch(:system_prompt))

    review = BlindReviews::Prompt.build(review_round.review_runs.first)
    assert_methodology_payload(review, expected_guidance: selected.guidance)

    judge_round = Judging::Start.call(review_round: review_round, judge_ids: [ create_judge_model.id ])
    clear_enqueued_jobs
    judgment = Judging::Prompt.build(judge_round.judge_runs.first)
    assert_methodology_payload(judgment, expected_guidance: selected.guidance)

    complete_judge_run(judge_round.judge_runs.first)
    Judging::ReconcileRound.call(judge_round)
    clear_enqueued_jobs
    final_translation = FinalTranslations::Create.call(judge_round: judge_round)
    finalization_run = Finalizations::Start.call(
      final_translation: final_translation,
      finalizer_ids: [ create_finalizer.id ]
    ).finalization_runs.first
    clear_enqueued_jobs
    finalization = Finalizations::Prompt.build(finalization_run)
    assert_methodology_payload(finalization, expected_guidance: selected.guidance)

    assert_equal selected, experiment.reload.methodology_profile_revision
  end

  test "no methodology uses stable null data and preserves response contracts" do
    review_round = create_completed_review_round
    experiment = review_round.experiment
    translation = TranslationSegments::Prompt.build(
      experiment: experiment,
      source_text: experiment.document.source_text
    )
    assert_nil JSON.parse(translation.fetch(:user_prompt)).fetch("translation_methodology")

    review = BlindReviews::Prompt.build(review_round.review_runs.first)
    assert_nil bounded_data(review).fetch("translation_methodology")
    assert review.fetch(:response_schema).dig(:properties, :evaluations)

    judge_round = Judging::Start.call(review_round: review_round, judge_ids: [ create_judge_model.id ])
    clear_enqueued_jobs
    judgment = Judging::Prompt.build(judge_round.judge_runs.first)
    assert_nil bounded_data(judgment).fetch("translation_methodology")
    assert judgment.fetch(:response_schema).dig(:properties, :rankings)
  end

  private

  def assert_methodology_payload(prompt, expected_guidance:, bounded: true)
    data = bounded ? bounded_data(prompt) : JSON.parse(prompt.fetch(:user_prompt))
    assert_equal expected_guidance, data.fetch("translation_methodology")
    assert_not_includes prompt.fetch(:user_prompt), "Private Method Name"
    assert_not_includes prompt.fetch(:user_prompt), "Future Method Name"
    assert_not_includes prompt.fetch(:user_prompt), users(:normal).email
    assert_not_includes prompt.fetch(:user_prompt), "methodology_profile_id"
    assert_not_includes prompt.fetch(:user_prompt), "methodology_profile_revision_id"
    assert_includes prompt.fetch(:system_prompt), "methodology"
  end

  def bounded_data(prompt)
    boundary = prompt.fetch(:user_prompt).match(/\A<([^>]+)>\n/)[1]
    JSON.parse(
      prompt.fetch(:user_prompt)
        .delete_prefix("<#{boundary}>\n")
        .delete_suffix("</#{boundary}>\n")
    )
  end
end
