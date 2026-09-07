module JudgingTestHelper
  def create_completed_review_round(candidate_texts: [ "First translation", "Second translation" ], glossary_revision: nil,
                                    methodology_profile_revision: nil, source_text: "Source text", reference_revision: nil)
    project = Project.create!(
      user: (defined?(@current_test_user) && @current_test_user) || users(:normal),
      name: "Judging tests",
      source_language: "Vietnamese",
      target_language: "Japanese"
    )
    document = project.documents.create!(title: "Source", source_text: source_text)
    experiment = document.experiments.create!(
      instruction_prompt: "Translate faithfully.",
      status: :completed,
      glossary_revision: glossary_revision,
      methodology_profile_revision: methodology_profile_revision
    )
    snapshot_reference(experiment: experiment, revision: reference_revision) if reference_revision
    candidate_models = [ llm_models(:openrouter_claude), llm_models(:openrouter_gpt) ]
    candidates = candidate_texts.each_with_index.map do |text, index|
      experiment.translation_runs.create!(
        llm_model: candidate_models.fetch(index),
        status: :completed,
        translated_text: text
      )
    end
    review_round = experiment.create_review_round!(status: :running)
    review_run = review_round.review_runs.create!(
      reviewer_llm_model: llm_models(:openrouter_claude)
    )
    candidates.each_with_index do |candidate, index|
      review_run.review_evaluations.create!(
        translation_run: candidate,
        anonymous_label: BlindReviews::CandidateLabel.for(index),
        faithfulness_score: 9 - index,
        naturalness_score: 8 - index,
        terminology_score: 9 - index,
        instruction_adherence_score: 8 - index,
        overall_score: 9 - index,
        strengths: "Strength for translation #{index + 1}",
        issues: "Issue for translation #{index + 1}",
        recommended_corrections: "Correction for translation #{index + 1}",
        suggested_translation: "Suggestion for translation #{index + 1}"
      )
    end
    review_run.update!(status: :completed, completed_at: Time.current)
    review_round.update!(status: :completed)
    review_round
  end

  def create_judge_model(suffix: SecureRandom.hex(4), active: true, gateway: "openrouter")
    LlmModel.create!(
      gateway: gateway,
      provider: "judge-provider-#{suffix}",
      model_identifier: "judge/#{suffix}",
      display_name: "Judge #{suffix}",
      active: active
    )
  end

  def complete_judge_run(judge_run, order: nil, scores: nil)
    evaluations = judge_run.judge_evaluations.order(:anonymous_label).to_a
    order ||= evaluations.map(&:anonymous_label)
    scores ||= order.each_index.to_h { |index| [ order[index], 90 - (index * 10) ] }
    order.each_with_index do |label, index|
      evaluations.find { |evaluation| evaluation.anonymous_label == label }.update!(
        rank: index + 1,
        overall_score: scores.fetch(label),
        rationale: "Rationale for #{label}",
        strengths: "Strengths for #{label}",
        risks: "Risks for #{label}"
      )
    end
    winner = evaluations.find { |evaluation| evaluation.anonymous_label == order.first }
    judge_run.update!(
      status: :completed,
      winner_translation_run: winner.translation_run,
      winner_rationale: "Best overall translation.",
      confidence_score: 88,
      completed_at: Time.current
    )
  end
end
