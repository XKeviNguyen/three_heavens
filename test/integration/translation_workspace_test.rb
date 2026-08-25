require "test_helper"

class TranslationWorkspaceTest < ActionDispatch::IntegrationTest
  include ActiveJob::TestHelper

  setup do
    @first_model = llm_models(:openrouter_claude)
    @second_model = llm_models(:openrouter_gpt)
  end

  test "workspace is the application root and lists only active OpenRouter models" do
    inactive_model = LlmModel.create!(
      gateway: "openrouter",
      provider: "anthropic",
      model_identifier: "anthropic/inactive-browser-test",
      display_name: "Inactive browser model",
      active: false
    )
    other_gateway_model = LlmModel.create!(
      gateway: "direct",
      provider: "anthropic",
      model_identifier: "anthropic/direct-browser-test",
      display_name: "Direct browser model",
      active: true
    )

    get root_path

    assert_response :success
    assert_select "h1", "Start a translation experiment"
    assert_select "form[action='#{translation_workspace_path}']"
    assert_select "input[type='checkbox'][value='#{@first_model.id}']"
    assert_select "input[type='checkbox'][value='#{@second_model.id}']"
    assert_select "input[type='checkbox'][value='#{inactive_model.id}']", count: 0
    assert_select "input[type='checkbox'][value='#{other_gateway_model.id}']", count: 0
  end

  test "valid submission creates the workspace and starts multiple model runs" do
    assert_difference -> { Project.count }, 1 do
      assert_difference -> { Document.count }, 1 do
        assert_difference -> { Experiment.count }, 1 do
          assert_difference -> { TranslationRun.count }, 2 do
            assert_enqueued_jobs 2, only: TranslationRunJob do
              post translation_workspace_path,
                   params: { translation_workspace: valid_attributes }
            end
          end
        end
      end
    end

    experiment = Experiment.order(:id).last
    project = experiment.document.project

    assert_redirected_to experiment_path(experiment)
    assert experiment.running?
    assert_equal "Translation comparison", experiment.name
    assert_equal "Faith and Hope", experiment.document.title
    assert_equal "A source passage", experiment.document.source_text
    assert_equal "Vietnamese Sermons", project.name
    assert_equal "Vietnamese", project.source_language
    assert_equal "Japanese", project.target_language
    assert_equal [ @first_model.id, @second_model.id ].sort,
                 experiment.translation_runs.pluck(:llm_model_id).sort
  end

  test "submission without a model renders a useful error and creates nothing" do
    assert_no_workspace_records_created do
      post translation_workspace_path,
           params: {
             translation_workspace: valid_attributes.except(:model_ids)
           }
    end

    assert_response :unprocessable_content
    assert_select "li", text: /Model.*select at least one active OpenRouter model/
    assert_select "input[name='translation_workspace[project_name]'][value='Vietnamese Sermons']"
  end

  test "inactive and non-OpenRouter model IDs are rejected server-side" do
    inactive_model = LlmModel.create!(
      gateway: "openrouter",
      provider: "anthropic",
      model_identifier: "anthropic/inactive-tamper-test",
      display_name: "Inactive tamper model",
      active: false
    )
    other_gateway_model = LlmModel.create!(
      gateway: "direct",
      provider: "anthropic",
      model_identifier: "anthropic/direct-tamper-test",
      display_name: "Direct tamper model",
      active: true
    )

    [ inactive_model.id, other_gateway_model.id, "not-an-id" ].each do |tampered_id|
      assert_no_workspace_records_created do
        post translation_workspace_path,
             params: {
               translation_workspace: valid_attributes.merge(
                 model_ids: [ @first_model.id, tampered_id ]
               )
             }
      end

      assert_response :unprocessable_content
      assert_select "li", text: /Model.*invalid|Model.*inactive or unsupported/
    end
  end

  test "invalid project document and experiment data creates no partial records" do
    assert_no_workspace_records_created do
      post translation_workspace_path,
           params: {
             translation_workspace: valid_attributes.merge(
               project_name: "",
               source_language: "",
               target_language: "",
               document_title: "",
               source_text: "",
               experiment_name: "x" * 151,
               instruction_prompt: ""
             )
           }
    end

    assert_response :unprocessable_content
    assert_select "li", minimum: 7
    assert_select "li", text: /Project name.*blank/
    assert_select "li", text: /Source text.*blank/
    assert_select "li", text: /Experiment name.*too long/
    assert_select "li", text: /Instruction prompt.*blank/
  end

  test "an orchestration failure rolls back every workspace record" do
    failing_start_service = Class.new do
      def self.call(**)
        raise TranslationExperiments::Start::InvalidExperimentStateError
      end
    end
    workspace = TranslationWorkspace.new(
      valid_attributes,
      start_service: failing_start_service
    )

    assert_no_workspace_records_created do
      assert_not workspace.submit
    end

    assert_includes workspace.errors[:base].join, "could not be started"
  end

  test "an unexpected Active Record error propagates and rolls back every workspace record" do
    failing_start_service = Class.new do
      def self.call(**)
        raise ActiveRecord::StatementInvalid, "simulated SQL failure"
      end
    end
    workspace = TranslationWorkspace.new(
      valid_attributes,
      start_service: failing_start_service
    )
    counts_before = workspace_record_counts

    error = assert_raises ActiveRecord::StatementInvalid do
      workspace.submit
    end

    assert_equal "simulated SQL failure", error.message
    assert_equal counts_before, workspace_record_counts
    assert_empty workspace.errors[:base]
  end

  test "an unexpected ArgumentError propagates and rolls back every workspace record" do
    failing_start_service = Class.new do
      def self.call(**)
        raise ArgumentError, "simulated programming error"
      end
    end
    workspace = TranslationWorkspace.new(
      valid_attributes,
      start_service: failing_start_service
    )
    counts_before = workspace_record_counts

    error = assert_raises ArgumentError do
      workspace.submit
    end

    assert_equal "simulated programming error", error.message
    assert_equal counts_before, workspace_record_counts
    assert_empty workspace.errors[:base]
  end

  test "pending experiment page explains status and refreshes automatically" do
    experiment = experiments(:one)

    get experiment_path(experiment)

    assert_response :success
    assert_select "h1", experiment.name
    assert_select "meta[http-equiv='refresh'][content='5']", count: 1
    assert_select "[role='status']", text: /refreshes automatically every 5 seconds/
    assert_select "article", minimum: 1
    assert_select "article", text: /queued and waiting to start/
  end

  test "completed experiment page renders results model identifiers and telemetry" do
    experiment = experiments(:two)
    run = translation_runs(:two)
    run.update!(
      translated_text: "Translated result\nSecond line",
      resolved_model_identifier: "openai/gpt-resolved",
      prompt_tokens: 120,
      completion_tokens: 45,
      total_tokens: 165,
      cost: BigDecimal("0.0012345678")
    )

    get experiment_path(experiment)

    assert_response :success
    assert_select "meta[http-equiv='refresh']", count: 0
    assert_select "article", text: /#{Regexp.escape(run.llm_model.display_name)}/
    assert_select "article", text: /#{Regexp.escape(run.llm_model.model_identifier)}/
    assert_select "article", text: /openai\/gpt-resolved/
    assert_select "article", text: /Translated result.*Second line/m
    assert_select "article", text: /Prompt tokens.*120/m
    assert_select "article", text: /Completion tokens.*45/m
    assert_select "article", text: /Total tokens.*165/m
    assert_select "article", text: /Cost.*\$0\.0012345678/m
  end

  test "failed experiment page escapes provider text and redacts bearer credentials" do
    experiment = experiments(:one)
    experiment.update!(status: :failed)
    run = translation_runs(:one)
    run.update!(
      status: :failed,
      error_code: "provider_error",
      error_message: "Bearer provider-secret <script>alert('unsafe')</script>"
    )

    get experiment_path(experiment)

    assert_response :success
    assert_select "meta[http-equiv='refresh']", count: 0
    assert_select "article", text: /Translation failed/
    assert_select "article", text: /provider_error/
    assert_includes response.body, "[FILTERED]"
    assert_includes response.body, "&lt;script&gt;alert"
    assert_not_includes response.body, "provider-secret"
    assert_not_includes response.body, "<script>alert('unsafe')</script>"
  end

  private

  def assert_no_workspace_records_created
    counts_before = workspace_record_counts

    yield

    assert_equal counts_before, workspace_record_counts
  end

  def workspace_record_counts
    [
      Project.count,
      Document.count,
      Experiment.count,
      TranslationRun.count
    ]
  end

  def valid_attributes
    {
      project_name: "Vietnamese Sermons",
      source_language: "Vietnamese",
      target_language: "Japanese",
      document_title: "Faith and Hope",
      source_text: "A source passage",
      experiment_name: "Translation comparison",
      instruction_prompt: "Translate faithfully and preserve paragraph breaks.",
      model_ids: [ @first_model.id, @second_model.id ]
    }
  end
end
