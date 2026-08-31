class MethodologyProfilesController < ApplicationController
  SCALAR_KEYS = %w[name description source_language target_language guidance expected_version].freeze

  before_action :set_methodology_profile, only: %i[show edit update activate deactivate]

  def index
    @methodology_profiles = current_user.methodology_profiles.includes(:current_revision)
      .order(active: :desc, updated_at: :desc, id: :desc)
  end

  def new
    @form_values = {}
  end

  def create
    profile = MethodologyProfiles::Create.call(
      user: current_user,
      attributes: exact_profile_parameters!(include_expected_version: false)
    )
    redirect_to profile, notice: "Methodology profile created."
  rescue ActiveRecord::RecordInvalid => error
    @form_values = safe_submitted_values
    @form_errors = error.record.errors.full_messages
    render :new, status: :unprocessable_content
  end

  def show
    @methodology_profile = current_user.methodology_profiles.includes(revisions: :experiments)
      .find(@methodology_profile.id)
  end

  def edit
    @form_values = revision_form_values(@methodology_profile.current_revision)
  end

  def update
    attributes = exact_profile_parameters!(include_expected_version: true)
    revision = MethodologyProfiles::Revise.call(
      methodology_profile: @methodology_profile,
      expected_version: attributes.delete("expected_version"),
      attributes: attributes
    )
    redirect_to @methodology_profile, notice: "Methodology revision #{revision.version} created."
  rescue MethodologyProfiles::Revise::StaleRevisionError => error
    @form_values = safe_submitted_values
    @form_errors = [ error.message ]
    render :edit, status: :conflict
  rescue ActiveRecord::RecordInvalid => error
    @form_values = safe_submitted_values
    @form_errors = error.record.errors.full_messages
    render :edit, status: :unprocessable_content
  end

  def activate
    reject_unexpected_parameters!
    MethodologyProfiles::ChangeStatus.activate(methodology_profile: @methodology_profile)
    redirect_to @methodology_profile, notice: "Methodology profile activated."
  end

  def deactivate
    reject_unexpected_parameters!
    MethodologyProfiles::ChangeStatus.deactivate(methodology_profile: @methodology_profile)
    redirect_to @methodology_profile, notice: "Methodology profile archived. Historical revisions remain available."
  end

  private

  def set_methodology_profile
    @methodology_profile = current_user.methodology_profiles.includes(:current_revision).find(params[:id])
  end

  def exact_profile_parameters!(include_expected_version:)
    submitted = params.require(:methodology_profile)
    unless submitted.is_a?(ActionController::Parameters)
      raise ActionController::BadRequest, "methodology_profile must be an object"
    end

    scalar_keys = include_expected_version ? SCALAR_KEYS : SCALAR_KEYS - [ "expected_version" ]
    raise ActionController::BadRequest, "Unexpected parameters" if (submitted.keys - scalar_keys).any?
    scalar_keys.each do |key|
      value = submitted[key]
      raise ActionController::BadRequest, "#{key} must be a scalar" unless value.nil? || value.is_a?(String)
    end

    submitted.permit(*scalar_keys).to_h
  end

  def reject_unexpected_parameters!
    submitted = params[:methodology_profile]
    return if submitted.nil? || (submitted.is_a?(ActionController::Parameters) && submitted.empty?)

    raise ActionController::BadRequest, "Unexpected parameters"
  end

  def revision_form_values(revision)
    revision.slice("name", "description", "source_language", "target_language", "guidance")
      .merge("expected_version" => revision.version.to_s)
  end

  def safe_submitted_values
    submitted = params[:methodology_profile]
    return {} unless submitted.is_a?(ActionController::Parameters)

    submitted.to_unsafe_h.slice(*SCALAR_KEYS)
  end
end
