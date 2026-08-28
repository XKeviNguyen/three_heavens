# Be sure to restart your server when you modify this file.

# Configure parameters to be partially matched (e.g. passw matches password) and filtered from the log file.
# Use this to limit dissemination of sensitive information.
# See the ActiveSupport::ParameterFilter documentation for supported notations and behaviors.
Rails.application.config.filter_parameters += [
  :passw, :email, :secret, :token, :_key, :crypt, :salt, :certificate, :otp, :ssn, :cvv, :cvc,
  :source_text, :extracted_text, :preview_text, :source_file, :instruction_prompt,
  :translated_text, :translation_text, :suggested_translation, :proposed_translation,
  "final_translation.content", "final_translation.change_note"
]
