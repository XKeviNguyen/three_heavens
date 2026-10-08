require "test_helper"
require "stringio"
require "tmpdir"

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

  test "a restored object whose bytes differ from its blob record is a problem, critical for a document source" do
    project = Project.create!(user: users(:normal), name: "Restore bytes #{SecureRandom.hex(4)}",
                              source_language: "Vietnamese", target_language: "Japanese")
    document = project.documents.create!(title: "Restore source", source_text: "private source", source_kind: :pasted_text)
    document.source_file.attach(io: StringIO.new("exact restored bytes"), filename: "source.txt", content_type: "text/plain")
    staged = ActiveStorage::Blob.create_and_upload!(io: StringIO.new("unattached staged bytes"), filename: "staged.txt")
    # Audit a private copy of just these objects: parallel workers share the
    # service root, and their files would change the counts between audits.
    storage_root = Dir.mktmpdir("restore-bytes")
    path = lambda do |blob|
      File.join(storage_root, blob.key[0..1], blob.key[2..3], blob.key).tap do |copy|
        FileUtils.mkdir_p(File.dirname(copy))
        FileUtils.cp(ActiveStorage::Blob.service.path_for(blob.key), copy) unless File.exist?(copy)
      end
    end
    [ document.source_file.blob, staged ].each(&path)
    audit = lambda do
      Operations::Restore::IntegrityAudit.call(
        database_url: "isolated-test-connection", storage_path: storage_root,
        connector: ExistingConnection.new(ActiveRecord::Base.connection.raw_connection)
      )
    end
    baseline = audit.call

    File.binwrite(path.call(staged), "unattached staged byteZ")
    altered = audit.call
    assert_equal baseline.corrupt_disk_objects + 1, altered.corrupt_disk_objects
    assert_equal baseline.warning_count + 1, altered.warning_count
    assert_equal baseline.critical_count, altered.critical_count

    File.binwrite(path.call(document.source_file.blob), "exact restored")
    truncated = audit.call
    assert_equal baseline.corrupt_disk_objects + 2, truncated.corrupt_disk_objects
    assert_equal baseline.critical_count + 1, truncated.critical_count
    assert_not truncated.successful?
  ensure
    FileUtils.rm_rf(storage_root) if storage_root
    document&.source_file&.purge
    staged&.purge
    Document.where(id: document&.id).delete_all
    Project.where(id: project&.id).delete_all
  end
end
