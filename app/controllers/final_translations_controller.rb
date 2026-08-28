class FinalTranslationsController < ApplicationController
  before_action :set_final_translation, except: :create

  def create
    judge_round = current_user.judge_rounds.find(params[:judge_round_id])
    final_translation = FinalTranslations::Create.call(judge_round: judge_round)
    redirect_to final_translation, notice: "Final translation workspace is ready."
  rescue FinalTranslations::EligibilityError => error
    redirect_to judge_round, alert: error.message
  end

  def show
    load_workspace
  end

  def save_revision
    attributes = exact_parameters!(:final_translation, %w[content expected_version_number change_note])
    FinalTranslations::SaveRevision.call(
      final_translation: @final_translation,
      content: attributes.fetch("content", ""),
      expected_version_number: attributes["expected_version_number"],
      change_note: attributes["change_note"]
    )
    redirect_to @final_translation, notice: "Revision saved."
  rescue FinalTranslations::StaleVersionError => error
    @submitted_content = attributes&.fetch("content", "")
    render_workspace_error(error, :conflict)
  rescue FinalTranslations::InvalidStateError, ActionController::ParameterMissing => error
    @submitted_content = attributes&.fetch("content", "")
    render_workspace_error(error, :unprocessable_content)
  end

  def restore_revision
    attributes = exact_parameters!(:restore, %w[version_id expected_version_number])
    FinalTranslations::RestoreRevision.call(
      final_translation: @final_translation,
      version_id: attributes["version_id"],
      expected_version_number: attributes["expected_version_number"]
    )
    redirect_to @final_translation, notice: "Revision restored as a new version."
  rescue FinalTranslations::StaleVersionError => error
    render_workspace_error(error, :conflict)
  rescue FinalTranslations::InvalidStateError, ActiveRecord::RecordNotFound,
         ActionController::ParameterMissing => error
    render_workspace_error(error, :unprocessable_content)
  end

  def refine
    attributes = exact_parameters!(:refinement, %w[finalizer_ids], array_keys: %w[finalizer_ids])
    Finalizations::Start.call(
      final_translation: @final_translation,
      finalizer_ids: attributes["finalizer_ids"]
    )
    redirect_to @final_translation, notice: "AI refinement started."
  rescue FinalTranslations::Error, ActionController::ParameterMissing => error
    render_workspace_error(error, :unprocessable_content)
  end

  def apply_proposal
    attributes = exact_parameters!(:proposal, %w[finalization_run_id])
    Finalizations::ApplyProposal.call(
      final_translation: @final_translation,
      finalization_run_id: attributes["finalization_run_id"]
    )
    redirect_to @final_translation, notice: "AI proposal applied as a new revision."
  rescue FinalTranslations::StaleVersionError => error
    render_workspace_error(error, :conflict)
  rescue FinalTranslations::Error, ActiveRecord::RecordNotFound,
         ActionController::ParameterMissing => error
    render_workspace_error(error, :unprocessable_content)
  end

  def finalize
    reject_unexpected_optional_parameters!(:final_translation)
    FinalTranslations::ChangeStatus.finalize(final_translation: @final_translation)
    redirect_to @final_translation, notice: "Final translation finalized."
  rescue FinalTranslations::Error, ActionController::ParameterMissing => error
    render_workspace_error(error, :unprocessable_content)
  end

  def reopen
    reject_unexpected_optional_parameters!(:final_translation)
    FinalTranslations::ChangeStatus.reopen(final_translation: @final_translation)
    redirect_to @final_translation, notice: "Final translation reopened for editing."
  rescue FinalTranslations::Error, ActionController::ParameterMissing => error
    render_workspace_error(error, :unprocessable_content)
  end

  def download
    current = @final_translation.current_version
    document = @final_translation.experiment.document
    state = @final_translation.finalized? ? "final" : "draft"

    case params[:format]
    when "txt"
      send_data current.content.encode(Encoding::UTF_8),
                type: "text/plain; charset=utf-8",
                disposition: "attachment",
                filename: SourceImports::Filename.export(document.title, suffix: state, extension: "txt")
    when "docx"
      send_data DocumentExports::Docx.call(title: document.title, content: current.content),
                type: DocumentExports::Docx::CONTENT_TYPE,
                disposition: "attachment",
                filename: SourceImports::Filename.export(document.title, suffix: state, extension: "docx")
    else
      head :not_acceptable
    end
  end

  private

  def set_final_translation
    @final_translation = current_user.final_translations.find(params[:id])
  end

  def load_workspace
    @final_translation = current_user.final_translations.includes(
      :current_version,
      :source_winner_translation_run,
      experiment: { document: :project },
      judge_round: :review_round,
      versions: { source_finalization_run: :finalizer_llm_model },
      finalization_rounds: [
        :base_version,
        { finalization_runs: :finalizer_llm_model }
      ]
    ).find(@final_translation.id)
    @finalizer_models = LlmModel.active_openrouter.order(:display_name, :id)
    winner = @final_translation.source_winner_translation_run
    @winner_review_evaluations = winner.review_evaluations.includes(:review_run).order(:created_at, :id)
    @winner_judge_evaluations = winner.judge_evaluations.includes(:judge_run).order(:created_at, :id)
  end

  def render_workspace_error(error, status)
    load_workspace
    flash.now[:alert] = error.message
    render :show, status: status
  end

  def exact_parameters!(key, allowed_keys, array_keys: [])
    submitted = params.require(key)
    unless submitted.is_a?(ActionController::Parameters)
      raise ActionController::ParameterMissing, key
    end
    unexpected = submitted.keys - allowed_keys
    raise ActionController::BadRequest, "Unexpected parameters: #{unexpected.join(', ')}" if unexpected.any?
    array_keys.each do |array_key|
      value = submitted[array_key]
      unless value.nil? || value.is_a?(Array)
        raise ActionController::BadRequest, "#{array_key} must be an array"
      end
    end
    (allowed_keys - array_keys).each do |scalar_key|
      value = submitted[scalar_key]
      unless value.nil? || value.is_a?(String)
        raise ActionController::BadRequest, "#{scalar_key} must be a scalar value"
      end
    end
    scalar_keys = allowed_keys - array_keys
    submitted.permit(*scalar_keys, *array_keys.map { |array_key| { array_key => [] } }).to_h
  end

  def reject_unexpected_optional_parameters!(key)
    submitted = params[key]
    unless submitted.nil? || (submitted.is_a?(ActionController::Parameters) && submitted.empty?)
      raise ActionController::BadRequest, "Unexpected parameters"
    end
  end
end
