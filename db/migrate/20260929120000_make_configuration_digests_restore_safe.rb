# pg_dump sets an empty search_path for the whole restore, and COPY evaluates
# the payload digest CHECK constraints while loading rows. The original bodies
# called pgcrypto's unqualified digest(), which then cannot be resolved, so a
# real pg_restore of any database containing methodology or reference revisions
# failed. The replacements hash with the built-in pg_catalog.sha256, which is
# always resolvable and independent of where (or whether) pgcrypto is installed,
# and qualify every table they read.
#
# sha256(convert_to(text, 'UTF8')) hashes exactly the bytes digest(text,
# 'sha256') hashed in this UTF-8 database, and the bytes the Ruby digests hash,
# so existing digests remain valid. up re-verifies every stored digest before
# committing because replacing a function does not re-run CHECK constraints.
class MakeConfigurationDigestsRestoreSafe < ActiveRecord::Migration[8.1]
  def up
    execute <<~SQL
      CREATE OR REPLACE FUNCTION public.methodology_revision_configuration_digest(
        source_language text, target_language text, guidance text
      ) RETURNS text
        LANGUAGE sql IMMUTABLE STRICT
        AS $$
        SELECT pg_catalog.encode(pg_catalog.sha256(pg_catalog.convert_to(
          '{"source_language":' || pg_catalog.to_json(source_language)::text ||
          ',"target_language":' || pg_catalog.to_json(target_language)::text ||
          ',"guidance":' || pg_catalog.to_json(guidance)::text || '}',
          'UTF8'
        )), 'hex');
      $$;

      CREATE OR REPLACE FUNCTION public.translation_reference_revision_configuration_digest(
        source_language text, target_language text, source_text text, approved_translation text
      ) RETURNS text
        LANGUAGE sql IMMUTABLE STRICT
        AS $$
        SELECT pg_catalog.encode(pg_catalog.sha256(pg_catalog.convert_to(
          '{"source_language":' || pg_catalog.to_json(source_language)::text ||
          ',"target_language":' || pg_catalog.to_json(target_language)::text ||
          ',"source_text":' || pg_catalog.to_json(source_text)::text ||
          ',"approved_translation":' || pg_catalog.to_json(approved_translation)::text || '}',
          'UTF8'
        )), 'hex');
      $$;

      CREATE OR REPLACE FUNCTION public.glossary_revision_configuration_digest(revision_id bigint) RETURNS text
        LANGUAGE sql STABLE
        AS $$
        SELECT pg_catalog.encode(pg_catalog.sha256(pg_catalog.convert_to(
          '{"source_language":' || pg_catalog.to_json(glossary_revisions.source_language)::text ||
          ',"target_language":' || pg_catalog.to_json(glossary_revisions.target_language)::text ||
          ',"entries":[' || COALESCE((
            SELECT pg_catalog.string_agg(
              '{"position":' || glossary_entries.position ||
              ',"source_term":' || pg_catalog.to_json(glossary_entries.source_term)::text ||
              ',"preferred_target_term":' || pg_catalog.to_json(glossary_entries.preferred_target_term)::text ||
              ',"note":' || COALESCE(pg_catalog.to_json(glossary_entries.note)::text, 'null') || '}',
              ',' ORDER BY glossary_entries.position
            )
            FROM public.glossary_entries
            WHERE glossary_entries.glossary_revision_id = glossary_revisions.id
          ), '') || ']}',
          'UTF8'
        )), 'hex')
        FROM public.glossary_revisions
        WHERE glossary_revisions.id = revision_id;
      $$;
    SQL

    verify_stored_digests!
  end

  def down
    execute <<~SQL
      CREATE OR REPLACE FUNCTION public.methodology_revision_configuration_digest(
        source_language text, target_language text, guidance text
      ) RETURNS text
        LANGUAGE sql IMMUTABLE STRICT
        AS $$
        SELECT encode(digest(
          '{"source_language":' || to_json(source_language)::text ||
          ',"target_language":' || to_json(target_language)::text ||
          ',"guidance":' || to_json(guidance)::text || '}',
          'sha256'
        ), 'hex');
      $$;

      CREATE OR REPLACE FUNCTION public.translation_reference_revision_configuration_digest(
        source_language text, target_language text, source_text text, approved_translation text
      ) RETURNS text
        LANGUAGE sql IMMUTABLE STRICT
        AS $$
        SELECT encode(digest(
          '{"source_language":' || to_json(source_language)::text ||
          ',"target_language":' || to_json(target_language)::text ||
          ',"source_text":' || to_json(source_text)::text ||
          ',"approved_translation":' || to_json(approved_translation)::text || '}',
          'sha256'
        ), 'hex');
      $$;

      CREATE OR REPLACE FUNCTION public.glossary_revision_configuration_digest(revision_id bigint) RETURNS text
        LANGUAGE sql STABLE
        AS $$
        SELECT encode(digest(
          '{"source_language":' || to_json(glossary_revisions.source_language)::text ||
          ',"target_language":' || to_json(glossary_revisions.target_language)::text ||
          ',"entries":[' || COALESCE((
            SELECT string_agg(
              '{"position":' || position ||
              ',"source_term":' || to_json(source_term)::text ||
              ',"preferred_target_term":' || to_json(preferred_target_term)::text ||
              ',"note":' || COALESCE(to_json(note)::text, 'null') || '}',
              ',' ORDER BY position
            )
            FROM glossary_entries
            WHERE glossary_revision_id = glossary_revisions.id
          ), '') || ']}',
          'sha256'
        ), 'hex')
        FROM glossary_revisions
        WHERE id = revision_id;
      $$;
    SQL
  end

  private

  def verify_stored_digests!
    mismatched = select_value(<<~SQL)
      SELECT
        (SELECT count(*) FROM public.methodology_profile_revisions
          WHERE configuration_digest <> public.methodology_revision_configuration_digest(
            source_language, target_language, guidance)) +
        (SELECT count(*) FROM public.translation_reference_revisions
          WHERE configuration_digest <> public.translation_reference_revision_configuration_digest(
            source_language, target_language, source_text, approved_translation)) +
        (SELECT count(*) FROM public.glossary_revisions
          WHERE configuration_digest <> public.glossary_revision_configuration_digest(id))
    SQL
    return if Integer(mismatched).zero?

    raise ActiveRecord::MigrationError,
          "#{mismatched} stored configuration digests would no longer match; migration aborted without changes"
  end
end
