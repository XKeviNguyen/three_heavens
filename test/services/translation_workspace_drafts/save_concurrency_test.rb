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

    # The interleaving from CI: the losing save finds no draft, the winner
    # commits, and only then does the loser insert. The unique index must
    # reject that insert and the loser must resolve it as a conflict.
    test "a first save whose insert follows another tab's committed first save reports a conflict" do
      winner, loser = SecureRandom.hex(16), SecureRandom.hex(16)
      paused = Queue.new
      resume = Queue.new
      pause_once = lambda do |_draft|
        next unless Thread.current[:pause_before_insert]

        Thread.current[:pause_before_insert] = false
        paused << true
        resume.pop
      end
      TranslationWorkspaceDraft.set_callback(:validation, :before, pause_once)

      losing = Thread.new do
        ActiveRecord::Base.connection_pool.with_connection do
          Thread.current[:pause_before_insert] = true
          save(editor: loser, sequence: 1, text: "Loser")
        rescue StandardError => error
          error
        end
      end
      paused.pop
      won = ActiveRecord::Base.connection_pool.with_connection { save(editor: winner, sequence: 1, text: "Winner") }
      resume << true
      lost = losing.value

      assert_not won.conflict?
      assert_kind_of Save::Result, lost, lost.try(:full_message)
      assert lost.conflict?
      assert_equal won.draft.id, lost.draft.id
      draft = TranslationWorkspaceDraft.where(user_id: @user.id).sole
      assert_equal [ "Winner", winner, 1 ], [ draft.payload.fetch("source_text"), draft.editor_id, draft.editor_sequence ]
    ensure
      TranslationWorkspaceDraft.skip_callback(:validation, :before, pause_once)
    end

    test "repeated simultaneous first saves from two tabs always keep one winner and lose no later edit" do
      100.times do |iteration|
        editors = [ SecureRandom.hex(16), SecureRandom.hex(16) ]
        results = concurrently(editors) { |editor| save(editor:, sequence: 1, text: "From #{editor}") }

        assert_empty results.grep(Exception), "iteration #{iteration}: #{results.grep(Exception).map(&:full_message).join("\n")}"
        winners, losers = results.partition { |result| !result.conflict? }
        assert_equal [ 1, 1 ], [ winners.size, losers.size ], "iteration #{iteration}"
        draft = TranslationWorkspaceDraft.where(user_id: @user.id).sole
        assert_equal winners.sole.draft.id, losers.sole.draft.id
        assert_includes editors, draft.editor_id
        assert_equal [ "From #{draft.editor_id}", 1 ], [ draft.payload.fetch("source_text"), draft.editor_sequence ]

        # The winning tab keeps saving; the losing tab's text never lands.
        followed = save(editor: draft.editor_id, sequence: 2, text: "Later edit #{iteration}")
        assert_not followed.conflict?
        assert_equal [ "Later edit #{iteration}", 2 ], [ draft.reload.payload.fetch("source_text"), draft.editor_sequence ]
        TranslationWorkspaceDraft.where(user_id: @user.id).delete_all
      end
    end

    test "other invalid first saves still fail validation" do
      assert_raises(ActiveRecord::RecordInvalid) do
        Save.call(user: @user, context_key: "x" * 81, payload: { "source_text" => "Text" },
                  draft_id: nil, version: nil, editor_id: SecureRandom.hex(16), sequence: 1)
      end
      assert_empty TranslationWorkspaceDraft.where(user_id: @user.id)
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
