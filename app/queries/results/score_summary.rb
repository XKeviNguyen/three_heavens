module Results
  # Average overall score per candidate, and across all candidates, from the
  # finished runs of a review or judging round. Works on the runs the page has
  # already loaded (current runs only: replaced runs are not part of the
  # round), so it runs no queries. Returns nil until a run has finished.
  class ScoreSummary
    Candidate = Data.define(:translation_run, :average, :count, :delta)
    Result = Data.define(:average, :candidates, :finished_runs, :total_runs, :scale)

    def self.call(runs, evaluations:, scale:)
      runs = runs.to_a
      finished = runs.select(&:completed?)
      scored = finished.flat_map { |run| run.public_send(evaluations).to_a }.select(&:overall_score)
      return if scored.empty?

      groups = scored.group_by(&:translation_run_id).values
      averages = groups.map { |group| group.sum(&:overall_score).fdiv(group.size) }
      average = averages.sum.fdiv(averages.size)
      candidates = groups.zip(averages).map do |group, candidate_average|
        Candidate.new(translation_run: group.first.translation_run, average: candidate_average,
                      count: group.size, delta: candidate_average - average)
      end
      Result.new(
        average: average,
        candidates: candidates.sort_by { |candidate| [ -candidate.average, candidate.translation_run.id ] },
        finished_runs: finished.size, total_runs: runs.size, scale: scale
      )
    end
  end
end
