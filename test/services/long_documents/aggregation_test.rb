require "test_helper"

class LongDocuments::AggregationTest < ActiveSupport::TestCase
  test "review scores use deterministic source-character weighting" do
    experiment, plan, candidates = build_experiment("a" * 6_000)
    round = experiment.create_review_round!(status: :running)
    run = round.review_runs.create!(
      reviewer_llm_model: llm_models(:openrouter_claude),
      status: :running,
      started_at: Time.current
    )
    candidates.each_with_index do |candidate, index|
      run.review_evaluations.create!(
        translation_run: candidate,
        anonymous_label: BlindReviews::CandidateLabel.for(index)
      )
    end

    plan.segments.each_with_index do |segment, index|
      score = index.zero? ? 1 : 9
      run.review_segment_runs.create!(
        experiment_segment: segment,
        status: :completed,
        completed_at: Time.current,
        evaluations: run.review_evaluations.map { |evaluation| review_evaluation(evaluation.anonymous_label, score) },
        **budget_attributes
      )
    end

    ReviewSegments::ReconcileRun.call(run)

    assert run.reload.completed?
    assert_equal [ 4, 4 ], run.review_evaluations.order(:id).pluck(:overall_score)
  end

  test "segment Borda ties use weighted mean then stable translation run id" do
    experiment, plan, candidates = build_experiment("a" * 8_000)
    review_round = experiment.create_review_round!(status: :running)
    judge_round = review_round.create_judge_round!(status: :running)
    run = judge_round.judge_runs.create!(
      judge_llm_model: llm_models(:openrouter_claude),
      status: :running,
      started_at: Time.current
    )
    candidates.each_with_index do |candidate, index|
      run.judge_evaluations.create!(
        translation_run: candidate,
        anonymous_label: BlindReviews::CandidateLabel.for(index)
      )
    end
    labels = run.judge_evaluations.order(:anonymous_label).pluck(:anonymous_label)

    plan.segments.each_with_index do |segment, index|
      ordered_labels = index.even? ? labels : labels.reverse
      run.judge_segment_runs.create!(
        experiment_segment: segment,
        status: :completed,
        completed_at: Time.current,
        judgment: judgment(ordered_labels),
        **budget_attributes
      )
    end

    JudgeSegments::ReconcileRun.call(run)

    expected_winner = candidates.min_by(&:id)
    assert run.reload.completed?
    assert_equal expected_winner.id, run.winner_translation_run_id
    assert_equal [ 1, 2 ], run.judge_evaluations.order(:translation_run_id).pluck(:rank)
    assert_equal [ 85, 85 ], run.judge_evaluations.order(:translation_run_id).pluck(:overall_score)
    assert_equal expected_winner.id, judge_round.reload.winner_translation_run_id
  end

  private

  def build_experiment(source)
    project = users(:normal).projects.create!(
      name: "Aggregation",
      source_language: "Vietnamese",
      target_language: "Japanese"
    )
    document = project.documents.create!(title: "Weighted source", source_text: source)
    experiment = document.experiments.create!(instruction_prompt: "Translate.", status: :completed)
    plan = LongDocuments::Planner.call(experiment)
    candidates = [ llm_models(:openrouter_claude), llm_models(:openrouter_gpt) ].map do |model|
      experiment.translation_runs.create!(
        llm_model: model,
        status: :completed,
        translated_text: "translation-#{model.id}",
        completed_at: Time.current
      )
    end
    [ experiment, plan, candidates ]
  end

  def budget_attributes
    {
      context_window_tokens_snapshot: 64_000,
      max_output_tokens_snapshot: 4_096,
      estimated_input_tokens: 1_000,
      reserved_output_tokens: 4_096,
      context_safety_margin_tokens: 1_024,
      budget_policy_version: Ai::ContextBudget::POLICY_VERSION
    }
  end

  def review_evaluation(label, score)
    {
      "candidate_label" => label,
      "faithfulness_score" => score,
      "naturalness_score" => score,
      "terminology_score" => score,
      "instruction_adherence_score" => score,
      "overall_score" => score,
      "strengths" => "Strength",
      "issues" => "Issue",
      "recommended_corrections" => "Correction",
      "suggested_translation" => nil
    }
  end

  def judgment(ordered_labels)
    {
      "rankings" => ordered_labels.each_with_index.map do |label, index|
        {
          "candidate_label" => label,
          "rank" => index + 1,
          "overall_score" => index.zero? ? 80 : 90,
          "rationale" => "Rationale",
          "strengths" => "Strength",
          "risks" => "Risk"
        }
      end,
      "winner_label" => ordered_labels.first,
      "winner_rationale" => "Winner",
      "confidence_score" => 80
    }
  end
end
