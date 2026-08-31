require "test_helper"
require_relative "../../support/judging_test_helper"
require_relative "../../support/final_translation_test_helper"

class Glossaries::PromptIntegrationTest < ActiveSupport::TestCase
  include ActiveJob::TestHelper
  include JudgingTestHelper
  include FinalTranslationTestHelper

  setup do
    @glossary = Glossaries::Create.call(
      user: users(:normal),
      attributes: {
        "name" => "Terms",
        "source_language" => "Vietnamese",
        "target_language" => "Japanese",
        "entries" => [
          { "source_term" => "holy Sabbath", "preferred_target_term" => "聖なる安息日" },
          { "source_term" => "Sabbath", "preferred_target_term" => "安息日" },
          { "source_term" => "unrelated", "preferred_target_term" => "無関係" }
        ]
      }
    )
    @revision = @glossary.current_revision
  end

  test "translation review judge and finalization receive only relevant ordered mappings" do
    review_round = create_completed_review_round(
      glossary_revision: @revision,
      source_text: "The holy Sabbath is important."
    )
    experiment = review_round.experiment
    translation = TranslationSegments::Prompt.build(experiment: experiment, source_text: experiment.document.source_text)
    translation_data = JSON.parse(translation.fetch(:system_prompt).match(/\{.*\}/m)[0])
    assert_equal [ "holy Sabbath", "Sabbath" ], translation_data.fetch("terminology_requirements").map { |item| item.fetch("source_term") }
    assert_equal experiment.document.source_text, translation.fetch(:user_prompt)

    review = BlindReviews::Prompt.build(review_round.review_runs.first)
    assert_terms(review)

    judge = create_judge_model
    judge_round = Judging::Start.call(review_round: review_round, judge_ids: [ judge.id ])
    clear_enqueued_jobs
    judgment = Judging::Prompt.build(judge_round.judge_runs.first)
    assert_terms(judgment)

    final_translation = create_final_translation_workspace(glossary_revision: @revision, source_text: "The holy Sabbath is important.")
    finalizer = create_finalizer
    finalization = Finalizations::Start.call(final_translation: final_translation, finalizer_ids: [ finalizer.id ]).finalization_runs.first
    clear_enqueued_jobs
    assert_terms(Finalizations::Prompt.build(finalization))
  end

  private

  def assert_terms(prompt)
    payload = JSON.parse(prompt.fetch(:user_prompt).lines[1...-1].join)
    terms = payload.fetch("terminology_requirements")
    assert_equal [ "holy Sabbath", "Sabbath" ], terms.map { |item| item.fetch("source_term") }
    assert_not_includes terms.to_json, "unrelated"
    assert_not_includes prompt.fetch(:user_prompt), @glossary.user.email
  end
end
