require "test_helper"
require "stringio"

class ActiveStorageMaintenance::PurgeTest < ActiveSupport::TestCase
  self.use_transactional_tests = false

  test "a cached unattached lookup never deletes bytes attached by another connection" do
    blob = ActiveStorage::Blob.create_and_upload!(io: StringIO.new("Referenced source"), filename: "cache-probe.txt", content_type: "text/plain")
    configuration = ActiveRecord::Base.connection_db_config.configuration_hash
    other = PG.connect(host: configuration[:host], port: configuration[:port], user: configuration[:username],
      password: configuration[:password], dbname: configuration[:database])
    ActiveRecord::Base.cache do
      assert blob.attachments.none?
      other.exec_params(<<~SQL, [ blob.id, documents(:one).id ])
        INSERT INTO active_storage_attachments (name, record_type, record_id, blob_id, created_at, updated_at)
        VALUES ('cache_probe', 'Document', $2, $1, NOW(), NOW())
      SQL
      assert_not ActiveStorageMaintenance::Purge.call(blob:)
      assert ActiveStorage::Blob.exists?(blob.id)
      assert blob.service.exist?(blob.key)
      assert ActiveRecord::Base.uncached { ActiveStorage::Attachment.where(blob_id: blob.id).exists? }
    end
  ensure
    other&.close
    ActiveStorage::Attachment.where(blob_id: blob.id).delete_all if blob
    ActiveStorageMaintenance::Purge.call(blob:) if blob
  end
end
