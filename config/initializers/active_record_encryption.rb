# Use independent Rails Active Record Encryption keys derived from the stable
# secret_key_base. Re-encrypt active drafts before rotating that root secret.
key_generator = Rails.application.key_generator
encryption = Rails.application.config.active_record.encryption
encryption.primary_key = key_generator.generate_key("translation_workspace_drafts/primary", 32).unpack1("H*")
encryption.deterministic_key = key_generator.generate_key("translation_workspace_drafts/deterministic", 32).unpack1("H*")
encryption.key_derivation_salt = key_generator.generate_key("translation_workspace_drafts/salt", 32).unpack1("H*")
