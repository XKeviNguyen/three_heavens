require "test_helper"
require_relative "../support/document_io_test_helper"

class DocumentIoFlowTest < ActionDispatch::IntegrationTest
  include ActiveJob::TestHelper
  include DocumentIoTestHelper

  AI_JOBS = [ TranslationRunJob, ReviewRunJob, JudgeRunJob, FinalizationRunJob ].freeze

  setup do
    sign_in_as users(:normal)
    @model = llm_models(:openrouter_claude)
  end

  test "authenticated user uploads TXT previews and edits without AI work until submit" do
    assert_no_enqueued_jobs only: TranslationRunJob do
      post source_imports_path, params: {
        source_import: {
          source_file: uploaded_file("\xEF\xBB\xBFOriginal\r\ntext".b, filename: "sermon.txt", content_type: "text/plain")
        }
      }
    end

    source_import = SourceImport.order(:id).last
    binding = source_import_binding(source_import)
    assert_redirected_to new_translation_workspace_path(
      source_import_id: source_import.id,
      source_import_project_token: binding
    )
    assert source_import.ready?
    assert_equal "Original\ntext", source_import.extracted_text
    assert source_import.source_file.attached?

    follow_redirect!
    assert_response :success
    assert_select "textarea[name='translation_workspace[source_text]']", text: "Original\ntext"
    assert_select "input[name='translation_workspace[source_import_id]'][value='#{source_import.id}']"
    assert_select "button[data-action='workspace-upload#remove']", text: "Remove import"
    assert_no_enqueued_jobs only: TranslationRunJob

    blob_id = source_import.source_file.blob_id
    assert_enqueued_jobs 1, only: TranslationRunJob do
      post translation_workspace_path, params: {
        translation_workspace: workspace_attributes.merge(
          source_import_id: source_import.id,
          source_import_project_token: binding,
          source_text: "Reviewed and edited source"
        )
      }
    end

    document = Document.order(:id).last
    assert_redirected_to experiment_path(document.experiments.sole)
    assert_equal "Reviewed and edited source", document.source_text
    assert document.uploaded_file?
    assert_equal "txt", document.source_format
    assert_equal "sermon.txt", document.original_filename
    assert_equal source_import.sha256, document.source_sha256
    assert_equal SourceImports::Limits::EXTRACTION_VERSION, document.extraction_version
    assert_equal "\xEF\xBB\xBFOriginal\r\ntext".b.bytesize, document.original_byte_size
    assert_equal blob_id, document.source_file.blob_id
    assert source_import.reload.consumed?
    assert_nil source_import.extracted_text
    assert_equal document, source_import.resulting_document

    get experiment_path(document.experiments.sole)
    assert_select "p", text: /Uploaded file.*sermon\.txt.*TXT/m
    assert_select "a[href='#{download_original_document_path(document)}']", text: "Original source file"
    assert_select "div", text: /Reviewed and edited source/

    get project_path(document.project)
    assert_select "p", text: /Uploaded source.*sermon\.txt.*TXT/m
    assert_select "a[href='#{download_original_document_path(document)}']", text: "Download original"
  end

  test "text PDF is privately imported and reviewed before translation" do
    assert_no_enqueued_jobs only: AI_JOBS do
      post source_imports_path, params: {
        source_import: {
          source_file: uploaded_file(pdf_with_text("Readable PDF source"), filename: "source.pdf", content_type: "application/pdf")
        }
      }
    end

    source_import = SourceImport.order(:id).last
    assert source_import.ready?
    assert_equal "pdf", source_import.imported_format
    assert_equal "Readable PDF source", source_import.extracted_text
    assert_equal "test", source_import.source_file.blob.service_name
    assert_equal 0, AiProviderAttempt.count

    follow_redirect!
    assert_response :success
    assert_select "textarea[name='translation_workspace[source_text]']", text: "Readable PDF source"
    assert_select "input[name='translation_workspace[source_import_id]'][value='#{source_import.id}']"

    assert_enqueued_jobs 1, only: TranslationRunJob do
      post translation_workspace_path, params: {
        translation_workspace: workspace_attributes.merge(
          source_import_id: source_import.id,
          source_import_project_token: source_import_binding(source_import),
          source_text: "Reviewed PDF source"
        )
      }
    end
    document = Document.order(:id).last
    assert_equal "pdf", document.source_format
    assert_equal "Reviewed PDF source", document.source_text
    assert_equal source_import.source_file.blob_id, document.source_file.blob_id
  end

  test "pasted workflow remains supported with pasted provenance" do
    assert_enqueued_jobs 1, only: TranslationRunJob do
      post translation_workspace_path, params: {
        translation_workspace: workspace_attributes.merge(source_text: "Pasted source")
      }
    end

    document = Document.order(:id).last
    assert document.pasted_text?
    assert_not document.source_file.attached?
    assert_nil document.source_format
  end

  test "unsupported invalid binary and oversized uploads show safe errors and enqueue no AI" do
    uploads = [
      [ uploaded_file("%PDF", filename: "source.pdf"), /type does not match/ ],
      [ uploaded_file("abc\0def", filename: "source.txt", content_type: "text/plain"), /plain text/ ],
      [ uploaded_file("a" * (SourceImports::Limits::MAX_UPLOAD_BYTES + 1), filename: "huge.txt"), /larger than/ ]
    ]

    uploads.each do |upload, message|
      assert_no_enqueued_jobs only: TranslationRunJob do
        post source_imports_path, params: { source_import: { source_file: upload } }
      end
      assert_response :unprocessable_content
      assert_select "[role='alert']", text: message
      assert_not_includes response.body, "backtrace"
    end
  end

  test "document-specific parse failures are actionable and do not expose internals" do
    cases = [
      [ uploaded_file("plain", filename: "source.txt", content_type: SourceImports::Detector::DOCX_MIME), /type does not match/ ],
      [ uploaded_file("\xFF".b, filename: "source.txt", content_type: "text/plain"), /valid UTF-8/ ],
      [ uploaded_file(" \n\t", filename: "source.md", content_type: "text/markdown"), /readable text/ ],
      [ uploaded_file("a" * (SourceImports::Limits::MAX_EXTRACTED_CHARACTERS + 1), filename: "long.txt", content_type: "text/plain"), /character limit/ ],
      [ uploaded_file(build_docx(encrypted: true), filename: "encrypted.docx", content_type: SourceImports::Detector::DOCX_MIME), /Encrypted DOCX/ ],
      [ uploaded_file(Rails.root.join("test/fixtures/files/encrypted_source.pdf").binread, filename: "encrypted.pdf", content_type: "application/pdf"), /Encrypted or password-protected PDF/ ],
      [ uploaded_file(build_docx(entries: { "word/vbaProject.bin" => "macro" }), filename: "macro.docx", content_type: SourceImports::Detector::DOCX_MIME), /Macro-enabled/ ],
      [ uploaded_file(build_docx(entries: { "../outside" => "unsafe" }), filename: "unsafe.docx", content_type: SourceImports::Detector::DOCX_MIME), /cannot be processed safely/ ]
    ]

    cases.each do |upload, message|
      assert_no_enqueued_jobs only: AI_JOBS do
        post source_imports_path, params: { source_import: { source_file: upload } }
      end
      assert_response :unprocessable_content
      assert_select "[role='alert']", text: message
      assert_not_includes response.body, Rails.root.to_s
      assert_not_includes response.body, "storage/"
      assert_not_includes response.body, "backtrace"
    end
  end

  test "malformed upload parameter shapes return client errors without creating storage" do
    payloads = [
      {},
      { source_import: "malformed" },
      { source_import: [ "malformed" ] },
      { source_import: { source_file: { nested: "malformed" } } },
      { source_import: { source_file: [ "malformed" ] } }
    ]

    payloads.each do |payload|
      counts_before = [ SourceImport.count, ActiveStorage::Blob.count, ActiveStorage::Attachment.count ]
      assert_no_enqueued_jobs only: AI_JOBS do
        post source_imports_path, params: payload
      end

      assert_response :bad_request
      assert_equal counts_before, [ SourceImport.count, ActiveStorage::Blob.count, ActiveStorage::Attachment.count ]
      assert_select "[role='alert']", text: /upload request is invalid/i
      assert_not_includes response.body, "backtrace"
    end
  end

  test "failed DOCX upload keeps cleanup evidence and renders a POST form for a fresh retry" do
    malformed_docx = build_docx(document_xml: "not valid XML")

    assert_difference -> { SourceImport.failed.count }, 1 do
      assert_no_enqueued_jobs only: AI_JOBS do
        post source_imports_path, params: {
          source_import: {
            source_file: uploaded_file(
              malformed_docx,
              filename: "broken.docx",
              content_type: SourceImports::Detector::DOCX_MIME
            )
          }
        }
      end
    end

    failed_import = SourceImport.order(:id).last
    assert_response :unprocessable_content
    assert failed_import.failed?
    assert failed_import.source_file.attached?
    assert_select "form[action='#{source_imports_path}'][method='post']", count: 1
    assert_select "form[action='#{source_imports_path}'] input[name='_method']", count: 0

    assert_difference -> { SourceImport.ready.count }, 1 do
      assert_no_enqueued_jobs only: AI_JOBS do
        post source_imports_path, params: {
          source_import: {
            source_file: uploaded_file("Retry source", filename: "retry.txt", content_type: "text/plain")
          }
        }
      end
    end

    ready_import = SourceImport.order(:id).last
    assert_redirected_to new_translation_workspace_path(
      source_import_id: ready_import.id,
      source_import_project_token: source_import_binding(ready_import)
    )
    assert ready_import.ready?
    assert SourceImport.find(failed_import.id).failed?
  end

  test "Markdown HTML-like content stays editable escaped plain source text" do
    source = "# Heading\n<script>alert('source only')</script>"
    post source_imports_path, params: {
      source_import: {
        source_file: uploaded_file(source, filename: "source.md", content_type: "text/markdown")
      }
    }

    source_import = SourceImport.order(:id).last
    assert_redirected_to new_translation_workspace_path(
      source_import_id: source_import.id,
      source_import_project_token: source_import_binding(source_import)
    )
    follow_redirect!
    assert_select "textarea", text: source
    assert_includes response.body, "&lt;script&gt;alert"
    assert_not_includes response.body, "<script>alert"
  end

  test "foreign import cannot be submitted as provenance" do
    source_import = create_ready_import(user: users(:normal))
    sign_out
    sign_in_as users(:other)

    assert_no_difference [ -> { Project.count }, -> { Document.count }, -> { Experiment.count } ] do
      post translation_workspace_path, params: {
        translation_workspace: workspace_attributes.merge(source_import_id: source_import.id)
      }
    end
    assert_response :not_found
  end

  test "malformed GET source import IDs return 400 without storage or AI side effects" do
    source_import = create_ready_import(user: users(:normal))
    payloads = [
      { source_import_id: [ source_import.id ] },
      { source_import_id: { nested: source_import.id } }
    ]

    payloads.each do |payload|
      counts_before = [ SourceImport.count, ActiveStorage::Blob.count, ActiveStorage::Attachment.count ]
      assert_no_enqueued_jobs only: AI_JOBS do
        get new_translation_workspace_path, params: payload
      end

      assert_response :bad_request
      assert_empty response.body
      assert_equal counts_before, [ SourceImport.count, ActiveStorage::Blob.count, ActiveStorage::Attachment.count ]
      assert source_import.reload.ready?
    end
  end

  test "missing original attachment returns safe not found" do
    get download_original_document_path(documents(:one))

    assert_response :not_found
  end

  test "foreign and admin users cannot preview consume or download another owners source" do
    source_import = create_ready_import(user: users(:normal), text: "Private text")
    document = consume_import(source_import)

    sign_out
    sign_in_as users(:other)
    get new_translation_workspace_path(source_import_id: source_import.id)
    assert_response :not_found
    get download_original_document_path(document)
    assert_response :not_found

    sign_out
    sign_in_as users(:admin)
    get download_original_document_path(document)
    assert_response :not_found
  end

  test "owner downloads original with attachment disposition safe MIME and filename" do
    source_import = create_ready_import(
      user: users(:normal),
      text: "Private UTF-8 日本語",
      filename: "..\\unsafe\r\nname.txt"
    )
    document = consume_import(source_import)

    get download_original_document_path(document)

    assert_response :success
    assert_equal "Private UTF-8 日本語", response.body.force_encoding(Encoding::UTF_8)
    assert_equal "text/plain", response.media_type
    disposition = response.headers.fetch("Content-Disposition")
    assert_includes disposition, "attachment"
    refute_match(/[\r\n]/, disposition)
    assert_equal "nosniff", response.headers["X-Content-Type-Options"]
  end

  test "long Unicode original filename stays bounded through provenance and download" do
    source_import = create_ready_import(
      user: users(:normal),
      text: "Private Unicode source",
      filename: "神学" * 180 + ".txt"
    )
    document = consume_import(source_import)

    assert_equal SourceImports::Limits::MAX_ORIGINAL_FILENAME_CHARACTERS, source_import.original_filename.length
    assert source_import.original_filename.end_with?(".txt")
    assert_equal source_import.original_filename, document.original_filename

    get download_original_document_path(document)

    assert_response :success
    assert_equal "Private Unicode source", response.body
    refute_match(/[\r\n]/, response.headers.fetch("Content-Disposition"))
  end

  test "one-time consumption rejects a second workflow" do
    source_import = create_ready_import(user: users(:normal))
    first = TranslationWorkspace.new(
      workspace_attributes.merge(
        user: users(:normal),
        source_import:,
        source_import_id: source_import.id,
        source_import_project_token: source_import_binding(source_import)
      )
    )
    assert first.submit

    second = TranslationWorkspace.new(
      workspace_attributes.merge(
        user: users(:normal),
        source_import: source_import.reload,
        source_import_id: source_import.id,
        source_import_project_token: source_import_binding(source_import)
      )
    )
    assert_not second.submit
    assert_includes second.errors[:source_import_id].join, "was already used"
    assert_equal 1, SourceImport.find(source_import.id).resulting_document.experiments.count
  end

  test "expired import is reported unavailable and cannot create or enqueue anything" do
    source_import = create_ready_import(user: users(:normal))
    source_import.update!(expires_at: 1.minute.ago)

    binding = source_import_binding(source_import)
    get new_translation_workspace_path(source_import_id: source_import.id, source_import_project_token: binding)
    assert_response :success
    assert_select "h2", text: "Please correct the following:"
    assert_select "li", text: /Source import.*has expired/i

    assert_no_workspace_records_created do
      assert_no_enqueued_jobs only: AI_JOBS do
        post translation_workspace_path, params: {
          translation_workspace: workspace_attributes.merge(
            source_import_id: source_import.id,
            source_import_project_token: binding
          )
        }
      end
    end

    assert_response :unprocessable_content
    assert source_import.reload.ready?
    assert_nil source_import.resulting_document
  end

  test "locked consumption rechecks an import that expires after form validation" do
    source_import = create_ready_import(user: users(:normal))
    before_expiration = source_import.expires_at - 1.second
    at_expiration = source_import.expires_at
    clock_calls = 0
    clock = lambda do
      clock_calls += 1
      clock_calls == 1 ? before_expiration : at_expiration
    end
    workspace = TranslationWorkspace.new(
      workspace_attributes.merge(
        user: users(:normal),
        source_import:,
        source_import_id: source_import.id,
        source_import_project_token: source_import_binding(source_import)
      ),
      clock:
    )

    assert_no_workspace_records_created do
      assert_no_enqueued_jobs only: AI_JOBS do
        assert_not workspace.submit
      end
    end

    assert_operator clock_calls, :>=, 2
    assert_includes workspace.errors[:source_import_id], "This source import has expired; upload the source file again."
    assert source_import.reload.ready?
    assert_nil source_import.resulting_document
  end

  test "workspace rollback leaves import usable and retains its upload" do
    source_import = create_ready_import(user: users(:normal))
    failing_start = Class.new do
      def self.call(**)
        raise TranslationExperiments::Start::InvalidExperimentStateError
      end
    end
    workspace = TranslationWorkspace.new(
      workspace_attributes.merge(
        user: users(:normal),
        source_import:,
        source_import_id: source_import.id,
        source_import_project_token: source_import_binding(source_import)
      ),
      start_service: failing_start
    )

    assert_not workspace.submit
    source_import.reload
    assert source_import.ready?
    assert source_import.source_file.attached?
    assert_nil source_import.resulting_document
    assert_equal "Imported source", source_import.extracted_text
  end

  test "cancel removes only an abandoned owner import" do
    source_import = create_ready_import(user: users(:normal))
    blob = source_import.source_file.blob
    attachment_id = source_import.source_file.attachment.id
    assert_no_enqueued_jobs only: [ ActiveStorage::PurgeJob, *AI_JOBS ] do
      delete source_import_path(source_import)
    end
    assert_redirected_to new_translation_workspace_path
    assert_not SourceImport.exists?(source_import.id)
    assert_not ActiveStorage::Attachment.exists?(attachment_id)
    assert_not ActiveStorage::Blob.exists?(blob.id)
    assert_not blob.service.exist?(blob.key)

    consumed = create_ready_import(user: users(:normal))
    consume_import(consumed)
    delete source_import_path(consumed)
    assert_redirected_to new_translation_workspace_path
    assert SourceImport.exists?(consumed.id)

    delete source_import_path(consumed, format: :json)
    assert_response :conflict
    assert_equal "This source import can no longer be canceled.", response.parsed_body["error"]
    assert SourceImport.exists?(consumed.id)
  end

  private

  def assert_no_workspace_records_created
    counts_before = [ Project.count, Document.count, Experiment.count, TranslationRun.count ]
    yield
    assert_equal counts_before, [ Project.count, Document.count, Experiment.count, TranslationRun.count ]
  end

  def workspace_attributes
    {
      project_name: "Document imports",
      source_language: "Vietnamese",
      target_language: "Japanese",
      document_title: "Imported sermon",
      source_text: "Imported source",
      experiment_name: "Secure import",
      instruction_prompt: "Translate faithfully.",
      model_ids: [ @model.id ],
      submission_token: issue_translation_workspace_token
    }
  end

  def consume_import(source_import)
    workspace = TranslationWorkspace.new(
      workspace_attributes.merge(
        user: users(:normal),
        source_import:,
        source_import_id: source_import.id,
        source_import_project_token: source_import_binding(source_import)
      )
    )
    assert workspace.submit
    workspace.document
  end
end
