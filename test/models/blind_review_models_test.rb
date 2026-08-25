require "test_helper"

class BlindReviewModelsTest < ActiveSupport::TestCase
  setup do
    project = Project.create!(
      name: "Review model tests",
      source_language: "Vietnamese",
      target_language: "Japanese"
    )
    document = project.documents.create!(title: "Source", source_text: "Source text")
    @experiment = document.experiments.create!(
      instruction_prompt: "Translate faithfully.",
      status: :completed
    )
    @first_translation = @experiment.translation_runs.create!(
      llm_model: llm_models(:openrouter_claude),
      status: :completed,
      translated_text: "First translation"
    )
    @second_translation = @experiment.translation_runs.create!(
      llm_model: llm_models(:openrouter_gpt),
      status: :completed,
      translated_text: "Second translation"
    )
    @review_round = @experiment.create_review_round!(status: :running)
    @review_run = @review_round.review_runs.create!(
      reviewer_llm_model: llm_models(:openrouter_claude)
    )
  end

  test "associations preserve review history with restricted deletion" do
    evaluation = @review_run.review_evaluations.create!(
      translation_run: @first_translation,
      anonymous_label: "Candidate A"
    )

    assert_equal @experiment, @review_round.experiment
    assert_equal @review_round, @review_run.review_round
    assert_equal llm_models(:openrouter_claude), @review_run.reviewer_llm_model
    assert_equal @review_run, evaluation.review_run
    assert_equal @first_translation, evaluation.translation_run
    assert_not @review_run.destroy
    assert_includes @review_run.errors[:base].join, "dependent"
  end

  test "validates statuses reviewer uniqueness and mapping uniqueness" do
    duplicate_reviewer = @review_round.review_runs.build(
      reviewer_llm_model: @review_run.reviewer_llm_model
    )
    invalid_round = ReviewRound.new(experiment: @experiment, status: "unknown")

    assert_not duplicate_reviewer.valid?
    assert_not invalid_round.valid?

    @review_run.review_evaluations.create!(
      translation_run: @first_translation,
      anonymous_label: "Candidate A"
    )
    duplicate_translation = @review_run.review_evaluations.build(
      translation_run: @first_translation,
      anonymous_label: "Candidate B"
    )
    duplicate_label = @review_run.review_evaluations.build(
      translation_run: @second_translation,
      anonymous_label: "Candidate A"
    )

    assert_not duplicate_translation.valid?
    assert_not duplicate_label.valid?
  end

  test "completed evaluations and aggregate terminal statuses must be internally consistent" do
    first_evaluation = @review_run.review_evaluations.create!(
      translation_run: @first_translation,
      anonymous_label: "Candidate A"
    )
    @review_run.review_evaluations.create!(
      translation_run: @second_translation,
      anonymous_label: "Candidate B"
    )

    first_evaluation.overall_score = 9
    assert_not first_evaluation.valid?

    @review_run.status = :completed
    assert_not @review_run.valid?

    @review_run.status = :failed
    @review_run.save!
    @review_round.status = :completed
    assert_not @review_round.valid?
    @review_round.status = :failed
    assert @review_round.valid?
  end

  test "database indexes enforce round reviewer and mapping uniqueness" do
    duplicate_round = ReviewRound.new(experiment: @experiment)
    assert_raises(ActiveRecord::RecordNotUnique) { duplicate_round.save!(validate: false) }

    duplicate_reviewer = @review_round.review_runs.build(
      reviewer_llm_model: @review_run.reviewer_llm_model
    )
    assert_raises(ActiveRecord::RecordNotUnique) { duplicate_reviewer.save!(validate: false) }

    @review_run.review_evaluations.create!(
      translation_run: @first_translation,
      anonymous_label: "Candidate A"
    )
    duplicate_translation = @review_run.review_evaluations.build(
      translation_run: @first_translation,
      anonymous_label: "Candidate B"
    )
    duplicate_label = @review_run.review_evaluations.build(
      translation_run: @second_translation,
      anonymous_label: "Candidate A"
    )

    assert_raises(ActiveRecord::RecordNotUnique) { duplicate_translation.save!(validate: false) }
    assert_raises(ActiveRecord::RecordNotUnique) { duplicate_label.save!(validate: false) }
  end

  test "database constraints enforce score ranges and anonymous label format" do
    invalid_score = @review_run.review_evaluations.build(
      translation_run: @first_translation,
      anonymous_label: "Candidate A",
      overall_score: 11
    )
    invalid_label = @review_run.review_evaluations.build(
      translation_run: @second_translation,
      anonymous_label: "Claude Test"
    )

    assert_raises(ActiveRecord::StatementInvalid) { invalid_score.save!(validate: false) }
    assert_raises(ActiveRecord::StatementInvalid) { invalid_label.save!(validate: false) }
  end

  test "candidate labels extend beyond Z without revealing identifiers" do
    assert_equal "Candidate A", BlindReviews::CandidateLabel.for(0)
    assert_equal "Candidate Z", BlindReviews::CandidateLabel.for(25)
    assert_equal "Candidate AA", BlindReviews::CandidateLabel.for(26)
  end
end
