class WorkflowProfilesController < ApplicationController
  MODEL_ROLES = WorkflowProfileModelSelection::ROLES.freeze
  SCALAR_KEYS = %w[name description completion_mode expected_version].freeze
  ARRAY_KEYS = MODEL_ROLES.map { |role| "#{role}_ids" }.freeze

  before_action :set_workflow_profile, only: %i[show edit update duplicate activate deactivate]
  before_action :load_models, only: %i[new create edit update]

  def index
    @workflow_profiles = paginate(current_user.workflow_profiles.includes(
      current_revision: :model_selections
    ).order(active: :desc, updated_at: :desc, id: :desc))
  end

  def new
    @form_values = default_form_values
  end

  def create
    attributes = exact_profile_parameters!(include_expected_version: false)
    profile = WorkflowProfiles::Create.call(user: current_user, attributes: attributes)
    redirect_to profile, notice: "Workflow profile created."
  rescue WorkflowProfiles::BuildRevision::Error, ActiveRecord::RecordInvalid => error
    @form_values = safe_submitted_values
    @form_errors = error_messages(error)
    render :new, status: :unprocessable_content
  end

  def show
    @workflow_profile = current_user.workflow_profiles.find(@workflow_profile.id)
    @revisions = paginate(
      @workflow_profile.revisions.includes(:pipeline_runs, model_selections: :llm_model)
    )
  end

  def edit
    @form_values = revision_form_values(@workflow_profile.current_revision)
  end

  def update
    attributes = exact_profile_parameters!(include_expected_version: true)
    revision = WorkflowProfiles::Revise.call(
      workflow_profile: @workflow_profile,
      expected_version: attributes.delete("expected_version"),
      attributes: attributes
    )
    redirect_to @workflow_profile, notice: "Workflow profile revision #{revision.version} created."
  rescue WorkflowProfiles::Revise::StaleRevisionError => error
    @form_values = safe_submitted_values
    @form_errors = [ error.message ]
    render :edit, status: :conflict
  rescue WorkflowProfiles::BuildRevision::Error, ActiveRecord::RecordInvalid => error
    @form_values = safe_submitted_values
    @form_errors = error_messages(error)
    render :edit, status: :unprocessable_content
  end

  def duplicate
    reject_unexpected_parameters!
    duplicate = WorkflowProfiles::Duplicate.call(workflow_profile: @workflow_profile)
    redirect_to duplicate, notice: "Workflow profile duplicated."
  rescue WorkflowProfiles::BuildRevision::Error, ActiveRecord::RecordInvalid => error
    redirect_to @workflow_profile, alert: error_messages(error).join(" ")
  end

  def activate
    reject_unexpected_parameters!
    WorkflowProfiles::ChangeStatus.activate(workflow_profile: @workflow_profile)
    redirect_to @workflow_profile, notice: "Workflow profile activated."
  rescue WorkflowProfiles::ChangeStatus::IneligibleConfigurationError => error
    redirect_to @workflow_profile, alert: error.message
  end

  def deactivate
    reject_unexpected_parameters!
    WorkflowProfiles::ChangeStatus.deactivate(workflow_profile: @workflow_profile)
    redirect_to @workflow_profile, notice: "Workflow profile deactivated."
  end

  private

  def set_workflow_profile
    @workflow_profile = current_user.workflow_profiles.includes(current_revision: :model_selections).find(params[:id])
  end

  def load_models
    @available_models = LlmModel.active_openrouter.order(:display_name, :id)
  end

  def exact_profile_parameters!(include_expected_version:)
    submitted = params.require(:workflow_profile)
    raise ActionController::BadRequest, "workflow_profile must be an object" unless submitted.is_a?(ActionController::Parameters)

    scalar_keys = include_expected_version ? SCALAR_KEYS : SCALAR_KEYS - [ "expected_version" ]
    allowed = scalar_keys + ARRAY_KEYS
    raise ActionController::BadRequest, "Unexpected parameters" if (submitted.keys - allowed).any?

    scalar_keys.each do |key|
      value = submitted[key]
      raise ActionController::BadRequest, "#{key} must be a scalar" unless value.nil? || value.is_a?(String)
    end
    ARRAY_KEYS.each do |key|
      value = submitted[key]
      unless value.nil? || (value.is_a?(Array) && value.all? { |item| item.is_a?(String) })
        raise ActionController::BadRequest, "#{key} must be a list of scalar values"
      end
    end

    submitted.permit(*scalar_keys, *ARRAY_KEYS.map { |key| { key => [] } }).to_h
  end

  def reject_unexpected_parameters!
    submitted = params[:workflow_profile]
    return if submitted.nil? || (submitted.is_a?(ActionController::Parameters) && submitted.empty?)

    raise ActionController::BadRequest, "Unexpected parameters"
  end

  def default_form_values
    { "completion_mode" => "winner_draft" }.merge(ARRAY_KEYS.index_with { [] })
  end

  def revision_form_values(revision)
    {
      "name" => revision.name,
      "description" => revision.description,
      "completion_mode" => revision.completion_mode,
      "expected_version" => revision.version.to_s
    }.merge(MODEL_ROLES.to_h { |role| [ "#{role}_ids", revision.selections_for(role).map { |selection| selection.llm_model_id.to_s } ] })
  end

  def safe_submitted_values
    submitted = params[:workflow_profile]
    return default_form_values unless submitted.is_a?(ActionController::Parameters)

    default_form_values.merge(submitted.to_unsafe_h.slice(*(SCALAR_KEYS + ARRAY_KEYS)))
  end

  def error_messages(error)
    return error.record.errors.full_messages if error.respond_to?(:record)

    [ error.message ]
  end
end
