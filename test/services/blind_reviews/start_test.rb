require "test_helper"

class BlindReviews::StartTest < ActiveSupport::TestCase
  include ActiveJob::TestHelper

  setup do
    project = Project.create!(
      user: users(:normal),
      name: "Blind review start tests",
      source_language: "Vietnamese",
      target_language: "Japanese"
    )
    document = project.documents.create!(title: "Source", source_text: "Source text")
    @experiment = document.experiments.create!(
      instruction_prompt: "Translate faithfully.",
      status: :completed
    )
    @first_candidate = @experiment.translation_runs.create!(
      llm_model: llm_models(:openrouter_claude),
      status: :completed,
      translated_text: "First translation"
    )
    @second_candidate = @experiment.translation_runs.create!(
      llm_model: llm_models(:openrouter_gpt),
      status: :completed,
      translated_text: "Second translation"
    )
    @reviewers = [ llm_models(:openrouter_claude), llm_models(:openrouter_gpt) ]
  end

  test "creates a round runs and persisted anonymous mappings transactionally" do
    assert_difference -> { ReviewRound.count }, 1 do
      assert_difference -> { ReviewRun.count }, 2 do
        assert_difference -> { ReviewEvaluation.count }, 4 do
          assert_enqueued_jobs 2, only: ReviewRunJob do
            @review_round = start_with(@reviewers)
          end
        end
      end
    end

    assert @review_round.running?
    assert_equal @reviewers.to_set,
                 @review_round.review_runs.map(&:reviewer_llm_model).to_set
    @review_round.review_runs.each do |run|
      assert_equal [ "Candidate A", "Candidate B" ],
                   run.review_evaluations.order(:anonymous_label).pluck(:anonymous_label)
      assert_equal [ @first_candidate.id, @second_candidate.id ].sort,
                   run.review_evaluations.pluck(:translation_run_id).sort
    end
  end

  test "supports a different anonymous mapping order for every reviewer" do
    call_count = 0
    randomizer = lambda do |candidates|
      call_count += 1
      call_count.odd? ? candidates : candidates.reverse
    end

    round = BlindReviews::Start.new(
      experiment: @experiment,
      reviewer_ids: @reviewers.map(&:id),
      randomizer: randomizer
    ).call
    runs = round.review_runs.order(:reviewer_llm_model_id)

    first_mapping = runs.first.review_evaluations.order(:anonymous_label).pluck(:translation_run_id)
    second_mapping = runs.second.review_evaluations.order(:anonymous_label).pluck(:translation_run_id)
    assert_equal first_mapping.reverse, second_mapping
  end

  test "is idempotent for an identical double submission" do
    first_round = start_with(@reviewers)
    clear_enqueued_jobs

    assert_no_difference [ -> { ReviewRound.count }, -> { ReviewRun.count }, -> { ReviewEvaluation.count } ] do
      assert_no_enqueued_jobs only: ReviewRunJob do
        repeated_round = start_with(@reviewers)
        assert_equal first_round, repeated_round
      end
    end
  end

  test "rejects a changed reviewer set after a round starts" do
    start_with(@reviewers.first(1))

    assert_raises BlindReviews::Start::AlreadyStartedError do
      start_with(@reviewers)
    end
  end

  test "rejects every ineligible experiment lifecycle state" do
    %i[pending running failed].each do |status|
      experiment = create_experiment(status: status)

      assert_raises BlindReviews::Start::InvalidExperimentStateError do
        BlindReviews::Start.call(
          experiment: experiment,
          reviewer_ids: [ @reviewers.first.id ]
        )
      end
      assert_nil experiment.reload.review_round
    end
  end

  test "requires a persisted experiment" do
    experiment = Experiment.new(
      document: @experiment.document,
      instruction_prompt: "Translate.",
      status: :completed
    )

    assert_raises ActiveRecord::RecordNotSaved do
      BlindReviews::Start.call(
        experiment: experiment,
        reviewer_ids: [ @reviewers.first.id ]
      )
    end
  end

  test "requires at least two completed nonblank translations" do
    mutate_historical_fixture { @second_candidate.update!(translated_text: " ") }

    assert_raises BlindReviews::Start::InsufficientCandidatesError do
      start_with(@reviewers.first(1))
    end
    assert_nil @experiment.reload.review_round
  end

  test "rejects missing malformed inactive unsupported and mixed reviewer selections" do
    inactive = LlmModel.create!(
      gateway: "openrouter",
      provider: "inactive-provider",
      model_identifier: "inactive/reviewer",
      display_name: "Inactive reviewer",
      active: false
    )
    unsupported = LlmModel.create!(
      gateway: "direct",
      provider: "direct-provider",
      model_identifier: "direct/reviewer",
      display_name: "Direct reviewer"
    )

    [ [], [ "bad-id" ], [ 99_999_999 ], [ inactive.id ], [ unsupported.id ],
      [ @reviewers.first.id, inactive.id ] ].each do |ids|
      assert_raises BlindReviews::Start::InvalidReviewerSelectionError do
        BlindReviews::Start.call(experiment: @experiment, reviewer_ids: ids)
      end
      assert_nil @experiment.reload.review_round
    end
  end

  test "rolls back all state and jobs when mapping creation fails" do
    invalid_randomizer = ->(candidates) { candidates.first(1) }

    assert_no_difference [ -> { ReviewRound.count }, -> { ReviewRun.count }, -> { ReviewEvaluation.count } ] do
      assert_no_enqueued_jobs only: ReviewRunJob do
        assert_raises ArgumentError do
          BlindReviews::Start.new(
            experiment: @experiment,
            reviewer_ids: @reviewers.map(&:id),
            randomizer: invalid_randomizer
          ).call
        end
      end
    end
  end

  test "does not swallow unexpected database errors" do
    failing_randomizer = lambda do |_candidates|
      raise ActiveRecord::StatementInvalid, "SQL failed"
    end

    error = assert_raises ActiveRecord::StatementInvalid do
      BlindReviews::Start.new(
        experiment: @experiment,
        reviewer_ids: [ @reviewers.first.id ],
        randomizer: failing_randomizer
      ).call
    end

    assert_equal "SQL failed", error.message
    assert_nil @experiment.reload.review_round
  end

  private

  def start_with(reviewers)
    BlindReviews::Start.call(
      experiment: @experiment,
      reviewer_ids: reviewers.map(&:id)
    )
  end

  def create_experiment(status:)
    document = @experiment.document.project.documents.create!(
      title: "#{status} source",
      source_text: "Source"
    )
    document.experiments.create!(
      instruction_prompt: "Translate.",
      status: status
    )
  end
end
