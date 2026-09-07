class ProjectsController < ApplicationController
  PER_PAGE = 25

  def index
    @total_count = current_user.projects.count
    @total_pages = [ (@total_count.to_f / PER_PAGE).ceil, 1 ].max
    @current_page = normalized_page(@total_pages)
    @projects = Projects::SummaryQuery.new(project_scope: current_user.projects).call(
      offset: (@current_page - 1) * PER_PAGE,
      limit: PER_PAGE
    )
  end

  def show
    @project = current_user.projects.find(params[:id])
    @total_count = @project.documents.count
    @total_pages = [ (@total_count.to_f / PER_PAGE).ceil, 1 ].max
    @current_page = normalized_page(@total_pages)
    @documents = @project.documents
      .preload(
        experiments: [
          :glossary_revision,
          :methodology_profile_revision,
          { experiment_reference_revisions: :translation_reference_revision },
          :pipeline_run,
          :final_translation,
          { review_round: :judge_round }
        ]
      )
      .order(created_at: :desc, id: :desc)
      .offset((@current_page - 1) * PER_PAGE)
      .limit(PER_PAGE)
  end

  private

  def normalized_page(total_pages)
    requested = Integer(params[:page].presence || 1, 10)
    requested.clamp(1, total_pages)
  rescue ArgumentError, TypeError
    1
  end
end
