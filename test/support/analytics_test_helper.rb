module AnalyticsTestHelper
  def create_analytics_model(name:, active: true)
    suffix = SecureRandom.hex(6)
    LlmModel.create!(
      gateway: "openrouter",
      provider: "analytics-provider",
      model_identifier: "analytics/#{suffix}",
      display_name: name,
      active: active
    )
  end

  def create_analytics_experiment(name:, models:, run_attributes: {}, user: nil)
    user ||= (defined?(@current_test_user) && @current_test_user) || users(:normal)
    suffix = SecureRandom.hex(6)
    project = Project.create!(
      user: user,
      name: "Analytics project #{suffix}",
      source_language: "Vietnamese",
      target_language: "English"
    )
    document = project.documents.create!(
      title: "Analytics document #{suffix}",
      source_text: "Historical source text"
    )
    experiment = document.experiments.create!(
      name: name,
      instruction_prompt: "Translate accurately.",
      status: :completed
    )
    runs = models.to_h do |model|
      attributes = with_cost_completeness(run_attributes.fetch(model, {}))
      run = experiment.translation_runs.create!(
        {
          llm_model: model,
          status: :completed,
          translated_text: "Translation by #{model.display_name}"
        }.merge(attributes)
      )
      [ model, run ]
    end

    [ experiment, runs ]
  end

  def create_review_round_with_runs(experiment:, specs:, status: :completed)
    round = experiment.create_review_round!(status: :running)
    specs.each do |spec|
      run = round.review_runs.create!(
        reviewer_llm_model: spec.fetch(:reviewer),
        cost: spec[:cost],
        cost_complete: !spec[:cost].nil?
      )
      spec.fetch(:scores, {}).each_with_index do |(translation_run, score), index|
        run.review_evaluations.create!(
          translation_run: translation_run,
          anonymous_label: BlindReviews::CandidateLabel.for(index),
          faithfulness_score: score,
          naturalness_score: score,
          terminology_score: score,
          instruction_adherence_score: score,
          overall_score: score,
          strengths: "Strengths",
          issues: "Issues",
          recommended_corrections: "Corrections"
        )
      end
      run.update!(
        status: spec.fetch(:status, :completed),
        completed_at: Time.current
      )
    end
    round.update!(status: status) unless status.to_s == "running"
    round
  end

  def create_judge_round_with_runs(review_round:, specs:, winner: nil, status: :completed)
    round = review_round.create_judge_round!(status: :running)
    specs.each do |spec|
      run = round.judge_runs.create!(
        judge_llm_model: spec.fetch(:judge),
        cost: spec[:cost],
        cost_complete: !spec[:cost].nil?
      )
      if spec.fetch(:status, :completed).to_s == "completed"
        scores = spec.fetch(:scores)
        ordered_runs = scores.keys.sort_by { |translation_run| [ -scores.fetch(translation_run), translation_run.id ] }
        ordered_runs.each_with_index do |translation_run, index|
          run.judge_evaluations.create!(
            translation_run: translation_run,
            anonymous_label: BlindReviews::CandidateLabel.for(index),
            rank: index + 1,
            overall_score: scores.fetch(translation_run),
            rationale: "Rationale",
            strengths: "Strengths",
            risks: "Risks"
          )
        end
        judge_winner = spec.fetch(:winner, ordered_runs.first)
        run.update!(
          status: :completed,
          winner_translation_run: judge_winner,
          winner_rationale: "Winner rationale",
          confidence_score: 90,
          completed_at: Time.current
        )
      else
        run.update!(status: spec.fetch(:status), completed_at: Time.current)
      end
    end
    round.update!(status: status, winner_translation_run: winner) unless status.to_s == "running"
    round
  end

  private

  def with_cost_completeness(attributes)
    return attributes unless attributes.key?(:cost)
    return attributes if attributes.key?(:cost_complete)

    attributes.merge(cost_complete: !attributes[:cost].nil?)
  end
end
