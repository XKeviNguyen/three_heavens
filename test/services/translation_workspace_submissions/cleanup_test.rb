require "test_helper"

module TranslationWorkspaceSubmissions
  class CleanupTest < ActiveSupport::TestCase
    test "bounded cleanup removes only expired unused identities" do
      expired = nil
      travel_to 2.days.ago do
        expired = claimed_submission
      end
      fresh = claimed_submission
      consumed = claimed_submission
      consumed.update!(status: :consumed, consumed_at: Time.current, experiment: experiments(:one))

      result = Cleanup.call(batch_size: 1)

      assert_equal 1, result.purged_count
      assert_not TranslationWorkspaceSubmission.exists?(expired.id)
      assert TranslationWorkspaceSubmission.exists?(fresh.id)
      assert TranslationWorkspaceSubmission.exists?(consumed.id)
      assert_raises(ArgumentError) { Cleanup.call(batch_size: 0) }
    end

    private

    def claimed_submission
      token = TranslationWorkspaceSubmission.issue_token(user: users(:normal))
      TranslationWorkspaceSubmission.claim!(user: users(:normal), token:)
    end
  end
end
