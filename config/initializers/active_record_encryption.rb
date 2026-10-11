# Use independent Rails Active Record Encryption keys derived from the stable
# secret_key_base. The labels are historical: these keys protect every
# encrypted attribute (workspace drafts, reference recovery failures, and
# users' OpenRouter API keys). Re-encrypt them before rotating that root
# secret; an OpenRouter key that can no longer be decrypted fails its owner's
# AI work closed (never falling back to the platform key) until replaced.
key_generator = Rails.application.key_generator
encryption = Rails.application.config.active_record.encryption
encryption.primary_key = key_generator.generate_key("translation_workspace_drafts/primary", 32).unpack1("H*")
encryption.deterministic_key = key_generator.generate_key("translation_workspace_drafts/deterministic", 32).unpack1("H*")
encryption.key_derivation_salt = key_generator.generate_key("translation_workspace_drafts/salt", 32).unpack1("H*")
