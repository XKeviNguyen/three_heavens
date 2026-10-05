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

  # Each ordinary POST is an intentional new action. Replay tests supply
  # their own stable key and use post directly.
  def post_new_reference(path, params:, **options)
    submitted = params[:translation_reference]
    if submitted.is_a?(Hash)
      params = params.merge(translation_reference: { creation_key: SecureRandom.hex(16) }.merge(submitted))
    end
    post path, params: params, **options
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
