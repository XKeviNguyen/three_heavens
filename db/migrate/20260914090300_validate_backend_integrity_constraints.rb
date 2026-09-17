class ValidateBackendIntegrityConstraints < ActiveRecord::Migration[8.1]
  def up
    validate_check_constraint :final_translation_versions,
                              name: "final_translation_versions_source_origin_check"

    %w[
      ai_provider_attempts_gateway_snapshot_check
      ai_provider_attempts_provider_snapshot_check
      ai_provider_attempts_identifier_snapshot_check
      ai_provider_attempts_display_name_snapshot_check
      ai_provider_attempts_error_code_format_check
      ai_provider_attempts_token_consistency_check
    ].each do |name|
      validate_check_constraint :ai_provider_attempts, name: name
    end
  end

  def down
  end
end
