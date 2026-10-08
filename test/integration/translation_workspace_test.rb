require "test_helper"

class TranslationWorkspaceTest < ActionDispatch::IntegrationTest
  include ActiveJob::TestHelper

  class RecordingQueueAdapter
    attr_reader :job_ids, :transaction_depths

    def initialize(failure: nil)
      @failure = failure
      @job_ids = []
      @transaction_depths = []
    end

    def enqueue(job)
      record(job)
      raise failure if failure
    end

    def enqueue_at(job, _timestamp)
      enqueue(job)
    end

    private

    attr_reader :failure

    def record(job)
      job_ids << job.job_id
      transaction_depths << ActiveRecord::Base.connection.open_transactions
    end
  end

  setup do
    sign_in_as users(:normal)
    @first_model = llm_models(:openrouter_claude)
    @second_model = llm_models(:openrouter_gpt)
  end

  test "workspace is the application root and uses the trusted OpenRouter catalog browser" do
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

    get new_translation_workspace_path

    assert_response :success
    assert_select "h1", "New translation"
    assert_select "form[action='#{translation_workspace_path}']"
    assert_select "[data-controller='model-browser'][data-model-browser-endpoint-value='#{open_router_catalog_path}']"
    assert_select "input[type='checkbox'][value='#{@first_model.id}']", count: 0
    assert_select "input[type='checkbox'][value='#{@second_model.id}']", count: 0
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

  test "outer transaction catches actual expected enqueue failure after commit" do
    queue_error = SolidQueue::Job::EnqueueError.new("private queue detail")
    adapter = RecordingQueueAdapter.new(failure: queue_error)
    workspace = TranslationWorkspace.new(
      valid_attributes.merge(model_ids: [ @first_model.id ])
    )
    baseline_transaction_depth = ActiveRecord::Base.connection.open_transactions
    provider_factory_calls = 0

    with_translation_job_boundaries(
      adapter: adapter,
      client_factory: -> { provider_factory_calls += 1 }
    ) do
      assert workspace.submit
    end

    experiment = workspace.experiment.reload
    run = experiment.translation_runs.sole.reload
    assert_equal [ baseline_transaction_depth ], adapter.transaction_depths
    assert_equal [ run.scheduled_job_id ], adapter.job_ids
    assert run.failed?
    assert_equal "enqueue_failed", run.error_code
    assert_equal Ai::RunScheduler::ERROR_MESSAGE, run.error_message
    assert_not_includes run.error_message, "private queue detail"
    assert experiment.failed?
    assert_equal 0, provider_factory_calls

    replay = TranslationWorkspace.new(valid_attributes.merge(submission_token: workspace.submission_token))
    with_translation_job_boundaries(adapter: adapter, client_factory: -> { provider_factory_calls += 1 }) do
      assert replay.submit
    end
    assert replay.replayed?
    assert_equal experiment, replay.experiment
    assert_equal 1, adapter.job_ids.size
  end

  test "outer transaction performs successful enqueue only after commit" do
    adapter = RecordingQueueAdapter.new
    workspace = TranslationWorkspace.new(
      valid_attributes.merge(model_ids: [ @first_model.id ])
    )
    baseline_transaction_depth = ActiveRecord::Base.connection.open_transactions
    provider_factory_calls = 0

    with_translation_job_boundaries(
      adapter: adapter,
      client_factory: -> { provider_factory_calls += 1 }
    ) do
      assert workspace.submit
    end

    experiment = workspace.experiment.reload
    run = experiment.translation_runs.sole.reload
    assert_equal [ baseline_transaction_depth ], adapter.transaction_depths
    assert_equal [ run.scheduled_job_id ], adapter.job_ids
    assert run.pending?
    assert run.pending_since
    assert experiment.running?
    assert_equal 0, provider_factory_calls
  end

  test "submission without a model renders a useful error and creates nothing" do
    assert_no_workspace_records_created do
      post translation_workspace_path,
           params: {
             translation_workspace: valid_attributes.except(:model_ids)
           }
    end

    assert_response :unprocessable_content
    assert_select "li", text: /AI models must include at least one available model/
    assert_select "input[name='translation_workspace[project_name]'][value='Vietnamese Sermons']"
  end

  test "workspace validation errors are written in the interface language" do
    {
      "ja" => [ "プロジェクト名を入力してください", "AIモデルを1つ以上選んでください" ],
      "vi" => [ "Tên dự án không được để trống", "Mô hình AI cần có ít nhất một mô hình khả dụng" ]
    }.each do |locale, messages|
      users(:normal).update!(locale: locale)

      assert_no_workspace_records_created do
        post translation_workspace_path,
             params: { translation_workspace: valid_attributes.merge(project_name: "", model_ids: []) }
      end

      assert_response :unprocessable_content
      section = css_select("section[aria-labelledby='form-errors-heading']").first
      messages.each { |message| assert_includes section.text, message, locale }
      assert_no_match(/must include|can't be blank|model_ids|revision/i, section.text, locale)
    end
  end

  test "workspace validation errors link to the section that needs correction" do
    assert_no_workspace_records_created do
      post translation_workspace_path,
           params: {
             translation_workspace: valid_attributes.merge(
               project_name: "",
               source_text: "",
               model_ids: [],
               glossary_revision_id: "999999999",
               translation_reference_revision_ids: [ "999999999" ]
             )
           }
    end

    assert_response :unprocessable_content
    assert_select "form#workspace-form"
    assert_select "section[aria-labelledby='form-errors-heading']" do
      assert_select "a[href='#workspace-project']", text: /Project name.*blank/
      assert_select "a[href='#workspace-source']", text: /Source text.*blank/
      assert_select "a[href='#workspace-manual-models']", text: /AI models must include at least one available model/
      assert_select "a[href='#workspace-glossary']", text: /Glossary is no longer available/
      assert_select "a[href='#workspace-references']", text: /reference that is no longer available/
    end

    assert_select "section#workspace-project"
    assert_select "section#workspace-source"
    assert_select "fieldset#workspace-manual-models"
    assert_select "fieldset#workspace-glossary"
    assert_select "fieldset#workspace-references"
  end

  test "malformed workspace and model ID parameter shapes are rejected without side effects" do
    payloads = [
      {},
      { translation_workspace: "malformed" },
      { translation_workspace: [ "malformed" ] },
      { translation_workspace: valid_attributes.merge(model_ids: "1") },
      { translation_workspace: valid_attributes.merge(model_ids: { nested: "1" }) }
    ]

    payloads.each_with_index do |payload, index|
      assert_no_workspace_records_created do
        assert_no_enqueued_jobs only: TranslationRunJob do
          post translation_workspace_path, params: payload
        end
      end
      assert_response :bad_request, "malformed payload #{index} was not rejected at the parameter boundary"
      assert_empty response.body
    end
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
      assert_select "li", text: /AI models (is invalid|include a model that is no longer available)/
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
    assert_select "li", text: /Translation name.*too long/
    assert_select "li", text: /Instructions.*blank/
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
    submission = translation_workspace_submission_for(workspace.submission_token)
    assert submission.available?

    retry_workspace = TranslationWorkspace.new(valid_attributes.merge(submission_token: workspace.submission_token))
    assert_enqueued_jobs 2, only: TranslationRunJob do
      assert retry_workspace.submit
    end
    assert submission.reload.consumed?
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
    assert_select "article", text: /Waiting to start/
  end

  test "completed experiment page renders results model identifiers and telemetry" do
    experiment = experiments(:one)
    experiment.update!(status: :completed)
    run = translation_runs(:one)
    run.update!(
      status: :completed,
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
    assert_select "article", text: /Input tokens.*120/m
    assert_select "article", text: /Output tokens.*45/m
    assert_select "article", text: /Total tokens.*165/m
    assert_select "article", text: /Cost.*\$0\.0012345678/m
  end

  test "failed experiment page escapes provider text and redacts bearer credentials" do
    experiment = experiments(:one)
    experiment.update!(status: :failed)
    run = translation_runs(:one)
    run.update!(
      status: :failed,
      error_code: "PRIVATE_PROVIDER_ERROR_CODE",
      error_message: "Bearer provider-secret <script>alert('unsafe')</script>"
    )

    get experiment_path(experiment)

    assert_response :success
    assert_select "meta[http-equiv='refresh']", count: 0
    assert_select "article", text: /Translation failed/
    assert_select "article", text: /provider_failure/
    assert_includes response.body, "The AI request failed."
    assert_not_includes response.body, "PRIVATE_PROVIDER_ERROR_CODE"
    assert_not_includes response.body, "&lt;script&gt;alert"
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
      user: users(:normal),
      project_name: "Vietnamese Sermons",
      source_language: "Vietnamese",
      target_language: "Japanese",
      document_title: "Faith and Hope",
      source_text: "A source passage",
      experiment_name: "Translation comparison",
      instruction_prompt: "Translate faithfully and preserve paragraph breaks.",
      model_ids: [ @first_model.id, @second_model.id ],
      submission_token: issue_translation_workspace_token
    }
  end

  def with_translation_job_boundaries(adapter:, client_factory:)
    original_adapter = TranslationRunJob.queue_adapter
    original_client_factory = TranslationRunJob.client_factory
    TranslationRunJob.queue_adapter = adapter
    TranslationRunJob.client_factory = client_factory
    yield
  ensure
    TranslationRunJob.queue_adapter = original_adapter
    TranslationRunJob.client_factory = original_client_factory
  end
end
