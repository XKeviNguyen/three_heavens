require "test_helper"
require_relative "../support/document_io_test_helper"
require_relative "../support/translation_reference_test_helper"

class TranslationReferencesTest < ActionDispatch::IntegrationTest
  include DocumentIoTestHelper
  include TranslationReferenceTestHelper

  setup { sign_in_as users(:normal) }

  test "owner creates a pasted pair revises archives and reactivates it" do
    assert_difference -> { TranslationReference.count }, 1 do
      assert_difference -> { TranslationReferenceRevision.count }, 1 do
        post translation_references_path, params: {
          translation_reference: translation_reference_attributes
        }
      end
    end
    reference = TranslationReference.order(:id).last
    assert_redirected_to translation_reference_path(reference)
    follow_redirect!
    assert_response :success
    assert_select "h1", text: "Sabbath study"
    assert_includes response.body, reference.current_revision.configuration_digest

    assert_difference -> { TranslationReferenceRevision.count }, 1 do
      patch translation_reference_path(reference), params: {
        translation_reference: translation_reference_attributes(
          title: "Sabbath study revised",
          approved_translation: "改訂された承認訳"
        ).merge(expected_version: "1")
      }
    end
    assert_equal 2, reference.reload.current_revision.version

    patch deactivate_translation_reference_path(reference)
    assert_not reference.reload.active?
    patch activate_translation_reference_path(reference)
    assert reference.reload.active?
  end

  test "TXT MD and DOCX uploads use the shared extraction path on either side" do
    cases = [
      [ "source.txt", "TXT source", "approved.md", "# Approved" ],
      [ "source.md", "# Source", "approved.txt", "Approved text" ],
      [ "source.docx", build_docx(document_xml: basic_document_xml("<w:p><w:r><w:t>DOCX source</w:t></w:r></w:p>")),
        "approved.docx", build_docx(document_xml: basic_document_xml("<w:p><w:r><w:t>DOCX approved</w:t></w:r></w:p>")) ]
    ]

    cases.each_with_index do |(source_name, source_bytes, approved_name, approved_bytes), index|
      post translation_references_path, params: {
        translation_reference: {
          title: "Uploaded #{index}",
          source_language: "Vietnamese",
          target_language: "Japanese",
          source_file: uploaded_file(source_bytes, filename: source_name),
          approved_translation_file: uploaded_file(approved_bytes, filename: approved_name)
        }
      }
      assert_response :redirect
    end

    revisions = TranslationReference.order(:id).last(3).map(&:current_revision)
    assert_equal "TXT source", revisions[0].source_text
    assert_equal "# Approved", revisions[0].approved_translation
    assert_equal "# Source", revisions[1].source_text
    assert_equal "Approved text", revisions[1].approved_translation
    assert_equal "DOCX source", revisions[2].source_text
    assert_equal "DOCX approved", revisions[2].approved_translation
  end

  test "text PDF uploads extract both reference sides without provider work" do
    assert_no_difference "AiProviderAttempt.count" do
      post translation_references_path, params: {
        translation_reference: {
          title: "PDF reference",
          source_language: "Vietnamese",
          target_language: "Japanese",
          source_file: uploaded_file(pdf_with_text("PDF source example"), filename: "source.pdf", content_type: "application/pdf"),
          approved_translation_file: uploaded_file(pdf_with_text("PDF approved example"), filename: "approved.pdf", content_type: "application/pdf")
        }
      }
    end
    assert_response :redirect
    revision = TranslationReference.order(:id).last.current_revision
    assert_equal "PDF source example", revision.source_text
    assert_equal "PDF approved example", revision.approved_translation
  end

  test "an individually oversized file is rejected below the global two-file request ceiling" do
    oversized = "a" * (SourceImports::Limits::MAX_UPLOAD_BYTES + 1)

    assert_no_difference -> { TranslationReference.count } do
      post translation_references_path, params: {
        translation_reference: {
          title: "Oversized source",
          source_language: "Vietnamese",
          target_language: "Japanese",
          source_file: uploaded_file(oversized, filename: "oversized.txt", content_type: "text/plain"),
          approved_translation: "Approved"
        }
      }
    end

    assert_response :unprocessable_content
    assert_includes response.body, "10 MiB limit"
  end

  test "ambiguous paste plus file and unsafe DOCX are rejected without AI work" do
    macro_docx = build_docx(entries: { "word/vbaProject.bin" => "macro" })

    assert_no_difference [
      -> { TranslationReference.count },
      -> { TranslationRun.count },
      -> { ActiveJob::Base.queue_adapter.enqueued_jobs.size }
    ] do
      post translation_references_path, params: {
        translation_reference: translation_reference_attributes.merge(
          source_file: uploaded_file("uploaded source", filename: "source.txt", content_type: "text/plain")
        )
      }
    end
    assert_response :unprocessable_content
    assert_includes response.body, "not both"

    assert_no_difference [ -> { TranslationReference.count }, -> { TranslationRun.count } ] do
      post translation_references_path, params: {
        translation_reference: {
          title: "Unsafe",
          source_language: "Vietnamese",
          target_language: "Japanese",
          source_file: uploaded_file(macro_docx, filename: "source.docx"),
          approved_translation: "Approved"
        }
      }
    end
    assert_response :unprocessable_content
    assert_includes response.body, "Macro-enabled Word documents are not supported"
  end

  test "stale editing exposes current content strict parameters owner isolation and admin no-bypass fail closed" do
    reference = create_translation_reference

    TranslationReferences::Revise.call(
      translation_reference: reference,
      expected_version: "1",
      attributes: translation_reference_attributes(
        title: "Current saved title",
        source_language: "English",
        target_language: "French",
        source_text: "Current source from another editor",
        approved_translation: "Current translation from another editor"
      )
    )

    patch translation_reference_path(reference), params: {
      translation_reference: translation_reference_attributes.merge(expected_version: "1")
    }
    assert_response :conflict
    assert_select "input[name='translation_reference[expected_version]'][value='2']"
    assert_includes response.body, "Current source from another editor"
    assert_includes response.body, "Current translation from another editor"
    assert_select "section[aria-labelledby='reference-conflict-heading']" do
      [ "Current saved title", "English", "French", "2" ].each do |value|
        assert_select "dd", text: value
      end
    end
    translation_reference_attributes.slice(:title, :source_language, :target_language).each do |key, value|
      assert_select "input[name='translation_reference[#{key}]'][value=?]", value
    end
    translation_reference_attributes.slice(:source_text, :approved_translation).each do |key, value|
      assert_select "textarea[name='translation_reference[#{key}]']", text: value
    end
    assert_equal 2, reference.revisions.count

    patch translation_reference_path(reference), params: {
      translation_reference: translation_reference_attributes(
        source_text: "Manually merged source",
        approved_translation: "Manually merged translation"
      ).merge(expected_version: "2")
    }
    assert_response :redirect
    assert_equal 3, reference.reload.revisions.count

    [
      { translation_reference: "bad" },
      { translation_reference: translation_reference_attributes.merge(user_id: users(:other).id) },
      { translation_reference: translation_reference_attributes.merge(source_text: [ "bad" ]) }
    ].each do |payload|
      assert_no_difference -> { TranslationReference.count } do
        post translation_references_path, params: payload
      end
      assert_response :bad_request
    end

    sign_out
    sign_in_as users(:other)
    get translation_reference_path(reference)
    assert_response :not_found
    get edit_translation_reference_path(reference)
    assert_response :not_found

    sign_out
    sign_in_as users(:admin)
    get translation_reference_path(reference)
    assert_response :not_found
    patch translation_reference_path(reference), params: {
      translation_reference: translation_reference_attributes.merge(expected_version: "3")
    }
    assert_response :not_found
  end

  test "an edit upload replaces unchanged prefilled text while edited paste plus file remains ambiguous" do
    reference = create_translation_reference
    revision = reference.current_revision

    patch translation_reference_path(reference), params: {
      translation_reference: translation_reference_attributes.merge(
        source_text: revision.source_text,
        approved_translation: revision.approved_translation,
        source_file: uploaded_file("Replacement source", filename: "replacement.txt"),
        expected_version: revision.version.to_s
      )
    }
    assert_response :redirect
    assert_equal "Replacement source", reference.reload.current_revision.source_text

    patch translation_reference_path(reference), params: {
      translation_reference: translation_reference_attributes(
        source_text: "An intentional different paste",
        approved_translation: reference.current_revision.approved_translation
      ).merge(
        source_file: uploaded_file("Another replacement", filename: "another.txt"),
        expected_version: reference.current_revision.version.to_s
      )
    }
    assert_response :unprocessable_content
    assert_includes response.body, "not both"
  end

  %i[source_text approved_translation].each do |side|
    test "#{side} replacement upload survives a validation error and corrected resubmission" do
      reference = create_translation_reference
      file_key = side == :source_text ? :source_file : :approved_translation_file
      submitted = translation_reference_attributes(title: "").merge(
        file_key => uploaded_file("Desired replacement", filename: "replacement.txt"),
        expected_version: "1"
      )

      assert_no_difference -> { TranslationReferenceRevision.count } do
        patch translation_reference_path(reference), params: { translation_reference: submitted }
      end
      assert_response :unprocessable_content
      assert_select "textarea[name='translation_reference[#{side}]']", text: "Desired replacement"
      assert_select "input[name='translation_reference[expected_version]'][value='1']"
      assert_select "input[name='translation_reference[title]'][value='']"

      patch translation_reference_path(reference), params: {
        translation_reference: translation_reference_attributes(title: "Corrected title").merge(
          side => "Desired replacement", expected_version: "1"
        )
      }
      assert_response :redirect
      assert_equal 2, reference.reload.current_revision.version
      assert_equal "Desired replacement", reference.current_revision.public_send(side)
    end

    test "a valid #{side} replacement survives failure to extract the opposite upload" do
      reference = create_translation_reference
      other_side = side == :source_text ? :approved_translation : :source_text
      file_keys = { source_text: :source_file, approved_translation: :approved_translation_file }
      submitted = translation_reference_attributes.merge(
        file_keys.fetch(side) => uploaded_file("Successful replacement", filename: "valid.txt"),
        file_keys.fetch(other_side) => uploaded_file("PK\x03\x04garbage".b, filename: "invalid.docx"),
        expected_version: "1"
      )

      assert_no_difference -> { TranslationReferenceRevision.count } do
        patch translation_reference_path(reference), params: { translation_reference: submitted }
      end
      assert_response :unprocessable_content
      assert_select "textarea[name='translation_reference[#{side}]']", text: "Successful replacement"
      assert_select "textarea[name='translation_reference[#{other_side}]']", text: ""
      assert_select "input[name='translation_reference[expected_version]'][value='1']"

      patch translation_reference_path(reference), params: {
        translation_reference: translation_reference_attributes.merge(
          side => "Successful replacement", other_side => "",
          file_keys.fetch(other_side) => uploaded_file("Corrected opposite side", filename: "fixed.txt"),
          expected_version: "1"
        )
      }
      assert_response :redirect
      assert_equal 2, reference.reload.current_revision.version
      assert_equal "Successful replacement", reference.current_revision.public_send(side)
      assert_equal "Corrected opposite side", reference.current_revision.public_send(other_side)
    end

    test "new #{side} upload survives a validation error" do
      file_key = side == :source_text ? :source_file : :approved_translation_file
      submitted = translation_reference_attributes(title: "").except(side).merge(
        file_key => uploaded_file("Desired new content", filename: "new.txt")
      )
      assert_no_difference -> { TranslationReference.count } do
        post translation_references_path, params: { translation_reference: submitted }
      end
      assert_response :unprocessable_content
      assert_select "textarea[name='translation_reference[#{side}]']", text: "Desired new content"
    end
  end

  %i[source_text approved_translation].each do |side|
    test "a stale #{side} replacement upload preserves extracted content in the conflict form" do
      reference = create_translation_reference
      original = reference.current_revision
      TranslationReferences::Revise.call(
        translation_reference: reference,
        expected_version: original.version.to_s,
        attributes: translation_reference_attributes(
          source_text: "Current source from another editor",
          approved_translation: "Current translation from another editor"
        )
      )

      patch translation_reference_path(reference), params: {
        translation_reference: translation_reference_attributes(
          source_text: original.source_text,
          approved_translation: original.approved_translation
        ).merge(
          "#{side == :source_text ? :source : :approved_translation}_file" => uploaded_file("Uploaded stale replacement", filename: "replacement.txt"),
          expected_version: original.version.to_s
        )
      }

      assert_response :conflict
      assert_select "input[name='translation_reference[expected_version]'][value='2']"
      assert_includes response.body, "Current source from another editor"
      assert_select "textarea[name='translation_reference[#{side}]']", text: "Uploaded stale replacement"
      assert_equal 2, reference.reload.current_revision.version
    end
  end
end
