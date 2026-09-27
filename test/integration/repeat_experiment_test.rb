require "test_helper"
require_relative "../support/workflow_profile_test_helper"
require_relative "../support/methodology_profile_test_helper"
require_relative "../support/translation_reference_test_helper"

class RepeatExperimentTest < ActionDispatch::IntegrationTest
  include ActiveJob::TestHelper
  include WorkflowProfileTestHelper
  include MethodologyProfileTestHelper
  include TranslationReferenceTestHelper

  setup do
    sign_in_as users(:normal)
    @project = users(:normal).projects.create!(
      name: "Reusable project",
      source_language: "Vietnamese",
      target_language: "Japanese"
    )
    document = @project.documents.create!(title: "Original source", source_text: "Xin chào")
    @historical = document.experiments.create!(
      name: "Original experiment",
      instruction_prompt: "Translate faithfully.",
      guidance_preference: :reference_examples,
      status: :completed
    )
    @historical.translation_runs.create!(
      llm_model: llm_models(:openrouter_claude),
      status: :completed,
      translated_text: "Hello",
      completed_at: Time.current
    )
  end

  test "GET prefills a new reviewed launch and POST creates new identities with explicit paid work" do
    assert_no_difference [ -> { Experiment.count }, -> { enqueued_jobs.size } ] do
      get repeat_experiment_path(@historical)
    end
    assert_response :success
    assert_select "input[name='translation_workspace[submission_token]']", count: 1
    assert_select "textarea[name='translation_workspace[source_text]']", text: "Xin chào"
    assert_select "[data-model-card][data-identifier='#{llm_models(:openrouter_claude).model_identifier}'] input[type='hidden'][name='translation_workspace[model_ids][]'][value='#{llm_models(:openrouter_claude).id}']"
    token = css_select("input[name='translation_workspace[submission_token]']").first["value"]

    assert_difference -> { Experiment.count }, 1 do
      assert_enqueued_jobs 1, only: TranslationRunJob do
        post translation_workspace_path, params: {
          translation_workspace: {
            submission_token: token,
            project_id: @project.id,
            document_title: "Original source",
            source_text: "Xin chào",
            experiment_name: "Repeat of Original experiment",
            instruction_prompt: "Translate faithfully.",
            guidance_preference: "reference_examples",
            workflow_mode: "manual",
            model_ids: [ llm_models(:openrouter_claude).id ]
          }
        }
      end
    end

    repeated = Experiment.order(:id).last
    assert_not_equal @historical.id, repeated.id
    assert_equal @historical.instruction_prompt, repeated.instruction_prompt
    assert_equal "Original experiment", @historical.reload.name
  end

  test "repeat is owner scoped" do
    other = experiments(:two)
    get repeat_experiment_path(other)
    assert_response :not_found
  end

  test "long automatic history with unavailable capabilities falls back to a usable manual prefill" do
    @historical.document.update!(source_text: "Long paragraph。\n\n" * 500)
    @historical.translation_runs.create!(
      llm_model: llm_models(:openrouter_gpt),
      status: :completed,
      translated_text: "Second translation",
      completed_at: Time.current
    )
    profile = create_workflow_profile
    create_pipeline_run(experiment: @historical, profile: profile)

    assert_no_enqueued_jobs do
      get repeat_experiment_path(@historical)
    end

    assert_response :success
    assert_select "[role='status']", text: /no longer has the model capability data/
    assert_select "input[name='translation_workspace[workflow_mode]'][value='manual'][checked]"
    assert_select "input[name='translation_workspace[workflow_profile_revision_id]'][checked]", count: 0
    assert_select "#workspace-manual-models [data-model-card] input[type='hidden'][name='translation_workspace[model_ids][]']", count: 2
  end

  test "repeat keeps selected current configurations outside bounded newest collections and can submit them" do
    selected_profile = create_workflow_profile(name: "Selected older workflow")
    selected_glossary = create_glossary(name: "Selected older glossary")
    selected_methodology = create_methodology_profile(name: "Selected older methodology")
    selected_reference = create_translation_reference(title: "Selected older reference")
    historical = configured_historical_experiment(
      profile: selected_profile,
      glossary: selected_glossary,
      methodology: selected_methodology,
      reference: selected_reference
    )

    TranslationWorkspacesController::CONFIGURATION_OPTION_LIMIT.times do |index|
      create_workflow_profile(name: "Newer workflow #{index}")
      create_glossary(name: "Newer glossary #{index}")
      create_methodology_profile(name: "Newer methodology #{index}")
      create_translation_reference(title: "Newer reference #{index}")
    end

    {
      workflow_profile_page: [ "Workflow profiles", "translation_workspace[workflow_profile_revision_id]", selected_profile.current_revision_id ],
      glossary_page: [ "Glossaries", "translation_workspace[glossary_revision_id]", selected_glossary.current_revision_id ],
      methodology_profile_page: [ "Methodology profiles", "translation_workspace[methodology_profile_revision_id]", selected_methodology.current_revision_id ],
      translation_reference_page: [ "Translation references", "translation_workspace[translation_reference_revision_ids][]", selected_reference.current_revision_id ]
    }.each do |page_param, (label, input_name, revision_id)|
      get new_translation_workspace_path(page_param => 2)
      assert_response :success
      assert_select "nav[aria-label='#{label} pagination']", text: /Page 2 of 2/
      assert_select "input[name='#{input_name}'][value='#{revision_id}']", count: 1
    end

    get new_translation_workspace_path
    assert_select "button[formaction='#{translation_workspace_options_path}'][formmethod='post'][name='workflow_profile_page'][value='2'][formnovalidate]", count: 1

    preserved_token = css_select("input[name='translation_workspace[submission_token]']").first["value"]
    assert_no_difference [ -> { Experiment.count }, -> { enqueued_jobs.size } ] do
      post translation_workspace_options_path, params: {
        workflow_profile_page: "2",
        translation_workspace: {
          submission_token: preserved_token,
          project_id: @project.id.to_s,
          document_title: "Preserved while paging",
          source_text: "Preserved source",
          experiment_name: "Preserved experiment",
          instruction_prompt: "Preserved instruction",
          glossary_revision_id: selected_glossary.current_revision_id.to_s,
          methodology_profile_revision_id: selected_methodology.current_revision_id.to_s,
          translation_reference_revision_ids: [ selected_reference.current_revision_id.to_s ],
          guidance_preference: "reference_examples",
          workflow_mode: "automatic",
          workflow_profile_revision_id: selected_profile.current_revision_id.to_s,
          automatic_confirmation: "1",
          automatic_plan_digest: "0" * 64
        }
      }
    end
    assert_response :success
    assert_select "textarea[name='translation_workspace[source_text]']", text: "Preserved source"
    assert_select "input[name='translation_workspace[workflow_profile_revision_id]'][value='#{selected_profile.current_revision_id}'][checked]", count: 1
    assert_select "input[name='translation_workspace[glossary_revision_id]'][value='#{selected_glossary.current_revision_id}'][checked]", count: 1
    assert_select "input[name='translation_workspace[methodology_profile_revision_id]'][value='#{selected_methodology.current_revision_id}'][checked]", count: 1
    assert_select "input[name='translation_workspace[translation_reference_revision_ids][]'][value='#{selected_reference.current_revision_id}'][checked]", count: 1
    assert_select "h3", text: "Paid-work authorization"
    assert_select "input[name='translation_workspace[automatic_confirmation]'][type='checkbox']:not([checked])", count: 1
    rebuilt_digest = css_select("input[name='translation_workspace[automatic_plan_digest]']").sole["value"]
    assert_match(/\A\h{64}\z/, rebuilt_digest)
    assert_not_equal "0" * 64, rebuilt_digest

    get repeat_experiment_path(historical)

    assert_response :success
    selected_ids = {
      "workflow_profile_revision_id" => selected_profile.current_revision_id,
      "glossary_revision_id" => selected_glossary.current_revision_id,
      "methodology_profile_revision_id" => selected_methodology.current_revision_id
    }
    selected_ids.each do |name, id|
      assert_select "input[name='translation_workspace[#{name}]'][value='#{id}'][checked]", count: 1
      assert_operator css_select("input[name='translation_workspace[#{name}]']").size,
                      :<=, TranslationWorkspacesController::CONFIGURATION_OPTION_LIMIT + 2
    end
    assert_select "input[name='translation_workspace[translation_reference_revision_ids][]'][value='#{selected_reference.current_revision_id}'][checked]", count: 1
    assert_operator css_select("input[name='translation_workspace[translation_reference_revision_ids][]']").size,
                    :<=, TranslationWorkspacesController::CONFIGURATION_OPTION_LIMIT +
                      ExperimentReferenceRevision::MAXIMUM_REFERENCES

    token = css_select("input[name='translation_workspace[submission_token]']").first["value"]
    plan_digest = css_select("input[name='translation_workspace[automatic_plan_digest]']").first["value"]
    assert_difference -> { Experiment.count }, 1 do
      post translation_workspace_path, params: {
        translation_workspace: {
          submission_token: token,
          project_id: @project.id,
          document_title: historical.document.title,
          source_text: historical.document.source_text,
          experiment_name: "Repeated bounded configuration",
          instruction_prompt: historical.instruction_prompt,
          glossary_revision_id: selected_glossary.current_revision_id,
          methodology_profile_revision_id: selected_methodology.current_revision_id,
          translation_reference_revision_ids: [ selected_reference.current_revision_id.to_s ],
          guidance_preference: historical.guidance_preference,
          workflow_mode: "automatic",
          workflow_profile_revision_id: selected_profile.current_revision_id,
          automatic_confirmation: "1",
          automatic_plan_digest: plan_digest
        }
      }
    end

    repeated = Experiment.order(:id).last
    assert_response :redirect
    assert_equal selected_glossary.current_revision_id, repeated.glossary_revision_id
    assert_equal selected_methodology.current_revision_id, repeated.methodology_profile_revision_id
    assert_equal [ selected_reference.current_revision_id ], repeated.translation_reference_revision_ids
    assert_equal selected_profile.current_revision_id, repeated.pipeline_run.workflow_profile_revision_id
  end

  test "submitted cross-owner configurations are not injected into bounded options" do
    foreign_profile = create_workflow_profile(user: users(:other), name: "Foreign workflow")
    foreign_glossary = create_glossary(user: users(:other), name: "Foreign glossary")
    foreign_methodology = create_methodology_profile(user: users(:other), name: "Foreign methodology")
    foreign_reference = create_translation_reference(user: users(:other), title: "Foreign reference")

    assert_no_difference -> { Experiment.count } do
      post translation_workspace_path, params: {
        translation_workspace: {
          submission_token: issue_translation_workspace_token,
          project_id: @project.id,
          document_title: "Tampered selection",
          source_text: "Source",
          experiment_name: "Tampered selection",
          instruction_prompt: "Translate faithfully.",
          glossary_revision_id: foreign_glossary.current_revision_id,
          methodology_profile_revision_id: foreign_methodology.current_revision_id,
          translation_reference_revision_ids: [ foreign_reference.current_revision_id.to_s ],
          guidance_preference: "reference_examples",
          workflow_mode: "automatic",
          workflow_profile_revision_id: foreign_profile.current_revision_id,
          automatic_confirmation: "1",
          automatic_plan_digest: "0" * 64
        }
      }
    end

    assert_response :unprocessable_content
    [
      [ "workflow_profile_revision_id", foreign_profile.current_revision_id ],
      [ "glossary_revision_id", foreign_glossary.current_revision_id ],
      [ "methodology_profile_revision_id", foreign_methodology.current_revision_id ]
    ].each do |name, id|
      assert_select "input[name='translation_workspace[#{name}]'][value='#{id}']", count: 0
    end
    assert_select "input[name='translation_workspace[translation_reference_revision_ids][]'][value='#{foreign_reference.current_revision_id}']", count: 0
  end

  private

  def create_glossary(user: users(:normal), name:)
    Glossaries::Create.call(
      user: user,
      attributes: {
        name: name,
        description: "Bounded selection regression",
        source_language: "Vietnamese",
        target_language: "Japanese",
        entries: [ { source_term: "faith", preferred_target_term: "信仰", note: "Keep exact" } ]
      }
    )
  end

  def configured_historical_experiment(profile:, glossary:, methodology:, reference:)
    document = @project.documents.create!(title: "Configured historical source", source_text: "Xin chào")
    experiment = document.experiments.create!(
      name: "Configured historical experiment",
      instruction_prompt: "Translate faithfully.",
      glossary_revision: glossary.current_revision,
      methodology_profile_revision: methodology.current_revision,
      guidance_preference: :reference_examples,
      status: :completed
    )
    experiment.experiment_reference_revisions.create!(
      translation_reference_revision: reference.current_revision,
      position: 1
    )
    profile.current_revision.selections_for("translator").each do |selection|
      experiment.translation_runs.create!(
        llm_model: selection.llm_model,
        status: :completed,
        translated_text: "Translated",
        completed_at: Time.current
      )
    end
    create_pipeline_run(experiment: experiment, profile: profile)
    experiment
  end
end
