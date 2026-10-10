require "test_helper"
require "timeout"

# Key changes and execution claims run in different processes; they are
# serialized by the owner's row lock, never by in-memory state.
class Ai::BillingConcurrencyTest < ActiveSupport::TestCase
  self.use_transactional_tests = false

  KEY = "sk-or-v1-#{"5a" * 32}".freeze
  OTHER_KEY = "sk-or-v1-#{"6b" * 32}".freeze

  setup do
    @user = users(:other)
    @project = @user.projects.create!(name: "Billing race", source_language: "Vietnamese", target_language: "Japanese")
  end

  # The tested paths create no provider attempts (immutable by trigger), so
  # only the rows below need removing.
  teardown do
    runs = TranslationRun.joins(experiment: :document).where(documents: { project_id: @project.id })
    runs.delete_all
    Experiment.joins(:document).where(documents: { project_id: @project.id }).delete_all
    Document.where(project_id: @project.id).delete_all
    @project.delete
    @user.open_router_credentials.delete_all
    @user.update_columns(ai_payment_source: "managed")
  end

  test "a claim waits for an in-progress key deletion and then fails closed" do
    run = scheduled_personal_run
    locked, release, outcome = Queue.new, Queue.new, Queue.new

    deleter = Thread.new do
      ActiveRecord::Base.connection_pool.with_connection do
        @user.with_lock do
          @user.open_router_credentials.active.sole.revoke!(reason: "deleted")
          locked << true
          release.pop
        end
      end
    end
    Timeout.timeout(10) { locked.pop }
    claimer = Thread.new do
      ActiveRecord::Base.connection_pool.with_connection do
        outcome << Ai::ExecutionClaim.call(TranslationRun.find(run.id), active_job_id: run.scheduled_job_id, active_job_execution: 1).state
      end
    rescue StandardError => error
      outcome << error
    end

    assert_nil claimer.join(0.5), "the claim must wait for the owner lock"
    release << true
    [ deleter, claimer ].each { |thread| thread.join(10) || flunk("thread did not finish") }

    assert_equal :terminal, outcome.pop
    assert_equal "personal_key_unavailable", run.reload.error_code
    assert_equal 0, AiProviderAttempt.where(provider_run: run).count
  ensure
    release&.push(true)
    [ deleter, claimer ].compact.each(&:join)
  end

  test "concurrent key saves from the same form keep exactly one active key" do
    token = Accounts::AiSettings.state(@user.reload).fetch(:state_token)
    start = Queue.new
    outcomes = Queue.new
    threads = [ KEY, OTHER_KEY ].map do |key|
      Thread.new do
        start.pop
        ActiveRecord::Base.connection_pool.with_connection do
          Accounts::AiSettings.store_key!(User.find(@user.id), api_key: key, state_token: token)
          outcomes << :saved
        end
      rescue Accounts::AiSettings::StaleError
        outcomes << :stale
      rescue StandardError => error
        outcomes << error
      end
    end
    2.times { start << true }
    threads.each { |thread| thread.join(10) || flunk("save did not finish") }

    assert_equal %i[saved stale], 2.times.map { outcomes.pop }.sort
    assert_equal 1, @user.open_router_credentials.count
    assert_equal 1, @user.open_router_credentials.active.count
  end

  private

  def scheduled_personal_run
    @user.open_router_credentials.create!(api_key: KEY)
    @user.update!(ai_payment_source: "personal")
    experiment = @project.documents.create!(title: "Source", source_text: "Source text")
                         .experiments.create!(instruction_prompt: "Translate.", status: :running)
    run = experiment.translation_runs.create!(llm_model: llm_models(:openrouter_claude))
    TranslationRun.transaction do
      Ai::RunScheduler.prepare(run: run, job_class: TranslationRunJob, billing: Ai::BillingPolicy.authorize!(@user.reload))
    end
    run.reload
  end
end
