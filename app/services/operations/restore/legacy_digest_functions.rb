require "pg"

module Operations
  module Restore
    # Bundles created before migration 20260929120000 define the payload digest
    # functions with pgcrypto's unqualified digest(). pg_restore loads data with
    # an empty search_path, so COPY cannot evaluate the CHECK constraints that
    # call them and such a bundle cannot be restored. Verification restores the
    # schema section first and then installs that migration's corrected
    # definitions, which produce identical digests, before loading data. Only
    # bodies that still call the unqualified digest() are replaced; any other
    # definition is left as restored.
    class LegacyDigestFunctions
      LEGACY_BODY_MARKER = "encode(digest("
      LEGACY_FUNCTION_SQL = <<~SQL.squish.freeze
        SELECT 1 FROM pg_catalog.pg_proc
        WHERE oid = pg_catalog.to_regprocedure($1) AND pg_catalog.strpos(prosrc, $2) > 0
      SQL
      DEFINITIONS = {
        "public.methodology_revision_configuration_digest(text,text,text)" => <<~SQL,
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
        SQL
        "public.translation_reference_revision_configuration_digest(text,text,text,text)" => <<~SQL,
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
        SQL
        "public.glossary_revision_configuration_digest(bigint)" => <<~SQL
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
      }.freeze

      def self.call(database_url, connector: PG)
        connection = connector.connect(database_url)
        upgrade!(connection)
      ensure
        connection&.close
      end

      # Returns how many legacy definitions were replaced.
      def self.upgrade!(connection)
        DEFINITIONS.count do |signature, definition|
          next false if connection.exec_params(LEGACY_FUNCTION_SQL, [ signature, LEGACY_BODY_MARKER ]).ntuples.zero?

          connection.exec(definition)
          true
        end
      end
    end
  end
end
