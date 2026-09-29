require "test_helper"

module TranslationWorkspaceDrafts
  class SaveConcurrencyTest < ActiveSupport::TestCase
    self.use_transactional_tests = false

    setup do
      @user = User.create!(
        email: "draft-race-#{SecureRandom.hex(8)}@example.test",
        password: "draft race password",
        role: :user,
        status: :active
      )
    end

    teardown do
      TranslationWorkspaceDraft.where(user_id: @user.id).delete_all
      @user.delete
    end

    test "simultaneous first saves from one page keep one draft with the newest edit" do
      editor = SecureRandom.hex(16)
      results = concurrently([ 1, 2 ]) { |sequence| save(editor:, sequence:, text: "Edit #{sequence}") }

      assert_empty results.grep(Exception), results.grep(Exception).map(&:full_message).join("\n")
      assert results.none?(&:conflict?)
      draft = TranslationWorkspaceDraft.where(user_id: @user.id).sole
      assert_equal [ "Edit 2", 2 ], [ draft.payload.fetch("source_text"), draft.editor_sequence ]
    end

    test "simultaneous first saves from two tabs keep one draft and report the other as a conflict" do
      results = concurrently([ SecureRandom.hex(16), SecureRandom.hex(16) ]) do |editor|
        save(editor:, sequence: 1, text: "From #{editor}")
      end

      assert_empty results.grep(Exception), results.grep(Exception).map(&:full_message).join("\n")
      assert_equal 1, results.count(&:conflict?)
      draft = TranslationWorkspaceDraft.where(user_id: @user.id).sole
      assert_equal "From #{draft.editor_id}", draft.payload.fetch("source_text")
    end

    private

    def save(editor:, sequence:, text:)
      Save.call(
        user: @user, context_key: "new", payload: { "source_text" => text },
        draft_id: nil, version: nil, editor_id: editor, sequence: sequence
      )
    end

    def concurrently(arguments, &block)
      ready = Queue.new
      gate = Queue.new
      results = Queue.new
      threads = arguments.map do |argument|
        Thread.new do
          ActiveRecord::Base.connection_pool.with_connection do
            ready << true
            gate.pop
            results << block.call(argument)
          rescue StandardError => error
            results << error
          end
        end
      end
      arguments.size.times { ready.pop }
      arguments.size.times { gate << true }
      threads.each(&:join)
      arguments.size.times.map { results.pop }
    end
  end
end
