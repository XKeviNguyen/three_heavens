require "test_helper"
require "stringio"

class Operations::Restore::IntegrityAuditTest < ActiveSupport::TestCase
  self.use_transactional_tests = false

  class ExistingConnection
    def initialize(connection)
      @connection = connection
    end

    def connect(*)
      Proxy.new(@connection)
    end

    class Proxy
      def initialize(connection)
        @connection = connection
      end

      def method_missing(name, ...)
        @connection.public_send(name, ...)
      end

      def respond_to_missing?(name, include_private = false)
        @connection.respond_to?(name, include_private)
      end

      def close
        nil
      end
    end
  end

  test "audits durable document storage with aggregate-only results" do
    project = Project.create!(
      user: users(:normal),
      name: "Restore audit #{SecureRandom.hex(4)}",
      source_language: "Vietnamese",
      target_language: "Japanese"
    )
    document = project.documents.create!(
      title: "Restore source",
      source_text: "private source",
      source_kind: :pasted_text
    )
    document.source_file.attach(
      io: StringIO.new("exact restored bytes"),
      filename: "private-original-name.txt",
      content_type: "text/plain"
    )
    connector = ExistingConnection.new(ActiveRecord::Base.connection.raw_connection)

    result = Operations::Restore::IntegrityAudit.call(
      database_url: "isolated-test-connection",
      storage_path: ActiveStorage::Blob.service.root,
      expected_schema_version: ActiveRecord::Base.connection_pool.migration_context.current_version,
      connector: connector
    )

    assert result.successful?
    assert_operator result.blob_count, :>=, 1
    assert_operator result.attachment_count, :>=, 1
    assert_operator result.document_source_attachment_count, :>=, 1
    assert_equal 0, result.missing_disk_objects
    assert_equal 0, result.critical_count
    assert_not_includes result.inspect, "private-original-name"
    assert_not_includes result.inspect, "private source"
  ensure
    document&.source_file&.purge
    Document.where(id: document&.id).delete_all
    Project.where(id: project&.id).delete_all
  end
end
