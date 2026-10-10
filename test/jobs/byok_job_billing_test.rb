require "test_helper"
require_relative "../support/final_translation_test_helper"
require_relative "../support/authorized_ai_job_helper"

# Every whole-document provider job resolves its OpenRouter key only from the
# payment authorization stamped on the run, inside the claim, and never falls
# back to another source. (Segment jobs: test/services/long_documents/segmented_workflow_test.rb.)
class ByokJobBillingTest < ActiveSupport::TestCase
  include ActiveJob::TestHelper
  include FinalTranslationTestHelper
  include AuthorizedAiJobHelper

  PERSONAL_KEY = "sk-or-v1-#{"a1" * 32}".freeze
  REPLACEMENT_KEY = "sk-or-v1-#{"b2" * 32}".freeze
  PLATFORM_KEY = "sk-or-v1-platform-test-key-value".freeze
  JOBS = {
    TranslationRun => TranslationRunJob,
    ReviewRun => ReviewRunJob,
    JudgeRun => JudgeRunJob,
    FinalizationRun => FinalizationRunJob
  }.freeze

  # Records the key it was built with, then fails like an out-of-credit key.
  class RecordingClient
    def initialize(log, credential, error_code: "http_402", retryable: false)
      @log = log
      @credential = credential
      @error_code = error_code
      @retryable = retryable
    end

    %i[chat_completion review_completion judge_completion finalization_completion].each do |name|
      define_method(name) do |**|
        @log << [ @credential.billing_source, @credential.api_key ]
        error_class = @retryable ? Ai::OpenRouterClient::RetryableError : Ai::OpenRouterClient::PermanentError
        raise error_class.new("OpenRouter request failed (HTTP 402)", code: @error_code)
      end
    end
  end

  setup do
    @current_test_user = users(:normal)
    @calls = []
    @original_factories = JOBS.values.to_h { |job| [ job, job.client_factory ] }
    JOBS.each_value { |job| job.client_factory = ->(credential) { RecordingClient.new(@calls, credential) } }
    @original_platform_key = ENV["OPENROUTER_API_KEY"]
    ENV["OPENROUTER_API_KEY"] = PLATFORM_KEY
    clear_enqueued_jobs
  end

  teardown do
    @original_factories.each { |job, factory| job.client_factory = factory }
    @original_platform_key ? ENV["OPENROUTER_API_KEY"] = @original_platform_key : ENV.delete("OPENROUTER_API_KEY")
  end

  test "every job type bills a personal key with managed access disabled and never falls back on failure" do
    runs = build_runs
    credential = use_personal_key
    @current_test_user.update!(managed_ai_access: false)

    runs.each do |run|
      @calls.clear
      schedule!(run)
      assert_equal "personal", run.reload.billing_source
      assert_equal credential.id, run.open_router_credential_id

      perform_authorized_ai_job(JOBS.fetch(run.class), run)

      assert_equal [ [ "personal", PERSONAL_KEY ] ], @calls, "#{run.class.name} used only the personal key"
      assert run.reload.failed?
      assert_equal "http_402", run.error_code
      attempts = run.provider_attempts.to_a
      assert_equal 1, attempts.size, "#{run.class.name} made no second attempt on another key"
      assert_equal [ "personal", credential.id ], [ attempts.first.billing_source, attempts.first.open_router_credential_id ]
    end
  end

  test "every job type bills the platform key under managed authorization" do
    build_runs.each do |run|
      @calls.clear
      schedule!(run)
      perform_authorized_ai_job(JOBS.fetch(run.class), run)

      assert_equal [ [ "managed", PLATFORM_KEY ] ], @calls
      assert_equal "managed", run.reload.provider_attempts.sole.billing_source
      assert_nil run.provider_attempts.sole.open_router_credential_id
    end
  end

  test "scheduled personal work keeps its payer when the owner later selects managed" do
    run = build_runs.first
    use_personal_key
    schedule!(run)
    @current_test_user.update!(ai_payment_source: "managed")

    perform_authorized_ai_job(TranslationRunJob, run)

    assert_equal [ [ "personal", PERSONAL_KEY ] ], @calls
  end

  test "scheduled managed work keeps its payer and fails closed when managed access is withdrawn" do
    run = build_runs.first
    schedule!(run)
    use_personal_key
    @current_test_user.update!(managed_ai_access: false)

    assert_no_difference "AiProviderAttempt.count" do
      perform_authorized_ai_job(TranslationRunJob, run)
    end

    assert_empty @calls
    assert_equal "managed_ai_access_revoked", run.reload.error_code
  end

  test "a key replaced or deleted before the claim fails every job type closed" do
    %w[replace delete].each do |change|
      build_runs.each do |run|
        use_personal_key
        schedule!(run)
        if change == "replace"
          Accounts::AiSettings.store_key!(@current_test_user, api_key: REPLACEMENT_KEY, state_token: state_token)
        else
          Accounts::AiSettings.delete_key!(@current_test_user, state_token: state_token)
        end

        assert_no_difference "AiProviderAttempt.count" do
          perform_authorized_ai_job(JOBS.fetch(run.class), run)
        end
        assert_empty @calls, "#{run.class.name} sent no request after #{change}"
        assert run.reload.failed?
        assert_equal "personal_key_unavailable", run.error_code
        reset_key!
      end
    end
  end

  test "a provider retry re-checks the key and stops when it was deleted after the first attempt" do
    run = build_runs.first
    use_personal_key
    schedule!(run)
    TranslationRunJob.client_factory = ->(credential) { RecordingClient.new(@calls, credential, error_code: "http_503", retryable: true) }

    perform_authorized_ai_job(TranslationRunJob, run)
    assert run.reload.running?
    assert_equal 1, @calls.size

    Accounts::AiSettings.delete_key!(@current_test_user, state_token: state_token)
    perform_enqueued_jobs(only: TranslationRunJob)

    assert_equal 1, @calls.size, "the retry sent nothing, on any key"
    assert run.reload.failed?
    assert_equal "personal_key_unavailable", run.error_code
    assert_equal [ "failed" ], run.provider_attempts.pluck(:status)
  end

  test "a disabled or unverified owner is denied in both modes" do
    [ { status: :disabled }, { email_verified_at: nil } ].each do |change|
      [ false, true ].each do |personal|
        run = build_runs.first
        personal ? use_personal_key : nil
        schedule!(run)
        @current_test_user.update_columns(change.transform_values { |value| value.is_a?(Symbol) ? value.to_s : value })

        perform_authorized_ai_job(TranslationRunJob, run)

        assert_empty @calls
        assert_equal "ai_account_ineligible", run.reload.error_code
        @current_test_user.update_columns(status: "active", email_verified_at: Time.current)
        reset_key!
      end
    end
  end

  test "a run stamped with another user's key is refused" do
    run = build_runs.first
    foreign = users(:other).open_router_credentials.create!(api_key: REPLACEMENT_KEY)
    schedule!(run)
    run.update_columns(billing_source: "personal", open_router_credential_id: foreign.id)

    perform_authorized_ai_job(TranslationRunJob, run)

    assert_empty @calls
    assert_equal "personal_key_unavailable", run.reload.error_code
  end

  test "undecryptable key ciphertext fails closed instead of using the platform key" do
    run = build_runs.first
    credential = use_personal_key
    schedule!(run)
    # Raw SQL: a hash update_all would encrypt the value through the attribute type.
    OpenRouterCredential.connection.execute(
      "UPDATE open_router_credentials SET api_key = '{\"p\":\"bm90LWNpcGhlcnRleHQ=\",\"h\":{}}' WHERE id = #{Integer(credential.id)}"
    )

    perform_authorized_ai_job(TranslationRunJob, run)

    assert_empty @calls
    assert_equal "personal_key_unavailable", run.reload.error_code
  end

  test "job arguments, logs, and attempt records never contain the key" do
    run = build_runs.first
    use_personal_key
    log = StringIO.new
    original_logger = Rails.logger
    Rails.logger = ActiveSupport::Logger.new(log)
    begin
      enqueued = Ai::RunScheduler.prepare(run: run, job_class: TranslationRunJob, billing: Ai::BillingPolicy.authorize!(@current_test_user))
      assert_equal [ run.id ], enqueued.job.serialize.fetch("arguments")
      assert_not_includes enqueued.job.serialize.to_json, PERSONAL_KEY
      perform_authorized_ai_job(TranslationRunJob, run)
    ensure
      Rails.logger = original_logger
    end

    assert_equal 1, @calls.size
    assert_not_includes log.string, PERSONAL_KEY
    assert_not_includes run.reload.attributes.to_json, PERSONAL_KEY
    assert_not_includes run.provider_attempts.sole.attributes.to_json, PERSONAL_KEY
    assert_not_includes OpenRouterCredential.connection.select_value("SELECT api_key FROM open_router_credentials WHERE revoked_at IS NULL"), PERSONAL_KEY
  end

  private

  def build_runs
    experiment = create_experiment
    review_round = create_completed_review_round
    mutate_historical_fixture { review_round.update!(status: :running) }
    judge_round = create_completed_review_round.create_judge_round!(status: :running)
    final_translation = create_final_translation_workspace
    finalization_round = final_translation.finalization_rounds.create!(
      base_version: final_translation.current_version, selection_key: SecureRandom.hex(32), status: :running
    )
    clear_enqueued_jobs
    [
      experiment.translation_runs.create!(llm_model: llm_models(:openrouter_claude)),
      review_round.review_runs.create!(reviewer_llm_model: llm_models(:openrouter_gpt)),
      judge_round.judge_runs.create!(judge_llm_model: create_judge_model),
      finalization_round.finalization_runs.create!(finalizer_llm_model: create_finalizer)
    ]
  end

  def create_experiment
    project = @current_test_user.projects.create!(name: "BYOK #{SecureRandom.hex(3)}", source_language: "Vietnamese", target_language: "Japanese")
    project.documents.create!(title: "Source", source_text: "Source text")
           .experiments.create!(instruction_prompt: "Translate.", status: :running)
  end

  def schedule!(run)
    run.class.transaction do
      Ai::RunScheduler.prepare(run: run, job_class: JOBS.fetch(run.class), billing: Ai::BillingPolicy.authorize!(@current_test_user.reload))
    end
  end

  def use_personal_key
    Accounts::AiSettings.store_key!(@current_test_user, api_key: PERSONAL_KEY, state_token: state_token)
    Accounts::AiSettings.select_source!(@current_test_user, source: "personal", state_token: state_token)
    @current_test_user.reload.active_open_router_credential
  end

  def reset_key!
    @current_test_user.reload.update!(ai_payment_source: "managed")
    @current_test_user.open_router_credentials.active.each { |credential| credential.revoke!(reason: "deleted") }
  end

  def state_token
    Accounts::AiSettings.state(@current_test_user.reload).fetch(:state_token)
  end
end
