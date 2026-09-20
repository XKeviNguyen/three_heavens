require "test_helper"
require "stringio"

class ActiveStorageMaintenance::CleanupTest < ActiveSupport::TestCase
  test "cleanup is bounded dry-run by default and preserves attached or recent blobs" do
    stale = upload("stale")
    second_stale = upload("second stale")
    recent = upload("recent")
    attached = upload("durable")
    [ stale, second_stale, attached ].each { |blob| blob.update_column(:created_at, 8.days.ago) }
    documents(:one).source_file.attach(attached)

    preview = ActiveStorageMaintenance::Cleanup.call(batch_size: 1)
    assert_equal 1, preview.candidate_count
    assert_equal 0, preview.purged_count
    assert ActiveStorage::Blob.exists?(stale.id)

    first = ActiveStorageMaintenance::Cleanup.call(batch_size: 1, execute: true)
    second = ActiveStorageMaintenance::Cleanup.call(batch_size: 10, execute: true)
    assert_equal 1, first.purged_count
    assert_equal 1, second.purged_count
    assert_not ActiveStorage::Blob.exists?(stale.id)
    assert_not ActiveStorage::Blob.exists?(second_stale.id)
    assert ActiveStorage::Blob.exists?(recent.id)
    assert ActiveStorage::Blob.exists?(attached.id)
    assert documents(:one).reload.source_file.attached?
  ensure
    [ stale, second_stale, recent, attached ].compact.each { |blob| blob.purge if blob.persisted? }
  end

  private

  def upload(content)
    ActiveStorage::Blob.create_and_upload!(
      io: StringIO.new(content),
      filename: "#{SecureRandom.hex(4)}.txt",
      content_type: "text/plain"
    )
  end
end
