require "test_helper"
require_relative "../../support/document_io_test_helper"
require_relative "../../support/process_barrier"
require_relative "../../support/upload_budget_clock"

module TranslationReferences
  class CreationProcessTest < ActiveSupport::TestCase
    include DocumentIoTestHelper
    include ProcessBarrier
    include UploadBudgetClock
    self.use_transactional_tests = false

    test "crash during first extraction leaves a tenth-slot action that never recharges or repeats work" do
      user = User.create!(email: "reference-crash-#{SecureRandom.hex(8)}@example.test", password: "synthetic crash password", role: :user, status: :active)
      9.times { UploadBudget.consume(user:) }
      key = ReplayIdentity.issue
      attributes = -> { { title: "Interrupted", source_language: "English", target_language: "Japanese", source_file: uploaded_file("Interrupted", filename: "source.txt"), approved_translation: "Approved" } }
      crash_at_extraction { Create.call(user:, creation_key: key, attributes: attributes.call) }
      assert TranslationReferenceCreation.find_by!(user:, creation_key: key).pending?
      assert_equal 10, UploadBudget.find_by!(user:).count
      assert_raises(Create::Interrupted) { Create.call(user:, creation_key: key, attributes: attributes.call) }
      assert_empty user.translation_references
      assert_equal 10, UploadBudget.find_by!(user:).count
    ensure
      if user
        TranslationReferenceCreation.where(user:).delete_all
        UploadBudget.where(user:).delete_all
        user.delete
      end
    end
  end
end
