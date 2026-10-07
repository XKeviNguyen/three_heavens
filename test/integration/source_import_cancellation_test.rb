require "test_helper"
require_relative "../support/document_io_test_helper"
require_relative "../support/process_barrier"
require_relative "../support/upload_budget_clock"

class SourceImportCancellationTest < ActionDispatch::IntegrationTest
  include DocumentIoTestHelper
  include ProcessBarrier
  include UploadBudgetClock
  self.use_transactional_tests = false

  setup do
    @user = User.create!(email: "cancel-race-#{SecureRandom.hex(8)}@example.test",
      password: "synthetic cancellation password", status: :active, email_verified_at: Time.current)
    post session_path, params: { session: { email: @user.email, password: "synthetic cancellation password" } }
    assert_response :redirect
    @cookies = cookies.to_hash
    @key = ReplayIdentity.issue
    @blobs_before = ActiveStorage::Blob.count
    @storage_keys = Queue.new
    keys = @storage_keys
    @original_upload = ActiveStorage::Blob.service.method(:upload)
    original_upload = @original_upload
    ActiveStorage::Blob.service.define_singleton_method(:upload) do |key, *arguments, **options|
      keys << key
      original_upload.call(key, *arguments, **options)
    end
    @threads = []
  end

  teardown do
    @threads.each { |thread| thread.kill.join(5) if thread.alive? }
    ActiveStorage::Blob.service.singleton_class.define_method(:upload, @original_upload.unbind)
    @user.source_imports.reload.find_each(&:destroy!)
    SourceImportRetirement.where(user: @user).delete_all
    UploadBudget.where(user: @user).delete_all
    Session.where(user: @user).delete_all
    @user.delete
  end

  test "DELETE waits for admitted extraction and purges the successful upload without refund" do
    9.times { UploadBudget.consume(user: @user) }
    with_paused_extraction do |reached, release|
      creator = async { upload }
      await_queue(reached)
      pending = @user.source_imports.sole
      cancellation = async { cancel(pending.id) }
      await_lock_waiters(1)
      assert pending.reload.pending?
      assert_not pending.source_file.attached?
      assert cancellation.alive?

      release << true
      assert_equal 201, finish(creator).first
      assert_equal 204, finish(cancellation).first
      assert_retired(pending.id, budget: 10)
      assert_equal [ 422, "import_unavailable" ], upload.then { |status, body| [ status, body.fetch("code") ] }
      assert_equal 429, upload(key: ReplayIdentity.issue).first
      assert_budget(10)
    end
  end

  test "normal completed cancellation blocks lost-response replay and permits a genuinely new action" do
    status, delivered = upload
    assert_equal 201, status
    source_import = @user.source_imports.sole
    blob = source_import.source_file.blob
    assert blob.service.exist?(blob.key)
    # Ignore the successful response, cancel, then deliver the original POST
    # again exactly as an ambiguous network retry would.
    assert_equal 204, cancel(source_import.id).first
    assert_retired(delivered.fetch("id"), budget: 1)
    assert_not blob.service.exist?(blob.key)
    3.times { assert_equal 422, upload.first }
    assert_budget(1)
    assert_equal 201, upload(key: ReplayIdentity.issue).first
    assert_equal 1, @user.source_imports.count
    assert_budget(2)
  end

  test "two concurrent cancellations reload after waiting and the second observes absence" do
    with_paused_extraction do |reached, release|
      creator = async { upload }
      await_queue(reached)
      pending = @user.source_imports.sole
      cancellations = 2.times.map { async { cancel(pending.id) } }
      await_lock_waiters(2)
      release << true
      assert_equal 201, finish(creator).first
      assert_equal [ 204, 404 ], cancellations.map { finish(it).first }.sort
      assert_retired(pending.id, budget: 1)
    end
  end

  test "cancellation waits for extraction failure and purges its terminal file" do
    with_paused_extraction do |reached, release|
      creator = async { upload(bytes: "PK\x03\x04invalid".b, filename: "failed.docx", content_type: SourceImports::Detector::DOCX_MIME) }
      await_queue(reached)
      pending = @user.source_imports.sole
      cancellation = async { cancel(pending.id) }
      await_lock_waiters(1)
      release << true
      assert_equal [ 422, "malformed_docx" ], finish(creator).then { |status, body| [ status, body.fetch("code") ] }
      assert_equal 204, finish(cancellation).first
      assert_retired(pending.id, budget: 1)
    end
  end

  test "Busy before work refunds once and a waiting cancellation observes absence" do
    held, finish_slot = Queue.new, Queue.new
    holder = async { SourceImports::PdfExtractor::WORKER_SLOTS.hold { held << true; finish_slot.pop } }
    await_queue(held)
    with_paused_extraction do |reached, release|
      creator = async { upload(bytes: pdf_with_text("Busy"), filename: "busy.pdf", content_type: "application/pdf") }
      await_queue(reached)
      pending = @user.source_imports.sole
      cancellation = async { cancel(pending.id) }
      await_lock_waiters(1)
      release << true
      assert_equal 503, finish(creator).first
      assert_equal 404, finish(cancellation).first
      assert_empty @user.source_imports.reload
      assert_empty SourceImportRetirement.where(user: @user)
      assert_budget(0)
      assert_storage_clear
    end
    finish_slot << true
    finish(holder)
    assert_equal 201, upload.first
    assert_budget(1)
  ensure
    finish_slot << true if holder&.alive?
  end

  test "process death after admission releases the lock and cancellation removes the pending action" do
    crash_at_extraction { SourceImports::Create.call(user: @user, request_key: @key, upload: uploaded_file("Cancelled source", filename: "cancel.txt")) }
    pending = @user.source_imports.sole
    assert pending.pending?
    assert_equal 204, cancel(pending.id).first
    assert_retired(pending.id, budget: 1)
    assert_equal 422, upload.first
    assert_budget(1)
  end

  [ false, true ].each do |after_write|
    test "cancellation after process death at storage write #{after_write} removes database and disk content" do
      crash_at_storage(after_write:) { SourceImports::Create.call(user: @user, request_key: @key, upload: uploaded_file("Cancelled source", filename: "cancel.txt")) }
      pending = @user.source_imports.sole
      assert pending.pending?
      blob = pending.source_file.blob
      @storage_keys << blob.key
      assert_equal after_write, blob.service.exist?(blob.key)
      assert_equal 204, cancel(pending.id).first
      assert_retired(pending.id, budget: 1)
      assert_not blob.service.exist?(blob.key)
      assert_equal 422, upload.first
    end
  end

  test "pending creation cancellation and duplicate delivery serialize without extra admission" do
    with_paused_extraction do |reached, release|
      creator = async { upload }
      await_queue(reached)
      pending = @user.source_imports.sole
      cancellation = async { cancel(pending.id) }
      await_lock_waiters(1)
      replay = async { upload }
      await_lock_waiters(2)
      release << true
      assert_equal 201, finish(creator).first
      assert_equal 204, finish(cancellation).first
      status, body = finish(replay)
      assert_includes [ 201, 422 ], status
      assert_equal pending.id, body.fetch("id") if status == 201
      assert_equal "import_unavailable", body.fetch("code") if status == 422
      assert_retired(pending.id, budget: 1)
    end
  end

  [ false, true ].each do |after_delete|
    test "death during cancellation storage deletion #{after_delete} leaves discoverable recovery" do
      assert_equal 201, upload.first
      source_import = @user.source_imports.sole
      blob = source_import.source_file.blob
      crash_at_storage_delete(after_delete:) { SourceImports::Retire.call(source_import:) }
      assert_not SourceImport.exists?(source_import.id)
      assert_not ActiveStorage::Attachment.where(record_type: "SourceImport", record_id: source_import.id).exists?
      assert ActiveStorage::Blob.unattached.exists?(blob.id)
      assert_equal !after_delete, blob.service.exist?(blob.key)
      assert_equal 422, upload.first
      assert_budget(1)
      recovery = ActiveStorageMaintenance::Cleanup.call(cutoff: 1.minute.from_now, execute: true)
      assert_equal 1, recovery.purged_count
      assert_retired(source_import.id, budget: 1)
    end
  end

  test "partial write and deletion outage terminalize failure and preserve discoverable recovery" do
    service = ActiveStorage::Blob.service
    original_upload = service.method(:upload)
    original_delete = service.method(:delete)
    service.define_singleton_method(:upload) do |*arguments, **options|
      original_upload.call(*arguments, **options)
      raise IOError, "synthetic partial-write outage"
    end
    service.define_singleton_method(:delete) { |*| raise IOError, "synthetic deletion outage" }
    assert_equal [ 422, "storage_unavailable" ], upload.then { |status, body| [ status, body.fetch("code") ] }
    failed = @user.source_imports.sole
    assert failed.failed?
    assert_not failed.source_file.attached?
    blob = ActiveStorage::Blob.unattached.sole
    assert blob.service.exist?(blob.key)
    assert_equal 422, upload.first
    assert_budget(1)
    assert_equal 0, ActiveStorageMaintenance::Cleanup.call(cutoff: 1.minute.from_now, execute: true).purged_count
    assert ActiveStorage::Blob.exists?(blob.id)
    service.singleton_class.define_method(:delete, original_delete.unbind)
    assert_equal 0, ActiveStorageMaintenance::Cleanup.call(cutoff: 1.minute.from_now, execute: true).purged_count
    travel_to blob.reload.cleanup_retry_at, with_usec: true do
      assert_equal 1, ActiveStorageMaintenance::Cleanup.call(cutoff: 1.minute.from_now, execute: true).purged_count
    end
    assert_equal 204, cancel(failed.id).first
    assert_retired(failed.id, budget: 1)
  ensure
    service.singleton_class.define_method(:upload, original_upload.unbind) if original_upload
    service.singleton_class.define_method(:delete, original_delete.unbind) if original_delete
  end

  test "DELETE lock timeout is retryable and does not change content or admission" do
    assert_equal 201, upload.first
    source_import = @user.source_imports.sole
    held, release = Queue.new, Queue.new
    holder = async do
      SourceImports::RequestLock.with(user_id: @user.id, request_key: @key) { held << true; release.pop }
    end
    await_queue(held)
    original = SourceImports::Limits::REQUEST_LOCK_WAIT_SECONDS
    SourceImports::Limits.send(:remove_const, :REQUEST_LOCK_WAIT_SECONDS)
    SourceImports::Limits.const_set(:REQUEST_LOCK_WAIT_SECONDS, 0.05)
    status, body, headers = cancel(source_import.id)
    assert_equal 503, status
    assert_equal "import_in_progress", body.fetch("code")
    assert_equal "5", headers.fetch("Retry-After")
    assert source_import.reload.available?
    assert source_import.source_file.blob.service.exist?(source_import.source_file.blob.key)
    assert_empty SourceImportRetirement.where(user: @user)
    assert_budget(1)
    release << true
    finish(holder)
    assert_equal 204, cancel(source_import.id).first
    assert_retired(source_import.id, budget: 1)
  ensure
    if original
      SourceImports::Limits.send(:remove_const, :REQUEST_LOCK_WAIT_SECONDS)
      SourceImports::Limits.const_set(:REQUEST_LOCK_WAIT_SECONDS, original)
    end
    release << true if holder&.alive?
  end

  test "cleanup skips a live creator and rechecks refreshed expiration" do
    with_paused_extraction do |reached, release|
      creator = async { upload }
      await_queue(reached)
      pending = @user.source_imports.sole
      pending.update!(expires_at: 1.minute.ago)
      cleanup = async { SourceImports::Cleanup.call }
      assert_equal 0, finish(cleanup).purged_count
      assert SourceImport.exists?(pending.id)
      release << true
      assert_equal 201, finish(creator).first
      assert pending.reload.available?
      assert pending.source_file.blob.service.exist?(pending.source_file.blob.key)
      pending.update!(expires_at: 1.minute.ago)
      assert_equal 1, SourceImports::Cleanup.call.purged_count
      assert_retired(pending.id, budget: 1)
      assert_equal 422, upload.first
    end
  end

  test "cleanup cannot expire a live storage write before its availability period begins" do
    original = ActiveStorage::Blob.service.method(:upload)
    reached, release = Queue.new, Queue.new
    ActiveStorage::Blob.service.define_singleton_method(:upload) do |*arguments, **options|
      original.call(*arguments, **options)
      reached << true
      release.pop
    end
    creator = async { upload }
    await_queue(reached)
    pending = @user.source_imports.sole
    pending.update!(expires_at: 1.minute.ago)
    cleanup = async { SourceImports::Cleanup.call }
    assert_equal 0, finish(cleanup).purged_count
    release << true
    assert_equal 201, finish(creator).first
    assert pending.reload.available?
    assert pending.source_file.blob.service.exist?(pending.source_file.blob.key)
    assert_budget(1)
  ensure
    release << true if creator&.alive?
    ActiveStorage::Blob.service.singleton_class.define_method(:upload, original.unbind) if original
  end

  test "consumption while cancellation waits is reloaded and keeps the document attachment" do
    assert_equal 201, upload.first
    source_import = @user.source_imports.sole
    held, release = Queue.new, Queue.new
    holder = async do
      SourceImports::RequestLock.with(user_id: @user.id, request_key: @key) { held << true; release.pop }
    end
    await_queue(held)
    cancellation = async { cancel(source_import.id) }
    await_lock_waiters(1)
    project = @user.projects.create!(name: "Consumed source", source_language: "English", target_language: "Japanese")
    document = project.documents.build(title: "Consumed", source_text: "Cancelled source")
    SourceImport.transaction do
      current = SourceImport.lock.find(source_import.id)
      SourceImports::Consume.apply!(source_import: current, document:)
      document.save!
      SourceImports::Consume.finish!(source_import: current, document:)
    end
    release << true
    finish(holder)
    assert_equal 409, finish(cancellation).first
    assert source_import.reload.consumed?
    assert document.reload.source_file.blob.service.exist?(document.source_file.blob.key)
    assert_empty SourceImportRetirement.where(user: @user)
    assert_budget(1)
  ensure
    if document&.persisted?
      mutate_historical_fixture do
        ActiveStorage::Attachment.where(record: document).delete_all
        SourceImport.where(id: source_import.id).update_all(resulting_document_id: nil, consumed_at: nil, status: "failed")
        document.delete
        project.delete
      end
    end
    release << true if holder&.alive?
  end

  test "a foreign owner cannot retire an action and a retirement key is owner scoped" do
    assert_equal 201, upload.first
    source_import = @user.source_imports.sole
    foreign = ActionDispatch::Integration::Session.new(Rails.application)
    foreign.post session_path, params: { session: { email: users(:other).email, password: "other secure password value" } }
    foreign.delete source_import_path(source_import, format: :json)
    assert_equal 404, foreign.response.status
    assert source_import.reload.available?
    assert_equal 204, cancel(source_import.id).first
    other = SourceImports::Create.call(user: users(:other), request_key: @key, upload: uploaded_file("Other owner", filename: "other.txt"))
    assert other.available?
  ensure
    other&.destroy!
    UploadBudget.where(user: users(:other)).delete_all
    foreign&.delete session_path
  end

  private

  def client
    ActionDispatch::Integration::Session.new(Rails.application).tap do |session|
      @cookies.each { |name, value| session.cookies[name] = value }
    end
  end

  def upload(key: @key, bytes: "Cancelled source", filename: "cancel.txt", content_type: "text/plain")
    session = client
    session.post source_imports_path(format: :json), params: { source_import: { request_key: key, source_file: uploaded_file(bytes, filename:, content_type:) } }
    [ session.response.status, session.response.parsed_body, session.response.headers ]
  end

  def cancel(id)
    session = client
    session.delete source_import_path(id, format: :json)
    body = session.response.body.present? && session.response.media_type == "application/json" ? session.response.parsed_body : nil
    [ session.response.status, body, session.response.headers ]
  end

  def async(&work)
    Thread.new do
      ActiveRecord::Base.connection_pool.with_connection { work.call }
    rescue StandardError => error
      error
    end.tap { @threads << it }
  end

  def finish(thread)
    assert thread.join(15), "worker did not finish"
    result = thread.value
    raise result if result.is_a?(Exception)

    result
  end

  def await_queue(queue)
    Timeout.timeout(10) { queue.pop }
  end

  def await_lock_waiters(count)
    Timeout.timeout(10) do
      loop do
        waiting = ActiveRecord::Base.uncached do
          ActiveRecord::Base.connection.select_value(<<~SQL)
            SELECT count(*) FROM pg_locks
            WHERE locktype = 'advisory' AND NOT granted
              AND database = (SELECT oid FROM pg_database WHERE datname = current_database())
          SQL
        end
        break if waiting >= count

        Thread.pass
      end
    end
  end

  def with_paused_extraction
    original = SourceImports::TextExtractor.method(:call)
    reached, release = Queue.new, Queue.new
    SourceImports::TextExtractor.define_singleton_method(:call) do |**arguments|
      reached << true
      release.pop
      original.call(**arguments)
    end
    yield reached, release
  ensure
    SourceImports::TextExtractor.singleton_class.define_method(:call, original.unbind)
  end

  def assert_budget(count)
    budget = UploadBudget.find_by!(user: @user)
    assert_equal count, budget.count
    assert_equal count, budget.receipts.size
    assert_equal count, budget.receipts.uniq.size
    assert_operator budget.count, :>=, 0
  end

  def assert_storage_clear
    assert_equal @blobs_before, ActiveStorage::Blob.count
    # Parallel test processes share a Disk service directory; inspect the
    # actual keys written by this example, not another process's files.
    @storage_keys.size.times do
      key = @storage_keys.pop
      assert_not ActiveStorage::Blob.service.exist?(key), "cancelled storage object survived"
    end
    assert_not ActiveStorage::Attachment.where(record_type: "SourceImport").where.not(record_id: SourceImport.select(:id)).exists?
  end

  def assert_retired(id, budget:)
    assert_not SourceImport.exists?(id)
    assert_not ActiveStorage::Attachment.where(record_type: "SourceImport", record_id: id).exists?
    assert_equal 1, SourceImportRetirement.where(user: @user, request_key: @key).count
    assert_storage_clear
    assert_budget(budget)
  end
end
