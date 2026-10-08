require "test_helper"
require "timeout"

module OpenRouter
  class ModelResolverConcurrencyTest < ActiveSupport::TestCase
    self.use_transactional_tests = false

    teardown do
      LlmModel.where(model_identifier: "vendor/review-race").delete_all
    end

    test "two first materializations reload the unique index winner inside an outer transaction" do
      ready, release, outcomes = Queue.new, Queue.new, Queue.new
      models = 2.times.map { candidate }
      models.each do |model|
        model.define_singleton_method(:_create_record) do |*arguments, &block|
          ready << true
          release.pop
          super(*arguments, &block)
        end
      end
      threads = models.map do |model|
        Thread.new do
          ActiveRecord::Base.connection_pool.with_connection do
            LlmModel.transaction do
              resolved = ModelResolver.materialize!(model)
              # A unique violation must not poison the caller's transaction.
              outcomes << [ resolved.id, LlmModel.find(resolved.id).active? ]
            end
          end
        rescue StandardError => error
          outcomes << error
        end
      end
      Timeout.timeout(10) { 2.times { ready.pop } }
      2.times { release << true }
      threads.each { |thread| thread.join(10) || flunk("materialization did not finish") }
      results = 2.times.map { outcomes.pop }
      assert_empty results.grep(Exception), results.grep(Exception).map(&:full_message).join("\n")
      winner = LlmModel.find_by!(model_identifier: "vendor/review-race")
      assert_equal [ [ winner.id, true ], [ winner.id, true ] ], results
      assert_equal 1, LlmModel.where(model_identifier: "vendor/review-race").count
    ensure
      2.times { release << true }
      threads&.each(&:join)
    end

    test "winner committed before uniqueness validation is reused with its authoritative metadata" do
      loser = candidate
      commit_winner_before_save(loser, active: true)
      LlmModel.transaction do
        winner = ModelResolver.materialize!(loser)
        assert_equal "Winning metadata", winner.display_name
        assert winner.active?
        assert_equal winner.id, LlmModel.find_by!(model_identifier: loser.model_identifier).id
      end
      assert_equal 1, LlmModel.where(model_identifier: loser.model_identifier).count
    end

    test "a winner deactivated before loser validation stays inactive without activation permission" do
      loser = candidate
      commit_winner_before_save(loser, active: false)
      assert_raises(ModelResolver::InactiveModelError) { ModelResolver.materialize!(loser) }
      refute LlmModel.find_by!(model_identifier: loser.model_identifier).active?
    end

    test "authorized activation reuses and activates a concurrent inactive winner" do
      loser = candidate
      commit_winner_before_save(loser, active: false)
      winner = ModelResolver.materialize!(loser, activate: true)
      assert winner.reload.active?
      assert_equal "Winning metadata", winner.display_name
      assert_equal 1, LlmModel.where(model_identifier: loser.model_identifier).count
    end

    test "other validation errors are not hidden by a concurrent identity winner" do
      loser = candidate
      loser.display_name = ""
      commit_winner_before_save(loser, active: true)
      assert_raises(ModelResolver::Error) { ModelResolver.materialize!(loser) }
      assert_equal "Winning metadata", LlmModel.find_by!(model_identifier: loser.model_identifier).display_name
    end

    private

    def commit_winner_before_save(loser, active:)
      winner = candidate
      winner.display_name = "Winning metadata"
      loser.define_singleton_method(:save!) do |**options|
        # Joining is the barrier: the initial missing-row lookup has happened,
        # and another request commits before this request validates uniqueness.
        Thread.new do
          ActiveRecord::Base.connection_pool.with_connection do
            resolved = ModelResolver.materialize!(winner)
            resolved.update!(active: false) unless active
          end
        end.value
        super(**options)
      end
    end

    def candidate
      LlmModel.new(gateway: "openrouter", provider: "vendor", model_identifier: "vendor/review-race",
        display_name: "Review race", active: true, context_window_tokens: 32_000, max_output_tokens: 4_096)
    end
  end
end
