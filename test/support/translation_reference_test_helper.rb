module TranslationReferenceTestHelper
  def translation_reference_attributes(
    title: "Sabbath study",
    source_language: "Vietnamese",
    target_language: "Japanese",
    source_text: "Nguồn thứ nhất.\n\n  Dòng giữ thụt lề.",
    approved_translation: "承認された翻訳。\n\n  字下げを保持します。"
  )
    {
      title: title,
      source_language: source_language,
      target_language: target_language,
      source_text: source_text,
      approved_translation: approved_translation
    }
  end

  def create_translation_reference(user: users(:normal), **attributes)
    TranslationReferences::Create.call(
      user: user,
      attributes: translation_reference_attributes(**attributes)
    )
  end

  def snapshot_reference(experiment:, revision:, position: 1)
    experiment.experiment_reference_revisions.create!(
      translation_reference_revision: revision,
      position: position
    )
  end
end
