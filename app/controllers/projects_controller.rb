class ProjectsController < ApplicationController
  PER_PAGE = 25

  def index
    @total_count = current_user.projects.count
    @total_pages = [ (@total_count.to_f / PER_PAGE).ceil, 1 ].max
    @current_page = normalized_page(@total_pages)
    @projects = current_user.projects
      .left_joins(documents: :experiments)
      .select(<<~SQL.squish)
        projects.*,
        COUNT(DISTINCT documents.id) AS documents_count,
        COUNT(DISTINCT experiments.id) AS experiments_count,
        MAX(COALESCE(experiments.updated_at, documents.updated_at, projects.updated_at)) AS latest_activity_at
      SQL
      .group("projects.id")
      .order(Arel.sql("latest_activity_at DESC"), id: :desc)
      .offset((@current_page - 1) * PER_PAGE)
      .limit(PER_PAGE)
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
