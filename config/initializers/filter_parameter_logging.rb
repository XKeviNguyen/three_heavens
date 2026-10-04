# Be sure to restart your server when you modify this file.

# Configure parameters to be partially matched (e.g. passw matches password) and filtered from the log file.
# Use this to limit dissemination of sensitive information.
# See the ActiveSupport::ParameterFilter documentation for supported notations and behaviors.
Rails.application.config.filter_parameters += [
  :passw, :email, :secret, :token, :_key, :crypt, :salt, :certificate, :otp, :ssn, :cvv, :cvc, :credential, :return_to,
  :source_text, :extracted_text, :preview_text, :source_file, :instruction_prompt,
  :translated_text, :translation_text, :suggested_translation, :proposed_translation,
  :approved_translation, :approved_translation_file, :reference_source_text,
  "methodology_profile.guidance", :source_term, :preferred_target_term, "glossary.entries.note",
  "final_translation.content", "final_translation.change_note", :workspace_payload, :workspace,
  # Parameters are logged before authentication, so any other long value
  # (an unknown field in a signed-out request, for example) is truncated
  # rather than written to the log in full.
  ->(_key, value) { value.replace("#{value[0, 200]}[TRUNCATED]") if value.is_a?(String) && value.length > 200 }
]
