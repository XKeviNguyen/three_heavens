require "test_helper"
require_relative "../support/translation_reference_test_helper"

class TranslationReferenceTest < ActiveSupport::TestCase
  include TranslationReferenceTestHelper

  test "creation preserves meaningful formatting and computes behavior-only digest" do
    reference = create_translation_reference(
      title: "  Sabbath study  ",
      source_language: " Vietnamese ",
      target_language: " Japanese ",
      source_text: "\nNguồn。\n  Giữ thụt lề.\n\nCâu Kinh Thánh.  \n",
      approved_translation: "\n訳文。\n  字下げ。\n\n聖句。  \n"
    )
    revision = reference.current_revision

    assert_equal "Sabbath study", revision.title
    assert_equal "Vietnamese", revision.source_language
    assert_equal "Japanese", revision.target_language
    assert_equal "Nguồn。\n  Giữ thụt lề.\n\nCâu Kinh Thánh.", revision.source_text
    assert_equal "訳文。\n  字下げ。\n\n聖句。", revision.approved_translation
    assert_equal TranslationReferences::ConfigurationDigest.call(revision), revision.configuration_digest

    renamed = reference.revisions.build(
      version: 2,
      **translation_reference_attributes(title: "Cosmetic title").except(:title).merge(title: "Cosmetic title")
    )
    renamed.source_language = revision.source_language
    renamed.target_language = revision.target_language
    renamed.source_text = revision.source_text
    renamed.approved_translation = revision.approved_translation
    renamed.valid?
    assert_equal revision.configuration_digest, renamed.configuration_digest
  end

  test "revision is immutable in Rails and PostgreSQL and forged digests are rejected" do
    reference = create_translation_reference
    revision = reference.current_revision

    assert_not revision.update(source_text: "Changed")
    assert_includes revision.errors[:base], "Translation reference revisions are immutable"
    assert_not revision.destroy

    assert_database_rejects do
      TranslationReferenceRevision.where(id: revision.id).update_all(source_text: "Callback bypass")
    end
    assert_database_rejects do
      TranslationReferenceRevision.insert_all!([ {
        translation_reference_id: reference.id,
        version: 2,
        title: "Forged",
        source_language: "Vietnamese",
        target_language: "Japanese",
        source_text: "Different",
        approved_translation: "異なる",
        configuration_digest: "0" * 64,
        created_at: Time.current,
        updated_at: Time.current
      } ])
    end
    assert_equal 1, reference.revisions.count
  end

  test "editing creates an atomic revision and stale edits are rejected" do
    reference = create_translation_reference
    first = reference.current_revision
    second = TranslationReferences::Revise.call(
      translation_reference: reference,
      expected_version: "1",
      attributes: translation_reference_attributes(approved_translation: "第二版")
    )

    assert_equal 2, second.version
    assert_equal first, reference.revisions.find_by!(version: 1)
    assert_equal "第二版", reference.reload.approved_translation
    assert_raises TranslationReferences::Revise::StaleRevisionError do
      TranslationReferences::Revise.call(
        translation_reference: reference,
        expected_version: "1",
        attributes: translation_reference_attributes(approved_translation: "Stale")
      )
    end
    assert_equal 2, reference.revisions.count
  end

  test "archive and reactivation preserve an exact historical experiment snapshot" do
    reference = create_translation_reference
    revision = reference.current_revision
    project = users(:normal).projects.create!(
      name: "Reference project",
      source_language: " vietnamese ",
      target_language: "JAPANESE"
    )
    experiment = project.documents.create!(title: "Source", source_text: "Source").experiments.create!(
      instruction_prompt: "Translate.",
      guidance_preference: :reference_examples
    )
    snapshot = snapshot_reference(experiment: experiment, revision: revision)

    TranslationReferences::ChangeStatus.deactivate(translation_reference: reference)
    assert_not reference.reload.active?
    assert_equal revision, experiment.reload.translation_reference_revisions.sole
    TranslationReferences::ChangeStatus.activate(translation_reference: reference)
    assert reference.reload.active?
    assert_not reference.destroy
    assert_not snapshot.destroy
    assert_database_rejects { ExperimentReferenceRevision.where(id: snapshot.id).delete_all }
  end

  test "database rejects owner language and parent mutations that violate snapshots" do
    reference = create_translation_reference
    project = users(:normal).projects.create!(
      name: "Protected reference project",
      source_language: "Vietnamese",
      target_language: "Japanese"
    )
    document = project.documents.create!(title: "Source", source_text: "Source")
    experiment = document.experiments.create!(instruction_prompt: "Translate.")
    snapshot_reference(experiment: experiment, revision: reference.current_revision)
    other_project = users(:other).projects.create!(
      name: "Other",
      source_language: "Vietnamese",
      target_language: "Japanese"
    )
    other_document = other_project.documents.create!(title: "Other", source_text: "Source")

    assert_database_rejects { Project.where(id: project.id).update_all(target_language: "English") }
    assert_database_rejects { Project.where(id: project.id).update_all(user_id: users(:other).id) }
    assert_database_rejects { Document.where(id: document.id).update_all(project_id: other_project.id) }
    assert_database_rejects { Experiment.where(id: experiment.id).update_all(document_id: other_document.id) }
    assert_database_rejects { TranslationReference.where(id: reference.id).update_all(user_id: users(:other).id) }
  end

  test "database snapshot language comparisons match Rails whitespace and case normalization on every path" do
    reference = create_translation_reference
    [ "\t", "\n", "\v", "\f", "\r", " ", " \t\n\v\f\r" ].each do |whitespace|
      project = users(:normal).projects.create!(
        name: "Whitespace languages", source_language: "Vietnamese", target_language: "Japanese"
      )
      languages = { source_language: "#{whitespace}vIeTnAmEsE#{whitespace}",
                    target_language: "#{whitespace}jApAnEsE#{whitespace}" }
      Project.where(id: project.id).update_all(languages)
      project.reload
      assert TranslationLanguagePair.matches?(reference.current_revision, **languages)
      document = project.documents.create!(title: "Source", source_text: "Source")
      experiment = document.experiments.create!(instruction_prompt: "Translate.")
      snapshot_reference(experiment: experiment, revision: reference.current_revision)
      Project.where(id: project.id).update_all(languages)
      other_document = project.documents.create!(title: "Other source", source_text: "Source")
      Experiment.where(id: experiment.id).update_all(document_id: other_document.id)
      other_project = users(:normal).projects.create!(name: "Other project", **languages)
      Project.where(id: other_project.id).update_all(languages)
      Document.where(id: other_document.id).update_all(project_id: other_project.id)
      assert_equal reference.current_revision, experiment.reload.translation_reference_revisions.sole
    end
  end

  test "reference snapshots are sealed before provider work in Rails and PostgreSQL" do
    reference = create_translation_reference
    project = users(:normal).projects.create!(
      name: "Sealed reference project",
      source_language: "Vietnamese",
      target_language: "Japanese"
    )
    experiment = project.documents.create!(title: "Source", source_text: "Source").experiments.create!(
      instruction_prompt: "Translate."
    )
    experiment.translation_runs.create!(llm_model: llm_models(:openrouter_claude))

    snapshot = experiment.experiment_reference_revisions.build(
      translation_reference_revision: reference.current_revision,
      position: 1
    )
    assert_not snapshot.save
    assert_includes snapshot.errors[:experiment], "reference snapshots must be selected before provider work starts"
    assert_database_rejects do
      ExperimentReferenceRevision.insert_all!([ {
        experiment_id: experiment.id,
        translation_reference_revision_id: reference.current_revision.id,
        position: 1,
        created_at: Time.current,
        updated_at: Time.current
      } ])
    end
  end

  test "guidance preference defaults for new experiments accepts exact values and is immutable" do
    project = users(:normal).projects.create!(name: "Guidance", source_language: "vi", target_language: "ja")
    document = project.documents.create!(title: "Source", source_text: "Source")

    assert_equal "reference_examples", document.experiments.create!(instruction_prompt: "Translate").guidance_preference
    Experiment.guidance_preferences.each_key do |value|
      assert_equal value, document.experiments.create!(
        instruction_prompt: "Translate",
        guidance_preference: value
      ).guidance_preference
    end
    invalid = document.experiments.build(instruction_prompt: "Translate", guidance_preference: "unknown")
    assert_not invalid.valid?

    experiment = document.experiments.create!(
      instruction_prompt: "Translate",
      guidance_preference: :glossary
    )
    assert_not experiment.update(guidance_preference: :experiment_instruction)
    assert_database_rejects do
      Experiment.where(id: experiment.id).update_all(guidance_preference: "experiment_instruction")
    end
    assert_equal "glossary", experiment.reload.guidance_preference
  end

  private

  def assert_database_rejects
    assert_raises ActiveRecord::StatementInvalid do
      ActiveRecord::Base.transaction(requires_new: true) { yield }
    end
  end
end
