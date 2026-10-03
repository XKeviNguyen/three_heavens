SET statement_timeout = 0;
SET lock_timeout = 0;
SET idle_in_transaction_session_timeout = 0;
SET transaction_timeout = 0;
SET client_encoding = 'UTF8';
SET standard_conforming_strings = on;
SELECT pg_catalog.set_config('search_path', '', false);
SET check_function_bodies = false;
SET xmloption = content;
SET client_min_messages = warning;
SET row_security = off;

--
-- Name: pgcrypto; Type: EXTENSION; Schema: -; Owner: -
--

CREATE EXTENSION IF NOT EXISTS pgcrypto WITH SCHEMA public;


--
-- Name: EXTENSION pgcrypto; Type: COMMENT; Schema: -; Owner: -
--

COMMENT ON EXTENSION pgcrypto IS 'cryptographic functions';


--
-- Name: enforce_document_glossary_owner(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.enforce_document_glossary_owner() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
BEGIN
  PERFORM pg_advisory_xact_lock(hashtextextended('document:' || NEW.id::text, 0));
  PERFORM pg_advisory_xact_lock(hashtextextended('project:' || NEW.project_id::text, 0));

  IF EXISTS (
    SELECT 1
    FROM experiments
    INNER JOIN glossary_revisions ON glossary_revisions.id = experiments.glossary_revision_id
    INNER JOIN glossaries ON glossaries.id = glossary_revisions.glossary_id
    INNER JOIN projects ON projects.id = NEW.project_id
    WHERE experiments.document_id = NEW.id
      AND glossaries.user_id <> projects.user_id
  ) THEN
    RAISE EXCEPTION 'Document project change would invalidate an experiment glossary revision'
      USING ERRCODE = 'check_violation';
  END IF;

  RETURN NEW;
END;
$$;


--
-- Name: enforce_document_methodology_snapshots(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.enforce_document_methodology_snapshots() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
BEGIN
  PERFORM pg_advisory_xact_lock(hashtextextended('document:' || NEW.id::text, 0));
  PERFORM pg_advisory_xact_lock(hashtextextended('project:' || NEW.project_id::text, 0));

  IF EXISTS (
    SELECT 1
    FROM experiments
    INNER JOIN methodology_profile_revisions
      ON methodology_profile_revisions.id = experiments.methodology_profile_revision_id
    INNER JOIN methodology_profiles
      ON methodology_profiles.id = methodology_profile_revisions.methodology_profile_id
    INNER JOIN projects ON projects.id = NEW.project_id
    WHERE experiments.document_id = NEW.id
      AND (
        methodology_profiles.user_id <> projects.user_id
        OR lower(btrim(methodology_profile_revisions.source_language)) <> lower(btrim(projects.source_language))
        OR lower(btrim(methodology_profile_revisions.target_language)) <> lower(btrim(projects.target_language))
      )
  ) THEN
    RAISE EXCEPTION 'Document project change would invalidate an experiment methodology revision'
      USING ERRCODE = 'check_violation';
  END IF;

  RETURN NEW;
END;
$$;


--
-- Name: enforce_document_reference_snapshots(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.enforce_document_reference_snapshots() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
BEGIN
  PERFORM pg_advisory_xact_lock(hashtextextended('document:' || NEW.id::text, 0));
  PERFORM pg_advisory_xact_lock(hashtextextended('project:' || NEW.project_id::text, 0));
  PERFORM pg_advisory_xact_lock(hashtextextended('translation_reference:' || reference_id::text, 0))
    FROM (
      SELECT DISTINCT revisions.translation_reference_id AS reference_id
      FROM experiment_reference_revisions snapshots
      JOIN translation_reference_revisions revisions ON revisions.id = snapshots.translation_reference_revision_id
      JOIN experiments ON experiments.id = snapshots.experiment_id

      WHERE experiments.document_id = NEW.id
      ORDER BY reference_id
    ) references_to_lock;

  IF EXISTS (
    SELECT 1
    FROM experiments
    INNER JOIN experiment_reference_revisions
      ON experiment_reference_revisions.experiment_id = experiments.id
    INNER JOIN translation_reference_revisions
      ON translation_reference_revisions.id = experiment_reference_revisions.translation_reference_revision_id
    INNER JOIN translation_references
      ON translation_references.id = translation_reference_revisions.translation_reference_id
    INNER JOIN projects ON projects.id = NEW.project_id
    WHERE experiments.document_id = NEW.id
      AND (
        translation_references.user_id <> projects.user_id
        OR lower(btrim(translation_reference_revisions.source_language, CHR(9) || CHR(10) || CHR(11) || CHR(12) || CHR(13) || ' ')) <> lower(btrim(projects.source_language, CHR(9) || CHR(10) || CHR(11) || CHR(12) || CHR(13) || ' '))
        OR lower(btrim(translation_reference_revisions.target_language, CHR(9) || CHR(10) || CHR(11) || CHR(12) || CHR(13) || ' ')) <> lower(btrim(projects.target_language, CHR(9) || CHR(10) || CHR(11) || CHR(12) || CHR(13) || ' '))
      )
  ) THEN
    RAISE EXCEPTION 'Document change would invalidate an experiment reference snapshot'
      USING ERRCODE = 'check_violation';
  END IF;

  RETURN NEW;
END;
$$;


--
-- Name: enforce_evaluation_lineage(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.enforce_evaluation_lineage() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
DECLARE
  parent_experiment_id bigint;
  candidate_experiment_id bigint;
BEGIN
  SELECT experiment_id INTO candidate_experiment_id FROM translation_runs WHERE id = NEW.translation_run_id;
  IF TG_TABLE_NAME = 'review_evaluations' THEN
    SELECT rounds.experiment_id INTO parent_experiment_id
      FROM review_runs runs JOIN review_rounds rounds ON rounds.id = runs.review_round_id
     WHERE runs.id = NEW.review_run_id;
  ELSE
    SELECT review_rounds.experiment_id INTO parent_experiment_id
      FROM judge_runs runs
      JOIN judge_rounds rounds ON rounds.id = runs.judge_round_id
      JOIN review_rounds ON review_rounds.id = rounds.review_round_id
     WHERE runs.id = NEW.judge_run_id;
  END IF;
  IF parent_experiment_id IS NULL OR candidate_experiment_id IS NULL OR parent_experiment_id <> candidate_experiment_id THEN
    RAISE EXCEPTION 'Evaluation candidate must belong to the reviewed experiment';
  END IF;
  RETURN NEW;
END;
$$;


--
-- Name: enforce_experiment_glossary_owner(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.enforce_experiment_glossary_owner() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
DECLARE
  project_id bigint;
  glossary_id bigint;
BEGIN
  IF NEW.glossary_revision_id IS NULL THEN
    RETURN NEW;
  END IF;

  PERFORM pg_advisory_xact_lock(hashtextextended('document:' || NEW.document_id::text, 0));
  SELECT documents.project_id INTO project_id FROM documents WHERE documents.id = NEW.document_id;
  PERFORM pg_advisory_xact_lock(hashtextextended('project:' || project_id::text, 0));
  SELECT glossary_revisions.glossary_id INTO glossary_id FROM glossary_revisions WHERE glossary_revisions.id = NEW.glossary_revision_id;
  PERFORM pg_advisory_xact_lock(hashtextextended('glossary:' || glossary_id::text, 0));

  IF NOT EXISTS (
    SELECT 1
    FROM documents
    INNER JOIN projects ON projects.id = documents.project_id
    INNER JOIN glossary_revisions ON glossary_revisions.id = NEW.glossary_revision_id
    INNER JOIN glossaries ON glossaries.id = glossary_revisions.glossary_id
    WHERE documents.id = NEW.document_id
      AND projects.user_id = glossaries.user_id
  ) THEN
    RAISE EXCEPTION 'Experiment glossary revision is not available for this project owner'
      USING ERRCODE = 'check_violation';
  END IF;

  RETURN NEW;
END;
$$;


--
-- Name: enforce_experiment_methodology_snapshot(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.enforce_experiment_methodology_snapshot() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
DECLARE
  project_id bigint;
  methodology_profile_id bigint;
BEGIN
  IF TG_OP = 'UPDATE'
     AND OLD.methodology_profile_revision_id IS DISTINCT FROM NEW.methodology_profile_revision_id THEN
    RAISE EXCEPTION 'Experiment methodology revision cannot change after creation'
      USING ERRCODE = 'check_violation';
  END IF;

  IF NEW.methodology_profile_revision_id IS NULL THEN
    RETURN NEW;
  END IF;

  PERFORM pg_advisory_xact_lock(hashtextextended('document:' || NEW.document_id::text, 0));
  SELECT documents.project_id INTO project_id FROM documents WHERE documents.id = NEW.document_id;
  PERFORM pg_advisory_xact_lock(hashtextextended('project:' || project_id::text, 0));
  SELECT methodology_profile_revisions.methodology_profile_id
    INTO methodology_profile_id
    FROM methodology_profile_revisions
    WHERE methodology_profile_revisions.id = NEW.methodology_profile_revision_id;
  PERFORM pg_advisory_xact_lock(hashtextextended('methodology:' || methodology_profile_id::text, 0));

  IF NOT EXISTS (
    SELECT 1
    FROM documents
    INNER JOIN projects ON projects.id = documents.project_id
    INNER JOIN methodology_profile_revisions
      ON methodology_profile_revisions.id = NEW.methodology_profile_revision_id
    INNER JOIN methodology_profiles
      ON methodology_profiles.id = methodology_profile_revisions.methodology_profile_id
    WHERE documents.id = NEW.document_id
      AND methodology_profiles.user_id = projects.user_id
      AND lower(btrim(methodology_profile_revisions.source_language)) = lower(btrim(projects.source_language))
      AND lower(btrim(methodology_profile_revisions.target_language)) = lower(btrim(projects.target_language))
  ) THEN
    RAISE EXCEPTION 'Experiment methodology revision is not available for this project and language pair'
      USING ERRCODE = 'check_violation';
  END IF;

  RETURN NEW;
END;
$$;


--
-- Name: enforce_experiment_reference_snapshots(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.enforce_experiment_reference_snapshots() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
DECLARE
  project_id bigint;
BEGIN
  -- UPDATE already owns the experiment row. Never request it after advisory locks.
  PERFORM pg_advisory_xact_lock(hashtextextended('document:' || NEW.document_id::text, 0));
  SELECT documents.project_id INTO project_id FROM documents WHERE id = NEW.document_id;
  PERFORM pg_advisory_xact_lock(hashtextextended('project:' || project_id::text, 0));
  PERFORM pg_advisory_xact_lock(hashtextextended('translation_reference:' || reference_id::text, 0))
    FROM (
      SELECT DISTINCT revisions.translation_reference_id AS reference_id
      FROM experiment_reference_revisions snapshots
      JOIN translation_reference_revisions revisions ON revisions.id = snapshots.translation_reference_revision_id
      WHERE snapshots.experiment_id = NEW.id
      ORDER BY reference_id
    ) references_to_lock;

  IF EXISTS (
    SELECT 1
    FROM experiment_reference_revisions
    INNER JOIN translation_reference_revisions
      ON translation_reference_revisions.id = experiment_reference_revisions.translation_reference_revision_id
    INNER JOIN translation_references
      ON translation_references.id = translation_reference_revisions.translation_reference_id
    INNER JOIN documents ON documents.id = NEW.document_id
    INNER JOIN projects ON projects.id = documents.project_id
    WHERE experiment_reference_revisions.experiment_id = NEW.id
      AND (
        translation_references.user_id <> projects.user_id
        OR lower(btrim(translation_reference_revisions.source_language, CHR(9) || CHR(10) || CHR(11) || CHR(12) || CHR(13) || ' ')) <> lower(btrim(projects.source_language, CHR(9) || CHR(10) || CHR(11) || CHR(12) || CHR(13) || ' '))
        OR lower(btrim(translation_reference_revisions.target_language, CHR(9) || CHR(10) || CHR(11) || CHR(12) || CHR(13) || ' ')) <> lower(btrim(projects.target_language, CHR(9) || CHR(10) || CHR(11) || CHR(12) || CHR(13) || ' '))
      )
  ) THEN
    RAISE EXCEPTION 'Experiment change would invalidate a reference snapshot'
      USING ERRCODE = 'check_violation';
  END IF;

  RETURN NEW;
END;
$$;


--
-- Name: enforce_final_version_lineage(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.enforce_final_version_lineage() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
DECLARE
  run_translation_id bigint;
BEGIN
  IF NEW.source_finalization_run_id IS NULL THEN RETURN NEW; END IF;
  SELECT rounds.final_translation_id INTO run_translation_id
    FROM finalization_runs runs
    JOIN finalization_rounds rounds ON rounds.id = runs.finalization_round_id
   WHERE runs.id = NEW.source_finalization_run_id;
  IF run_translation_id IS NULL OR run_translation_id <> NEW.final_translation_id THEN
    RAISE EXCEPTION 'Finalization source run must belong to the final translation';
  END IF;
  RETURN NEW;
END;
$$;


--
-- Name: enforce_final_version_sequence(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.enforce_final_version_sequence() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
DECLARE
  next_version integer;
BEGIN
  PERFORM 1 FROM final_translations WHERE id = NEW.final_translation_id FOR UPDATE;
  SELECT COALESCE(MAX(version_number), 0) + 1 INTO next_version
    FROM final_translation_versions
   WHERE final_translation_id = NEW.final_translation_id;
  IF NEW.version_number <> next_version THEN
    RAISE EXCEPTION 'Final translation version must be the next monotonic value';
  END IF;
  RETURN NEW;
END;
$$;


--
-- Name: enforce_glossary_entry_set_seal(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.enforce_glossary_entry_set_seal() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
DECLARE
  revision_id bigint;
BEGIN
  revision_id := CASE WHEN TG_OP = 'INSERT' THEN NEW.glossary_revision_id ELSE OLD.glossary_revision_id END;

  IF EXISTS (
    SELECT 1 FROM glossary_revisions WHERE id = revision_id AND entry_set_sealed
  ) THEN
    RAISE EXCEPTION 'Glossary entry sets are sealed'
      USING ERRCODE = 'check_violation';
  END IF;

  IF TG_OP = 'UPDATE' AND NEW.glossary_revision_id <> OLD.glossary_revision_id AND EXISTS (
    SELECT 1 FROM glossary_revisions WHERE id = NEW.glossary_revision_id AND entry_set_sealed
  ) THEN
    RAISE EXCEPTION 'Glossary entry sets are sealed'
      USING ERRCODE = 'check_violation';
  END IF;

  RETURN COALESCE(NEW, OLD);
END;
$$;


--
-- Name: enforce_glossary_owner(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.enforce_glossary_owner() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
BEGIN
  PERFORM pg_advisory_xact_lock(hashtextextended('glossary:' || NEW.id::text, 0));

  IF EXISTS (
    SELECT 1
    FROM glossary_revisions
    INNER JOIN experiments ON experiments.glossary_revision_id = glossary_revisions.id
    INNER JOIN documents ON documents.id = experiments.document_id
    INNER JOIN projects ON projects.id = documents.project_id
    WHERE glossary_revisions.glossary_id = NEW.id
      AND projects.user_id <> NEW.user_id
  ) THEN
    RAISE EXCEPTION 'Glossary ownership change would invalidate an experiment glossary revision'
      USING ERRCODE = 'check_violation';
  END IF;

  RETURN NEW;
END;
$$;


--
-- Name: enforce_judge_winner_lineage(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.enforce_judge_winner_lineage() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
DECLARE
  judged_experiment_id bigint;
  winner_experiment_id bigint;
BEGIN
  IF NEW.winner_translation_run_id IS NULL THEN RETURN NEW; END IF;
  IF NOT EXISTS (
    SELECT 1 FROM translation_runs
     WHERE id = NEW.winner_translation_run_id AND status = 'completed'
  ) THEN
    RAISE EXCEPTION 'Judge winner must be a completed translation';
  END IF;
  IF TG_TABLE_NAME = 'judge_rounds' THEN
    SELECT experiment_id INTO judged_experiment_id FROM review_rounds WHERE id = NEW.review_round_id;
    IF NOT EXISTS (
      SELECT 1
        FROM judge_evaluations evaluations
        JOIN judge_runs runs ON runs.id = evaluations.judge_run_id
       WHERE runs.judge_round_id = NEW.id
         AND evaluations.translation_run_id = NEW.winner_translation_run_id
    ) THEN
      RAISE EXCEPTION 'Judge round winner must be an evaluated candidate';
    END IF;
  ELSE
    SELECT reviews.experiment_id INTO judged_experiment_id
      FROM judge_rounds rounds
      JOIN review_rounds reviews ON reviews.id = rounds.review_round_id
     WHERE rounds.id = NEW.judge_round_id;
    IF NOT EXISTS (
      SELECT 1
        FROM judge_evaluations evaluations
       WHERE evaluations.judge_run_id = NEW.id
         AND evaluations.translation_run_id = NEW.winner_translation_run_id
         AND evaluations.rank = 1
         AND evaluations.overall_score IS NOT NULL
         AND BTRIM(evaluations.rationale) <> ''
         AND BTRIM(evaluations.strengths) <> ''
         AND BTRIM(evaluations.risks) <> ''
    ) THEN
      RAISE EXCEPTION 'Judge run winner must be its complete rank-one evaluation';
    END IF;
  END IF;
  SELECT experiment_id INTO winner_experiment_id
    FROM translation_runs WHERE id = NEW.winner_translation_run_id;
  IF judged_experiment_id IS NULL OR winner_experiment_id IS NULL OR judged_experiment_id <> winner_experiment_id THEN
    RAISE EXCEPTION 'Judge winner must belong to the judged experiment';
  END IF;
  RETURN NEW;
END;
$$;


--
-- Name: enforce_methodology_profile_owner(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.enforce_methodology_profile_owner() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
BEGIN
  PERFORM pg_advisory_xact_lock(hashtextextended('methodology:' || NEW.id::text, 0));

  IF EXISTS (
    SELECT 1
    FROM methodology_profile_revisions
    INNER JOIN experiments
      ON experiments.methodology_profile_revision_id = methodology_profile_revisions.id
    INNER JOIN documents ON documents.id = experiments.document_id
    INNER JOIN projects ON projects.id = documents.project_id
    WHERE methodology_profile_revisions.methodology_profile_id = NEW.id
      AND projects.user_id <> NEW.user_id
  ) THEN
    RAISE EXCEPTION 'Methodology ownership change would invalidate an experiment methodology revision'
      USING ERRCODE = 'check_violation';
  END IF;

  RETURN NEW;
END;
$$;


--
-- Name: enforce_new_experiment_reference_snapshot(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.enforce_new_experiment_reference_snapshot() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
DECLARE
  document_id bigint;
  reference_id bigint;
  project_id bigint;
BEGIN
  PERFORM 1 FROM experiments WHERE id = NEW.experiment_id FOR UPDATE;
  SELECT experiments.document_id INTO document_id FROM experiments WHERE id = NEW.experiment_id;
  PERFORM pg_advisory_xact_lock(hashtextextended('document:' || document_id::text, 0));
  SELECT documents.project_id INTO project_id FROM documents WHERE id = document_id;
  PERFORM pg_advisory_xact_lock(hashtextextended('project:' || project_id::text, 0));
  SELECT translation_reference_id INTO reference_id
    FROM translation_reference_revisions
    WHERE id = NEW.translation_reference_revision_id;
  PERFORM pg_advisory_xact_lock(hashtextextended('translation_reference:' || reference_id::text, 0));

  IF EXISTS (SELECT 1 FROM translation_runs WHERE experiment_id = NEW.experiment_id) THEN
    RAISE EXCEPTION 'Experiment reference snapshots must be selected before provider work starts'
      USING ERRCODE = 'check_violation';
  END IF;

  IF NOT EXISTS (
    SELECT 1
    FROM experiments
    INNER JOIN documents ON documents.id = experiments.document_id
    INNER JOIN projects ON projects.id = documents.project_id
    INNER JOIN translation_reference_revisions
      ON translation_reference_revisions.id = NEW.translation_reference_revision_id
    INNER JOIN translation_references
      ON translation_references.id = translation_reference_revisions.translation_reference_id
    WHERE experiments.id = NEW.experiment_id
      AND translation_references.user_id = projects.user_id
      AND translation_references.active
      AND translation_references.current_revision_id = translation_reference_revisions.id
      AND lower(btrim(translation_reference_revisions.source_language, CHR(9) || CHR(10) || CHR(11) || CHR(12) || CHR(13) || ' ')) = lower(btrim(projects.source_language, CHR(9) || CHR(10) || CHR(11) || CHR(12) || CHR(13) || ' '))
      AND lower(btrim(translation_reference_revisions.target_language, CHR(9) || CHR(10) || CHR(11) || CHR(12) || CHR(13) || ' ')) = lower(btrim(projects.target_language, CHR(9) || CHR(10) || CHR(11) || CHR(12) || CHR(13) || ' '))
  ) THEN
    RAISE EXCEPTION 'Translation reference revision is not available for this experiment'
      USING ERRCODE = 'check_violation';
  END IF;

  RETURN NEW;
END;
$$;


--
-- Name: enforce_owned_workflow_lineage(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.enforce_owned_workflow_lineage() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
DECLARE
  left_owner_id bigint;
  right_owner_id bigint;
BEGIN
  IF TG_TABLE_NAME = 'pipeline_runs' THEN
    SELECT projects.user_id INTO left_owner_id
      FROM experiments JOIN documents ON documents.id = experiments.document_id
      JOIN projects ON projects.id = documents.project_id
     WHERE experiments.id = NEW.experiment_id;
    SELECT profiles.user_id INTO right_owner_id
      FROM workflow_profile_revisions revisions
      JOIN workflow_profiles profiles ON profiles.id = revisions.workflow_profile_id
     WHERE revisions.id = NEW.workflow_profile_revision_id;
    IF NEW.finalization_round_id IS NOT NULL AND NOT EXISTS (
      SELECT 1 FROM finalization_rounds rounds
      JOIN final_translations translations ON translations.id = rounds.final_translation_id
      WHERE rounds.id = NEW.finalization_round_id AND translations.experiment_id = NEW.experiment_id
    ) THEN
      RAISE EXCEPTION 'Pipeline finalization round must belong to its experiment';
    END IF;
  ELSIF TG_TABLE_NAME = 'source_imports' THEN
    IF NEW.resulting_document_id IS NULL THEN RETURN NEW; END IF;
    left_owner_id := NEW.user_id;
    SELECT projects.user_id INTO right_owner_id
      FROM documents JOIN projects ON projects.id = documents.project_id
     WHERE documents.id = NEW.resulting_document_id;
  ELSE
    IF NEW.experiment_id IS NULL THEN RETURN NEW; END IF;
    left_owner_id := NEW.user_id;
    SELECT projects.user_id INTO right_owner_id
      FROM experiments JOIN documents ON documents.id = experiments.document_id
      JOIN projects ON projects.id = documents.project_id
     WHERE experiments.id = NEW.experiment_id;
  END IF;

  IF left_owner_id IS NULL OR right_owner_id IS NULL OR left_owner_id <> right_owner_id THEN
    RAISE EXCEPTION 'Referenced workflow records must have the same owner';
  END IF;
  RETURN NEW;
END;
$$;


--
-- Name: enforce_project_glossary_owner(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.enforce_project_glossary_owner() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
BEGIN
  PERFORM pg_advisory_xact_lock(hashtextextended('project:' || NEW.id::text, 0));

  IF EXISTS (
    SELECT 1
    FROM experiments
    INNER JOIN documents ON documents.id = experiments.document_id
    INNER JOIN glossary_revisions ON glossary_revisions.id = experiments.glossary_revision_id
    INNER JOIN glossaries ON glossaries.id = glossary_revisions.glossary_id
    WHERE documents.project_id = NEW.id
      AND glossaries.user_id <> NEW.user_id
  ) THEN
    RAISE EXCEPTION 'Project ownership change would invalidate an experiment glossary revision'
      USING ERRCODE = 'check_violation';
  END IF;

  RETURN NEW;
END;
$$;


--
-- Name: enforce_project_methodology_snapshots(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.enforce_project_methodology_snapshots() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
BEGIN
  PERFORM pg_advisory_xact_lock(hashtextextended('project:' || NEW.id::text, 0));

  IF EXISTS (
    SELECT 1
    FROM experiments
    INNER JOIN documents ON documents.id = experiments.document_id
    INNER JOIN methodology_profile_revisions
      ON methodology_profile_revisions.id = experiments.methodology_profile_revision_id
    INNER JOIN methodology_profiles
      ON methodology_profiles.id = methodology_profile_revisions.methodology_profile_id
    WHERE documents.project_id = NEW.id
      AND (
        methodology_profiles.user_id <> NEW.user_id
        OR lower(btrim(methodology_profile_revisions.source_language)) <> lower(btrim(NEW.source_language))
        OR lower(btrim(methodology_profile_revisions.target_language)) <> lower(btrim(NEW.target_language))
      )
  ) THEN
    RAISE EXCEPTION 'Project change would invalidate an experiment methodology revision'
      USING ERRCODE = 'check_violation';
  END IF;

  RETURN NEW;
END;
$$;


--
-- Name: enforce_project_reference_snapshots(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.enforce_project_reference_snapshots() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
BEGIN
  PERFORM pg_advisory_xact_lock(hashtextextended('project:' || NEW.id::text, 0));
  PERFORM pg_advisory_xact_lock(hashtextextended('translation_reference:' || reference_id::text, 0))
    FROM (
      SELECT DISTINCT revisions.translation_reference_id AS reference_id
      FROM experiment_reference_revisions snapshots
      JOIN translation_reference_revisions revisions ON revisions.id = snapshots.translation_reference_revision_id
      JOIN experiments ON experiments.id = snapshots.experiment_id
      JOIN documents ON documents.id = experiments.document_id
      WHERE documents.project_id = NEW.id
      ORDER BY reference_id
    ) references_to_lock;

  IF EXISTS (
    SELECT 1
    FROM documents
    INNER JOIN experiments ON experiments.document_id = documents.id
    INNER JOIN experiment_reference_revisions
      ON experiment_reference_revisions.experiment_id = experiments.id
    INNER JOIN translation_reference_revisions
      ON translation_reference_revisions.id = experiment_reference_revisions.translation_reference_revision_id
    INNER JOIN translation_references
      ON translation_references.id = translation_reference_revisions.translation_reference_id
    WHERE documents.project_id = NEW.id
      AND (
        translation_references.user_id <> NEW.user_id
        OR lower(btrim(translation_reference_revisions.source_language, CHR(9) || CHR(10) || CHR(11) || CHR(12) || CHR(13) || ' ')) <> lower(btrim(NEW.source_language, CHR(9) || CHR(10) || CHR(11) || CHR(12) || CHR(13) || ' '))
        OR lower(btrim(translation_reference_revisions.target_language, CHR(9) || CHR(10) || CHR(11) || CHR(12) || CHR(13) || ' ')) <> lower(btrim(NEW.target_language, CHR(9) || CHR(10) || CHR(11) || CHR(12) || CHR(13) || ' '))
      )
  ) THEN
    RAISE EXCEPTION 'Project change would invalidate an experiment reference snapshot'
      USING ERRCODE = 'check_violation';
  END IF;

  RETURN NEW;
END;
$$;


--
-- Name: enforce_provider_attempt_lineage(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.enforce_provider_attempt_lineage() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
DECLARE
  parent_exists boolean;
  expected_stage text;
BEGIN
  CASE NEW.provider_run_type
  WHEN 'TranslationRun' THEN
    expected_stage := 'translation';
    SELECT TRUE INTO parent_exists FROM translation_runs
     WHERE id = NEW.provider_run_id FOR KEY SHARE;
  WHEN 'TranslationSegmentRun' THEN
    expected_stage := 'translation';
    SELECT TRUE INTO parent_exists FROM translation_segment_runs
     WHERE id = NEW.provider_run_id FOR KEY SHARE;
  WHEN 'ReviewRun' THEN
    expected_stage := 'review';
    SELECT TRUE INTO parent_exists FROM review_runs
     WHERE id = NEW.provider_run_id FOR KEY SHARE;
  WHEN 'ReviewSegmentRun' THEN
    expected_stage := 'review';
    SELECT TRUE INTO parent_exists FROM review_segment_runs
     WHERE id = NEW.provider_run_id FOR KEY SHARE;
  WHEN 'JudgeRun' THEN
    expected_stage := 'judge';
    SELECT TRUE INTO parent_exists FROM judge_runs
     WHERE id = NEW.provider_run_id FOR KEY SHARE;
  WHEN 'JudgeSegmentRun' THEN
    expected_stage := 'judge';
    SELECT TRUE INTO parent_exists FROM judge_segment_runs
     WHERE id = NEW.provider_run_id FOR KEY SHARE;
  WHEN 'FinalizationRun' THEN
    expected_stage := 'finalization';
    SELECT TRUE INTO parent_exists FROM finalization_runs
     WHERE id = NEW.provider_run_id FOR KEY SHARE;
  WHEN 'FinalizationSegmentRun' THEN
    expected_stage := 'finalization';
    SELECT TRUE INTO parent_exists FROM finalization_segment_runs
     WHERE id = NEW.provider_run_id FOR KEY SHARE;
  ELSE
    RAISE EXCEPTION 'Unsupported provider run type';
  END CASE;

  IF parent_exists IS DISTINCT FROM TRUE OR NEW.stage <> expected_stage THEN
    RAISE EXCEPTION 'Provider attempt run and stage must match';
  END IF;
  RETURN NEW;
END;
$$;


--
-- Name: enforce_revision_sequence(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.enforce_revision_sequence() RETURNS trigger
    LANGUAGE plpgsql
    AS $_$
DECLARE
  parent_id bigint;
  next_version integer;
BEGIN
  parent_id := (to_jsonb(NEW)->>TG_ARGV[1])::bigint;
  EXECUTE format('SELECT 1 FROM %I WHERE id = $1 FOR UPDATE', TG_ARGV[0]) USING parent_id;
  EXECUTE format(
    'SELECT COALESCE(MAX(version), 0) + 1 FROM %I WHERE %I = $1',
    TG_TABLE_NAME, TG_ARGV[1]
  ) INTO next_version USING parent_id;
  IF NEW.version <> next_version THEN
    RAISE EXCEPTION 'Revision version must be the next monotonic value';
  END IF;
  RETURN NEW;
END;
$_$;


--
-- Name: enforce_segment_lineage(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.enforce_segment_lineage() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
DECLARE
  parent_experiment_id bigint;
  segment_experiment_id bigint;
BEGIN
  SELECT plans.experiment_id
    INTO segment_experiment_id
    FROM experiment_segments segments
    JOIN document_execution_plans plans ON plans.id = segments.document_execution_plan_id
   WHERE segments.id = NEW.experiment_segment_id;

  CASE TG_TABLE_NAME
  WHEN 'translation_segment_runs' THEN
    SELECT experiment_id INTO parent_experiment_id FROM translation_runs WHERE id = NEW.translation_run_id;
  WHEN 'review_segment_runs' THEN
    SELECT rounds.experiment_id INTO parent_experiment_id
      FROM review_runs runs JOIN review_rounds rounds ON rounds.id = runs.review_round_id
     WHERE runs.id = NEW.review_run_id;
  WHEN 'judge_segment_runs' THEN
    SELECT review_rounds.experiment_id INTO parent_experiment_id
      FROM judge_runs runs
      JOIN judge_rounds rounds ON rounds.id = runs.judge_round_id
      JOIN review_rounds ON review_rounds.id = rounds.review_round_id
     WHERE runs.id = NEW.judge_run_id;
  WHEN 'finalization_segment_runs' THEN
    SELECT translations.experiment_id INTO parent_experiment_id
      FROM finalization_runs runs
      JOIN finalization_rounds rounds ON rounds.id = runs.finalization_round_id
      JOIN final_translations translations ON translations.id = rounds.final_translation_id
     WHERE runs.id = NEW.finalization_run_id;
  WHEN 'final_translation_version_segments' THEN
    SELECT translations.experiment_id INTO parent_experiment_id
      FROM final_translation_versions versions
      JOIN final_translations translations ON translations.id = versions.final_translation_id
     WHERE versions.id = NEW.final_translation_version_id;
  ELSE
    RAISE EXCEPTION 'Unsupported segmented lineage table';
  END CASE;

  IF parent_experiment_id IS NULL OR segment_experiment_id IS NULL OR parent_experiment_id <> segment_experiment_id THEN
    RAISE EXCEPTION 'Segment must belong to the parent experiment';
  END IF;
  RETURN NEW;
END;
$$;


--
-- Name: enforce_translation_reference_owner(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.enforce_translation_reference_owner() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
BEGIN
  PERFORM pg_advisory_xact_lock(hashtextextended('translation_reference:' || NEW.id::text, 0));

  IF EXISTS (
    SELECT 1
    FROM translation_reference_revisions
    INNER JOIN experiment_reference_revisions
      ON experiment_reference_revisions.translation_reference_revision_id = translation_reference_revisions.id
    INNER JOIN experiments ON experiments.id = experiment_reference_revisions.experiment_id
    INNER JOIN documents ON documents.id = experiments.document_id
    INNER JOIN projects ON projects.id = documents.project_id
    WHERE translation_reference_revisions.translation_reference_id = NEW.id
      AND projects.user_id <> NEW.user_id
  ) THEN
    RAISE EXCEPTION 'Translation reference ownership change would invalidate an experiment snapshot'
      USING ERRCODE = 'check_violation';
  END IF;

  RETURN NEW;
END;
$$;


--
-- Name: glossary_revision_configuration_digest(bigint); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.glossary_revision_configuration_digest(revision_id bigint) RETURNS text
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


--
-- Name: methodology_revision_configuration_digest(text, text, text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.methodology_revision_configuration_digest(source_language text, target_language text, guidance text) RETURNS text
    LANGUAGE sql IMMUTABLE STRICT
    AS $$
  SELECT pg_catalog.encode(pg_catalog.sha256(pg_catalog.convert_to(
    '{"source_language":' || pg_catalog.to_json(source_language)::text ||
    ',"target_language":' || pg_catalog.to_json(target_language)::text ||
    ',"guidance":' || pg_catalog.to_json(guidance)::text || '}',
    'UTF8'
  )), 'hex');
$$;


--
-- Name: prevent_completed_record_mutation(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.prevent_completed_record_mutation() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
BEGIN
  IF TG_OP <> 'INSERT' THEN
    IF OLD.status = 'completed' THEN
      RAISE EXCEPTION 'Completed % rows are immutable', TG_TABLE_NAME;
    END IF;
  END IF;

  IF TG_OP <> 'DELETE' THEN
    IF NEW.status IS NOT DISTINCT FROM 'completed' THEN
      CASE TG_TABLE_NAME
      WHEN 'review_runs' THEN
        IF NOT EXISTS (
          SELECT 1 FROM review_evaluations WHERE review_run_id = NEW.id
        ) OR EXISTS (
          SELECT 1 FROM review_evaluations
          WHERE review_run_id = NEW.id
            AND (faithfulness_score IS NULL OR naturalness_score IS NULL
              OR terminology_score IS NULL OR instruction_adherence_score IS NULL
              OR overall_score IS NULL OR strengths IS NULL OR issues IS NULL
              OR recommended_corrections IS NULL)
        ) THEN
          RAISE EXCEPTION 'Completed review runs require complete evaluations';
        END IF;
      WHEN 'judge_runs' THEN
        IF NOT EXISTS (
          SELECT 1 FROM judge_evaluations WHERE judge_run_id = NEW.id
        ) OR EXISTS (
          SELECT 1 FROM judge_evaluations
          WHERE judge_run_id = NEW.id
            AND (rank IS NULL OR overall_score IS NULL
              OR BTRIM(rationale) = '' OR BTRIM(strengths) = '' OR BTRIM(risks) = '')
        ) THEN
          RAISE EXCEPTION 'Completed judge runs require complete evaluations';
        END IF;
        IF (SELECT COUNT(DISTINCT rank) FROM judge_evaluations WHERE judge_run_id = NEW.id)
             <> (SELECT COUNT(*) FROM judge_evaluations WHERE judge_run_id = NEW.id)
           OR (SELECT MIN(rank) FROM judge_evaluations WHERE judge_run_id = NEW.id) <> 1
           OR (SELECT MAX(rank) FROM judge_evaluations WHERE judge_run_id = NEW.id)
             <> (SELECT COUNT(*) FROM judge_evaluations WHERE judge_run_id = NEW.id) THEN
          RAISE EXCEPTION 'Completed judge runs require one complete ranking';
        END IF;
        IF NEW.winner_translation_run_id IS NULL
           OR NEW.confidence_score IS NULL
           OR NEW.winner_rationale IS NULL
           OR BTRIM(NEW.winner_rationale) = ''
           OR NOT EXISTS (
             SELECT 1 FROM judge_evaluations
             WHERE judge_run_id = NEW.id AND rank = 1
               AND translation_run_id = NEW.winner_translation_run_id
           ) THEN
          RAISE EXCEPTION 'Completed judge runs require a complete rank-one winner';
        END IF;
      WHEN 'finalization_runs' THEN
        IF NEW.proposed_translation IS NULL OR BTRIM(NEW.proposed_translation) = '' THEN
          RAISE EXCEPTION 'Completed finalization runs require a proposal';
        END IF;
        IF EXISTS (
          SELECT 1
          FROM jsonb_array_elements(NEW.change_summary || NEW.terminology_notes || NEW.warnings) AS items(item)
          WHERE jsonb_typeof(items.item) <> 'string'
        ) THEN
          RAISE EXCEPTION 'Completed finalization runs require string proposal lists';
        END IF;
      WHEN 'review_rounds' THEN
        IF NOT EXISTS (
          SELECT 1 FROM review_runs WHERE review_round_id = NEW.id
        ) OR EXISTS (
          SELECT 1 FROM review_runs
          WHERE review_round_id = NEW.id AND status NOT IN ('completed', 'failed')
        ) THEN
          RAISE EXCEPTION 'Completed review rounds require terminal review runs';
        END IF;
        IF EXISTS (
          SELECT 1 FROM review_runs WHERE review_round_id = NEW.id AND status = 'failed'
        ) THEN
          RAISE EXCEPTION 'Completed review rounds cannot contain failed review runs';
        END IF;
      WHEN 'judge_rounds' THEN
        IF NOT EXISTS (
          SELECT 1 FROM judge_runs WHERE judge_round_id = NEW.id
        ) OR EXISTS (
          SELECT 1 FROM judge_runs
          WHERE judge_round_id = NEW.id AND status NOT IN ('completed', 'failed')
        ) THEN
          RAISE EXCEPTION 'Completed judge rounds require terminal judge runs';
        END IF;
        IF EXISTS (
          SELECT 1 FROM judge_runs WHERE judge_round_id = NEW.id AND status = 'failed'
        ) THEN
          RAISE EXCEPTION 'Completed judge rounds cannot contain failed judge runs';
        END IF;
        IF NEW.winner_translation_run_id IS NULL
           OR NOT EXISTS (
             SELECT 1 FROM judge_evaluations evaluations
             JOIN judge_runs runs ON runs.id = evaluations.judge_run_id
             WHERE runs.judge_round_id = NEW.id
               AND evaluations.translation_run_id = NEW.winner_translation_run_id
           ) THEN
          RAISE EXCEPTION 'Completed judge rounds require an evaluated winner';
        END IF;
      WHEN 'finalization_rounds' THEN
        IF NOT EXISTS (
          SELECT 1 FROM finalization_runs WHERE finalization_round_id = NEW.id
        ) OR EXISTS (
          SELECT 1 FROM finalization_runs
          WHERE finalization_round_id = NEW.id AND status NOT IN ('completed', 'failed')
        ) THEN
          RAISE EXCEPTION 'Completed finalization rounds require terminal finalization runs';
        END IF;
        IF EXISTS (
          SELECT 1 FROM finalization_runs
          WHERE finalization_round_id = NEW.id AND status = 'failed'
        ) THEN
          RAISE EXCEPTION 'Completed finalization rounds cannot contain failed finalization runs';
        END IF;
      ELSE
        NULL;
      END CASE;
    END IF;
  END IF;

  RETURN CASE WHEN TG_OP = 'DELETE' THEN OLD ELSE NEW END;
END;
$$;


--
-- Name: prevent_experiment_glossary_revision_mutation(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.prevent_experiment_glossary_revision_mutation() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
BEGIN
  IF OLD.glossary_revision_id IS DISTINCT FROM NEW.glossary_revision_id THEN
    RAISE EXCEPTION 'Experiment glossary revision cannot change after creation'
      USING ERRCODE = 'check_violation';
  END IF;
  RETURN NEW;
END;
$$;


--
-- Name: prevent_experiment_guidance_preference_mutation(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.prevent_experiment_guidance_preference_mutation() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
BEGIN
  IF OLD.guidance_preference IS DISTINCT FROM NEW.guidance_preference THEN
    RAISE EXCEPTION 'Experiment guidance preference cannot change after creation'
      USING ERRCODE = 'check_violation';
  END IF;

  RETURN NEW;
END;
$$;


--
-- Name: prevent_experiment_reference_snapshot_mutation(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.prevent_experiment_reference_snapshot_mutation() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
BEGIN
  IF TG_OP = 'DELETE' THEN
    RAISE EXCEPTION 'Experiment reference snapshots cannot be deleted'
      USING ERRCODE = 'check_violation';
  END IF;

  RAISE EXCEPTION 'Experiment reference snapshots are immutable'
    USING ERRCODE = 'check_violation';
END;
$$;


--
-- Name: prevent_glossary_revision_mutation(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.prevent_glossary_revision_mutation() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
BEGIN
  IF TG_OP = 'DELETE' THEN
    RAISE EXCEPTION 'Glossary revisions cannot be deleted'
      USING ERRCODE = 'check_violation';
  END IF;

  IF OLD.entry_set_sealed = FALSE
     AND NEW.entry_set_sealed = TRUE
     AND (to_jsonb(NEW) - 'entry_set_sealed') = (to_jsonb(OLD) - 'entry_set_sealed') THEN
    RETURN NEW;
  END IF;

  RAISE EXCEPTION 'Glossary revisions are immutable'
    USING ERRCODE = 'check_violation';
END;
$$;


--
-- Name: prevent_immutable_row_mutation(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.prevent_immutable_row_mutation() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
BEGIN
  RAISE EXCEPTION '% rows are immutable', TG_TABLE_NAME;
END;
$$;


--
-- Name: prevent_methodology_profile_revision_mutation(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.prevent_methodology_profile_revision_mutation() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
BEGIN
  IF TG_OP = 'DELETE' THEN
    RAISE EXCEPTION 'Methodology profile revisions cannot be deleted'
      USING ERRCODE = 'check_violation';
  END IF;

  RAISE EXCEPTION 'Methodology profile revisions are immutable'
    USING ERRCODE = 'check_violation';
END;
$$;


--
-- Name: prevent_parent_lineage_mutation(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.prevent_parent_lineage_mutation() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
BEGIN
  IF (to_jsonb(OLD)->>TG_ARGV[0]) IS DISTINCT FROM (to_jsonb(NEW)->>TG_ARGV[0]) THEN
    RAISE EXCEPTION 'Historical parent lineage cannot change after creation'
      USING ERRCODE = 'check_violation';
  END IF;
  RETURN NEW;
END;
$$;


--
-- Name: prevent_provider_attempt_mutation(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.prevent_provider_attempt_mutation() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
BEGIN
  IF TG_OP = 'DELETE' OR OLD.status IN ('completed', 'failed') THEN
    RAISE EXCEPTION 'Historical provider attempts are immutable';
  END IF;
  IF OLD.provider_run_type IS DISTINCT FROM NEW.provider_run_type OR
     OLD.provider_run_id IS DISTINCT FROM NEW.provider_run_id OR
     OLD.attempt_number IS DISTINCT FROM NEW.attempt_number OR
     OLD.stage IS DISTINCT FROM NEW.stage OR
     OLD.gateway_snapshot IS DISTINCT FROM NEW.gateway_snapshot OR
     OLD.provider_snapshot IS DISTINCT FROM NEW.provider_snapshot OR
     OLD.model_identifier_snapshot IS DISTINCT FROM NEW.model_identifier_snapshot OR
     OLD.display_name_snapshot IS DISTINCT FROM NEW.display_name_snapshot OR
     OLD.started_at IS DISTINCT FROM NEW.started_at OR
     OLD.created_at IS DISTINCT FROM NEW.created_at THEN
    RAISE EXCEPTION 'Provider attempt identity and routing snapshots are immutable';
  END IF;
  RETURN NEW;
END;
$$;


--
-- Name: prevent_terminal_evaluation_mutation(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.prevent_terminal_evaluation_mutation() RETURNS trigger
    LANGUAGE plpgsql
    AS $_$
DECLARE
  old_parent_id bigint;
  new_parent_id bigint;
  parent_status text;
BEGIN
  IF TG_OP <> 'INSERT' THEN
    old_parent_id := (to_jsonb(OLD)->>TG_ARGV[1])::bigint;
    EXECUTE format('SELECT status FROM %I WHERE id = $1 FOR UPDATE', TG_ARGV[0])
      INTO parent_status USING old_parent_id;
    IF parent_status = 'completed' THEN
      RAISE EXCEPTION 'Completed evaluation results are immutable';
    END IF;
  END IF;

  IF TG_OP <> 'DELETE' THEN
    new_parent_id := (to_jsonb(NEW)->>TG_ARGV[1])::bigint;
    IF TG_OP = 'INSERT' OR new_parent_id <> old_parent_id THEN
      EXECUTE format('SELECT status FROM %I WHERE id = $1 FOR UPDATE', TG_ARGV[0])
        INTO parent_status USING new_parent_id;
      IF parent_status = 'completed' THEN
        RAISE EXCEPTION 'Completed evaluation results are immutable';
      END IF;
    END IF;
  END IF;

  RETURN CASE WHEN TG_OP = 'DELETE' THEN OLD ELSE NEW END;
END;
$_$;


--
-- Name: prevent_translation_reference_revision_mutation(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.prevent_translation_reference_revision_mutation() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
BEGIN
  IF TG_OP = 'DELETE' THEN
    RAISE EXCEPTION 'Translation reference revisions cannot be deleted'
      USING ERRCODE = 'check_violation';
  END IF;

  RAISE EXCEPTION 'Translation reference revisions are immutable'
    USING ERRCODE = 'check_violation';
END;
$$;


--
-- Name: restrict_provider_run_deletion(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.restrict_provider_run_deletion() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
BEGIN
  IF EXISTS (
    SELECT 1 FROM ai_provider_attempts
    WHERE provider_run_type = TG_ARGV[0] AND provider_run_id = OLD.id
  ) THEN
    RAISE EXCEPTION 'Provider runs with attempt history cannot be deleted';
  END IF;
  RETURN OLD;
END;
$$;


--
-- Name: seal_glossary_revision_entry_set(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.seal_glossary_revision_entry_set() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
DECLARE
  entry_count integer;
BEGIN
  SELECT count(*) INTO entry_count FROM glossary_entries WHERE glossary_revision_id = NEW.id;
  IF entry_count NOT BETWEEN 1 AND 100 THEN
    RAISE EXCEPTION 'Glossary revisions must have 1-100 entries'
      USING ERRCODE = 'check_violation';
  END IF;

  IF NEW.configuration_digest <> glossary_revision_configuration_digest(NEW.id) THEN
    RAISE EXCEPTION 'Glossary revision configuration digest does not match its entries'
      USING ERRCODE = 'check_violation';
  END IF;

  UPDATE glossary_revisions
  SET entry_set_sealed = TRUE
  WHERE id = NEW.id AND entry_set_sealed = FALSE;

  RETURN NULL;
END;
$$;


--
-- Name: translation_reference_revision_configuration_digest(text, text, text, text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.translation_reference_revision_configuration_digest(source_language text, target_language text, source_text text, approved_translation text) RETURNS text
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


SET default_tablespace = '';

SET default_table_access_method = heap;

--
-- Name: active_storage_attachments; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.active_storage_attachments (
    id bigint NOT NULL,
    name character varying NOT NULL,
    record_type character varying NOT NULL,
    record_id bigint NOT NULL,
    blob_id bigint NOT NULL,
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL
);


--
-- Name: active_storage_attachments_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.active_storage_attachments_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: active_storage_attachments_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.active_storage_attachments_id_seq OWNED BY public.active_storage_attachments.id;


--
-- Name: active_storage_blobs; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.active_storage_blobs (
    id bigint NOT NULL,
    key character varying NOT NULL,
    filename character varying NOT NULL,
    content_type character varying,
    metadata text,
    service_name character varying NOT NULL,
    byte_size bigint NOT NULL,
    checksum character varying,
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL
);


--
-- Name: active_storage_blobs_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.active_storage_blobs_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: active_storage_blobs_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.active_storage_blobs_id_seq OWNED BY public.active_storage_blobs.id;


--
-- Name: active_storage_variant_records; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.active_storage_variant_records (
    id bigint NOT NULL,
    blob_id bigint NOT NULL,
    variation_digest character varying NOT NULL
);


--
-- Name: active_storage_variant_records_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.active_storage_variant_records_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: active_storage_variant_records_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.active_storage_variant_records_id_seq OWNED BY public.active_storage_variant_records.id;


--
-- Name: ai_provider_attempts; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.ai_provider_attempts (
    id bigint NOT NULL,
    provider_run_type character varying NOT NULL,
    provider_run_id bigint NOT NULL,
    attempt_number integer NOT NULL,
    stage character varying NOT NULL,
    status character varying NOT NULL,
    gateway_snapshot character varying NOT NULL,
    provider_snapshot character varying NOT NULL,
    model_identifier_snapshot character varying NOT NULL,
    display_name_snapshot character varying NOT NULL,
    started_at timestamp(6) without time zone NOT NULL,
    completed_at timestamp(6) without time zone,
    error_code character varying,
    prompt_tokens integer,
    completion_tokens integer,
    total_tokens integer,
    cached_tokens integer,
    reasoning_tokens integer,
    cost numeric(20,10),
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL,
    CONSTRAINT ai_provider_attempts_attempt_number_check CHECK ((attempt_number > 0)),
    CONSTRAINT ai_provider_attempts_cached_tokens_check CHECK (((cached_tokens IS NULL) OR (cached_tokens >= 0))),
    CONSTRAINT ai_provider_attempts_completion_tokens_check CHECK (((completion_tokens IS NULL) OR (completion_tokens >= 0))),
    CONSTRAINT ai_provider_attempts_cost_check CHECK (((cost IS NULL) OR (cost >= (0)::numeric))),
    CONSTRAINT ai_provider_attempts_display_name_snapshot_check CHECK (((char_length((display_name_snapshot)::text) >= 1) AND (char_length((display_name_snapshot)::text) <= 150))),
    CONSTRAINT ai_provider_attempts_duration_check CHECK (((completed_at IS NULL) OR (completed_at >= started_at))),
    CONSTRAINT ai_provider_attempts_error_code_format_check CHECK (((error_code IS NULL) OR ((char_length((error_code)::text) >= 1) AND (char_length((error_code)::text) <= 80) AND ((error_code)::text ~ '^[a-z0-9_.:-]+$'::text)))),
    CONSTRAINT ai_provider_attempts_gateway_snapshot_check CHECK (((char_length((gateway_snapshot)::text) >= 1) AND (char_length((gateway_snapshot)::text) <= 50))),
    CONSTRAINT ai_provider_attempts_identifier_snapshot_check CHECK (((char_length((model_identifier_snapshot)::text) >= 1) AND (char_length((model_identifier_snapshot)::text) <= 255))),
    CONSTRAINT ai_provider_attempts_lifecycle_check CHECK (((((status)::text = 'running'::text) AND (completed_at IS NULL) AND (error_code IS NULL)) OR (((status)::text = 'completed'::text) AND (completed_at IS NOT NULL) AND (error_code IS NULL)) OR (((status)::text = 'failed'::text) AND (completed_at IS NOT NULL) AND (error_code IS NOT NULL)))),
    CONSTRAINT ai_provider_attempts_prompt_tokens_check CHECK (((prompt_tokens IS NULL) OR (prompt_tokens >= 0))),
    CONSTRAINT ai_provider_attempts_provider_snapshot_check CHECK (((char_length((provider_snapshot)::text) >= 1) AND (char_length((provider_snapshot)::text) <= 100))),
    CONSTRAINT ai_provider_attempts_reasoning_tokens_check CHECK (((reasoning_tokens IS NULL) OR (reasoning_tokens >= 0))),
    CONSTRAINT ai_provider_attempts_run_type_check CHECK (((provider_run_type)::text = ANY (ARRAY[('TranslationRun'::character varying)::text, ('TranslationSegmentRun'::character varying)::text, ('ReviewRun'::character varying)::text, ('ReviewSegmentRun'::character varying)::text, ('JudgeRun'::character varying)::text, ('JudgeSegmentRun'::character varying)::text, ('FinalizationRun'::character varying)::text, ('FinalizationSegmentRun'::character varying)::text]))),
    CONSTRAINT ai_provider_attempts_stage_check CHECK (((stage)::text = ANY (ARRAY[('translation'::character varying)::text, ('review'::character varying)::text, ('judge'::character varying)::text, ('finalization'::character varying)::text]))),
    CONSTRAINT ai_provider_attempts_status_check CHECK (((status)::text = ANY (ARRAY[('running'::character varying)::text, ('completed'::character varying)::text, ('failed'::character varying)::text]))),
    CONSTRAINT ai_provider_attempts_token_consistency_check CHECK (((total_tokens IS NULL) OR (((prompt_tokens IS NULL) OR (prompt_tokens <= total_tokens)) AND ((completion_tokens IS NULL) OR (completion_tokens <= total_tokens)) AND ((cached_tokens IS NULL) OR (cached_tokens <= total_tokens)) AND ((reasoning_tokens IS NULL) OR (reasoning_tokens <= total_tokens))))),
    CONSTRAINT ai_provider_attempts_total_tokens_check CHECK (((total_tokens IS NULL) OR (total_tokens >= 0)))
);


--
-- Name: ai_provider_attempts_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.ai_provider_attempts_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: ai_provider_attempts_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.ai_provider_attempts_id_seq OWNED BY public.ai_provider_attempts.id;


--
-- Name: ar_internal_metadata; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.ar_internal_metadata (
    key character varying NOT NULL,
    value character varying,
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL
);


--
-- Name: document_execution_plans; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.document_execution_plans (
    id bigint NOT NULL,
    experiment_id bigint NOT NULL,
    segmentation_version character varying NOT NULL,
    budget_policy_version character varying NOT NULL,
    source_sha256 character varying NOT NULL,
    segment_count integer NOT NULL,
    segment_target_characters integer NOT NULL,
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL,
    CONSTRAINT document_execution_plans_segment_count_check CHECK ((segment_count > 1)),
    CONSTRAINT document_execution_plans_source_digest_check CHECK ((char_length((source_sha256)::text) = 64)),
    CONSTRAINT document_execution_plans_target_check CHECK (((segment_target_characters >= 256) AND (segment_target_characters <= 20000)))
);


--
-- Name: document_execution_plans_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.document_execution_plans_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: document_execution_plans_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.document_execution_plans_id_seq OWNED BY public.document_execution_plans.id;


--
-- Name: documents; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.documents (
    id bigint NOT NULL,
    created_at timestamp(6) without time zone NOT NULL,
    project_id bigint NOT NULL,
    source_text text NOT NULL,
    title character varying NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL,
    source_kind character varying DEFAULT 'pasted_text'::character varying NOT NULL,
    source_format character varying,
    original_filename character varying,
    detected_content_type character varying,
    original_byte_size bigint,
    source_sha256 character varying,
    extraction_version character varying,
    CONSTRAINT documents_original_byte_size_check CHECK (((original_byte_size IS NULL) OR ((original_byte_size >= 0) AND (original_byte_size <= 10485760)))),
    CONSTRAINT documents_source_format_check CHECK (((source_format IS NULL) OR ((source_format)::text = ANY (ARRAY[('txt'::character varying)::text, ('md'::character varying)::text, ('docx'::character varying)::text, ('pdf'::character varying)::text])))),
    CONSTRAINT documents_source_kind_check CHECK (((source_kind)::text = ANY (ARRAY[('pasted_text'::character varying)::text, ('uploaded_file'::character varying)::text]))),
    CONSTRAINT documents_source_sha256_check CHECK (((source_sha256 IS NULL) OR (char_length((source_sha256)::text) = 64)))
);


--
-- Name: documents_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.documents_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: documents_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.documents_id_seq OWNED BY public.documents.id;


--
-- Name: experiment_reference_revisions; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.experiment_reference_revisions (
    id bigint NOT NULL,
    experiment_id bigint NOT NULL,
    translation_reference_revision_id bigint NOT NULL,
    "position" integer NOT NULL,
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL,
    CONSTRAINT experiment_reference_revisions_position_check CHECK ((("position" >= 1) AND ("position" <= 5)))
);


--
-- Name: experiment_reference_revisions_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.experiment_reference_revisions_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: experiment_reference_revisions_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.experiment_reference_revisions_id_seq OWNED BY public.experiment_reference_revisions.id;


--
-- Name: experiment_segments; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.experiment_segments (
    id bigint NOT NULL,
    document_execution_plan_id bigint NOT NULL,
    "position" integer NOT NULL,
    source_text text NOT NULL,
    source_character_count integer NOT NULL,
    source_sha256 character varying NOT NULL,
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL,
    CONSTRAINT experiment_segments_position_check CHECK (("position" > 0)),
    CONSTRAINT experiment_segments_source_digest_check CHECK ((char_length((source_sha256)::text) = 64)),
    CONSTRAINT experiment_segments_source_length_check CHECK (((source_character_count > 0) AND (source_character_count = char_length(source_text))))
);


--
-- Name: experiment_segments_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.experiment_segments_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: experiment_segments_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.experiment_segments_id_seq OWNED BY public.experiment_segments.id;


--
-- Name: experiments; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.experiments (
    id bigint NOT NULL,
    created_at timestamp(6) without time zone NOT NULL,
    document_id bigint NOT NULL,
    instruction_prompt text NOT NULL,
    name character varying,
    status character varying DEFAULT 'pending'::character varying NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL,
    glossary_revision_id bigint,
    methodology_profile_revision_id bigint,
    guidance_preference character varying DEFAULT 'reference_examples'::character varying NOT NULL,
    CONSTRAINT experiments_guidance_preference_check CHECK (((guidance_preference)::text = ANY (ARRAY[('reference_examples'::character varying)::text, ('glossary'::character varying)::text, ('experiment_instruction'::character varying)::text])))
);


--
-- Name: experiments_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.experiments_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: experiments_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.experiments_id_seq OWNED BY public.experiments.id;


--
-- Name: federated_identities; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.federated_identities (
    id bigint NOT NULL,
    user_id bigint NOT NULL,
    provider character varying NOT NULL,
    provider_uid character varying NOT NULL,
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL,
    CONSTRAINT federated_identities_provider_check CHECK (((provider)::text = 'google'::text)),
    CONSTRAINT federated_identities_provider_uid_length_check CHECK (((char_length((provider_uid)::text) >= 1) AND (char_length((provider_uid)::text) <= 255)))
);


--
-- Name: federated_identities_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.federated_identities_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: federated_identities_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.federated_identities_id_seq OWNED BY public.federated_identities.id;


--
-- Name: final_translation_version_segments; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.final_translation_version_segments (
    id bigint NOT NULL,
    final_translation_version_id bigint NOT NULL,
    experiment_segment_id bigint NOT NULL,
    content text NOT NULL,
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL,
    CONSTRAINT final_translation_version_segments_content_check CHECK (((char_length(content) >= 1) AND (char_length(content) <= 20000)))
);


--
-- Name: final_translation_version_segments_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.final_translation_version_segments_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: final_translation_version_segments_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.final_translation_version_segments_id_seq OWNED BY public.final_translation_version_segments.id;


--
-- Name: final_translation_versions; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.final_translation_versions (
    id bigint NOT NULL,
    change_note character varying,
    content text NOT NULL,
    created_at timestamp(6) without time zone NOT NULL,
    final_translation_id bigint NOT NULL,
    origin character varying NOT NULL,
    source_finalization_run_id bigint,
    updated_at timestamp(6) without time zone NOT NULL,
    version_number integer NOT NULL,
    segment_alignment_valid boolean DEFAULT true NOT NULL,
    CONSTRAINT final_translation_versions_change_note_check CHECK (((change_note IS NULL) OR (char_length((change_note)::text) <= 500))),
    CONSTRAINT final_translation_versions_content_check CHECK (((char_length(btrim(content)) > 0) AND (char_length(content) <= 100000))),
    CONSTRAINT final_translation_versions_number_check CHECK ((version_number > 0)),
    CONSTRAINT final_translation_versions_origin_check CHECK (((origin)::text = ANY (ARRAY[('seed'::character varying)::text, ('manual'::character varying)::text, ('ai_applied'::character varying)::text, ('restored'::character varying)::text]))),
    CONSTRAINT final_translation_versions_source_origin_check CHECK ((((origin)::text = 'ai_applied'::text) = (source_finalization_run_id IS NOT NULL)))
);


--
-- Name: final_translation_versions_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.final_translation_versions_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: final_translation_versions_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.final_translation_versions_id_seq OWNED BY public.final_translation_versions.id;


--
-- Name: final_translations; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.final_translations (
    id bigint NOT NULL,
    created_at timestamp(6) without time zone NOT NULL,
    current_version_id bigint,
    experiment_id bigint NOT NULL,
    finalized_at timestamp(6) without time zone,
    judge_round_id bigint NOT NULL,
    lock_version integer DEFAULT 0 NOT NULL,
    source_winner_translation_run_id bigint NOT NULL,
    status character varying DEFAULT 'draft'::character varying NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL,
    CONSTRAINT final_translations_finalized_at_check CHECK ((((status)::text = 'finalized'::text) = (finalized_at IS NOT NULL))),
    CONSTRAINT final_translations_status_check CHECK (((status)::text = ANY (ARRAY[('draft'::character varying)::text, ('finalized'::character varying)::text])))
);


--
-- Name: final_translations_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.final_translations_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: final_translations_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.final_translations_id_seq OWNED BY public.final_translations.id;


--
-- Name: finalization_rounds; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.finalization_rounds (
    id bigint NOT NULL,
    base_final_translation_version_id bigint NOT NULL,
    created_at timestamp(6) without time zone NOT NULL,
    final_translation_id bigint NOT NULL,
    selection_key character varying NOT NULL,
    status character varying DEFAULT 'running'::character varying NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL,
    CONSTRAINT finalization_rounds_selection_key_check CHECK ((char_length((selection_key)::text) = 64)),
    CONSTRAINT finalization_rounds_status_check CHECK (((status)::text = ANY (ARRAY[('running'::character varying)::text, ('completed'::character varying)::text, ('failed'::character varying)::text])))
);


--
-- Name: finalization_rounds_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.finalization_rounds_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: finalization_rounds_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.finalization_rounds_id_seq OWNED BY public.finalization_rounds.id;


--
-- Name: finalization_runs; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.finalization_runs (
    id bigint NOT NULL,
    cached_tokens bigint,
    change_summary jsonb DEFAULT '[]'::jsonb NOT NULL,
    completed_at timestamp(6) without time zone,
    completion_tokens bigint,
    cost numeric(20,10),
    created_at timestamp(6) without time zone NOT NULL,
    error_code character varying,
    error_message text,
    finalization_round_id bigint NOT NULL,
    finalizer_llm_model_id bigint NOT NULL,
    prompt_tokens bigint,
    proposed_translation text,
    provider_response_id character varying,
    reasoning_tokens bigint,
    resolved_model_identifier character varying,
    started_at timestamp(6) without time zone,
    status character varying DEFAULT 'pending'::character varying NOT NULL,
    terminology_notes jsonb DEFAULT '[]'::jsonb NOT NULL,
    total_tokens bigint,
    updated_at timestamp(6) without time zone NOT NULL,
    warnings jsonb DEFAULT '[]'::jsonb NOT NULL,
    last_claimed_at timestamp(6) without time zone,
    execution_attempt integer DEFAULT 0 NOT NULL,
    scheduled_job_id character varying,
    claimed_job_execution integer DEFAULT 0 NOT NULL,
    pending_since timestamp(6) without time zone,
    context_window_tokens_snapshot integer,
    max_output_tokens_snapshot integer,
    estimated_input_tokens integer,
    reserved_output_tokens integer,
    context_safety_margin_tokens integer,
    budget_policy_version character varying,
    telemetry_complete boolean DEFAULT true NOT NULL,
    cost_complete boolean DEFAULT false NOT NULL,
    CONSTRAINT finalization_runs_budget_numbers_check CHECK (((estimated_input_tokens IS NULL) OR ((estimated_input_tokens >= 0) AND (reserved_output_tokens > 0) AND (context_safety_margin_tokens > 0)))),
    CONSTRAINT finalization_runs_budget_snapshot_integrity_check CHECK ((((context_window_tokens_snapshot IS NULL) AND (max_output_tokens_snapshot IS NULL) AND (estimated_input_tokens IS NULL) AND (reserved_output_tokens IS NULL) AND (context_safety_margin_tokens IS NULL) AND (budget_policy_version IS NULL)) OR ((context_window_tokens_snapshot IS NOT NULL) AND (max_output_tokens_snapshot IS NOT NULL) AND (estimated_input_tokens IS NOT NULL) AND (reserved_output_tokens IS NOT NULL) AND (context_safety_margin_tokens IS NOT NULL) AND (budget_policy_version IS NOT NULL) AND ((char_length((budget_policy_version)::text) >= 1) AND (char_length((budget_policy_version)::text) <= 100)) AND (max_output_tokens_snapshot < context_window_tokens_snapshot) AND (reserved_output_tokens <= max_output_tokens_snapshot) AND (((estimated_input_tokens + reserved_output_tokens) + context_safety_margin_tokens) <= context_window_tokens_snapshot)))),
    CONSTRAINT finalization_runs_cached_tokens_check CHECK (((cached_tokens IS NULL) OR (cached_tokens >= 0))),
    CONSTRAINT finalization_runs_change_summary_array_check CHECK ((jsonb_typeof(change_summary) = 'array'::text)),
    CONSTRAINT finalization_runs_claimed_job_execution_check CHECK ((claimed_job_execution >= 0)),
    CONSTRAINT finalization_runs_complete_cost_present_check CHECK (((NOT cost_complete) OR (cost IS NOT NULL))),
    CONSTRAINT finalization_runs_completion_tokens_check CHECK (((completion_tokens IS NULL) OR (completion_tokens >= 0))),
    CONSTRAINT finalization_runs_context_snapshot_check CHECK (((context_window_tokens_snapshot IS NULL) OR ((context_window_tokens_snapshot >= 1024) AND (context_window_tokens_snapshot <= 2000000)))),
    CONSTRAINT finalization_runs_cost_check CHECK (((cost IS NULL) OR (cost >= (0)::numeric))),
    CONSTRAINT finalization_runs_execution_attempt_check CHECK ((execution_attempt >= 0)),
    CONSTRAINT finalization_runs_output_snapshot_check CHECK (((max_output_tokens_snapshot IS NULL) OR ((max_output_tokens_snapshot >= 256) AND (max_output_tokens_snapshot <= 200000)))),
    CONSTRAINT finalization_runs_prompt_tokens_check CHECK (((prompt_tokens IS NULL) OR (prompt_tokens >= 0))),
    CONSTRAINT finalization_runs_proposal_length_check CHECK (((proposed_translation IS NULL) OR (char_length(proposed_translation) <= 100000))),
    CONSTRAINT finalization_runs_reasoning_tokens_check CHECK (((reasoning_tokens IS NULL) OR (reasoning_tokens >= 0))),
    CONSTRAINT finalization_runs_status_check CHECK (((status)::text = ANY (ARRAY[('pending'::character varying)::text, ('running'::character varying)::text, ('completed'::character varying)::text, ('failed'::character varying)::text]))),
    CONSTRAINT finalization_runs_terminology_notes_array_check CHECK ((jsonb_typeof(terminology_notes) = 'array'::text)),
    CONSTRAINT finalization_runs_total_tokens_check CHECK (((total_tokens IS NULL) OR (total_tokens >= 0))),
    CONSTRAINT finalization_runs_warnings_array_check CHECK ((jsonb_typeof(warnings) = 'array'::text))
);


--
-- Name: finalization_runs_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.finalization_runs_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: finalization_runs_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.finalization_runs_id_seq OWNED BY public.finalization_runs.id;


--
-- Name: finalization_segment_runs; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.finalization_segment_runs (
    id bigint NOT NULL,
    finalization_run_id bigint NOT NULL,
    experiment_segment_id bigint NOT NULL,
    status character varying DEFAULT 'pending'::character varying NOT NULL,
    scheduled_job_id character varying,
    claimed_job_execution integer DEFAULT 0 NOT NULL,
    execution_attempt integer DEFAULT 0 NOT NULL,
    pending_since timestamp(6) without time zone,
    last_claimed_at timestamp(6) without time zone,
    started_at timestamp(6) without time zone,
    completed_at timestamp(6) without time zone,
    error_code character varying,
    error_message text,
    provider_response_id character varying,
    resolved_model_identifier character varying,
    prompt_tokens bigint,
    completion_tokens bigint,
    total_tokens bigint,
    cached_tokens bigint,
    reasoning_tokens bigint,
    cost numeric(20,10),
    context_window_tokens_snapshot integer NOT NULL,
    max_output_tokens_snapshot integer NOT NULL,
    estimated_input_tokens integer NOT NULL,
    reserved_output_tokens integer NOT NULL,
    context_safety_margin_tokens integer NOT NULL,
    budget_policy_version character varying NOT NULL,
    proposed_translation text,
    change_summary jsonb DEFAULT '[]'::jsonb NOT NULL,
    terminology_notes jsonb DEFAULT '[]'::jsonb NOT NULL,
    warnings jsonb DEFAULT '[]'::jsonb NOT NULL,
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL,
    CONSTRAINT finalization_segment_runs_budget_numbers_check CHECK (((estimated_input_tokens >= 0) AND (reserved_output_tokens > 0) AND (context_safety_margin_tokens > 0))),
    CONSTRAINT finalization_segment_runs_budget_snapshot_integrity_check CHECK (((char_length((budget_policy_version)::text) >= 1) AND (char_length((budget_policy_version)::text) <= 100) AND (reserved_output_tokens <= max_output_tokens_snapshot) AND (((estimated_input_tokens + reserved_output_tokens) + context_safety_margin_tokens) <= context_window_tokens_snapshot))),
    CONSTRAINT finalization_segment_runs_cached_tokens_check CHECK (((cached_tokens IS NULL) OR (cached_tokens >= 0))),
    CONSTRAINT finalization_segment_runs_change_summary_check CHECK (((jsonb_typeof(change_summary) = 'array'::text) AND (octet_length((change_summary)::text) <= 50000))),
    CONSTRAINT finalization_segment_runs_claimed_execution_check CHECK ((claimed_job_execution >= 0)),
    CONSTRAINT finalization_segment_runs_completion_tokens_check CHECK (((completion_tokens IS NULL) OR (completion_tokens >= 0))),
    CONSTRAINT finalization_segment_runs_context_snapshot_check CHECK (((context_window_tokens_snapshot >= 1024) AND (context_window_tokens_snapshot <= 2000000))),
    CONSTRAINT finalization_segment_runs_cost_check CHECK (((cost IS NULL) OR (cost >= (0)::numeric))),
    CONSTRAINT finalization_segment_runs_execution_attempt_check CHECK ((execution_attempt >= 0)),
    CONSTRAINT finalization_segment_runs_output_snapshot_check CHECK (((max_output_tokens_snapshot >= 256) AND (max_output_tokens_snapshot <= 200000) AND (max_output_tokens_snapshot < context_window_tokens_snapshot))),
    CONSTRAINT finalization_segment_runs_prompt_tokens_check CHECK (((prompt_tokens IS NULL) OR (prompt_tokens >= 0))),
    CONSTRAINT finalization_segment_runs_proposal_length_check CHECK (((proposed_translation IS NULL) OR (char_length(proposed_translation) <= 20000))),
    CONSTRAINT finalization_segment_runs_reasoning_tokens_check CHECK (((reasoning_tokens IS NULL) OR (reasoning_tokens >= 0))),
    CONSTRAINT finalization_segment_runs_status_check CHECK (((status)::text = ANY (ARRAY[('pending'::character varying)::text, ('running'::character varying)::text, ('completed'::character varying)::text, ('failed'::character varying)::text]))),
    CONSTRAINT finalization_segment_runs_terminology_notes_check CHECK (((jsonb_typeof(terminology_notes) = 'array'::text) AND (octet_length((terminology_notes)::text) <= 50000))),
    CONSTRAINT finalization_segment_runs_total_tokens_check CHECK (((total_tokens IS NULL) OR (total_tokens >= 0))),
    CONSTRAINT finalization_segment_runs_warnings_check CHECK (((jsonb_typeof(warnings) = 'array'::text) AND (octet_length((warnings)::text) <= 50000)))
);


--
-- Name: finalization_segment_runs_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.finalization_segment_runs_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: finalization_segment_runs_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.finalization_segment_runs_id_seq OWNED BY public.finalization_segment_runs.id;


--
-- Name: glossaries; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.glossaries (
    id bigint NOT NULL,
    user_id bigint NOT NULL,
    current_revision_id bigint,
    active boolean DEFAULT true NOT NULL,
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL
);


--
-- Name: glossaries_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.glossaries_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: glossaries_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.glossaries_id_seq OWNED BY public.glossaries.id;


--
-- Name: glossary_entries; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.glossary_entries (
    id bigint NOT NULL,
    glossary_revision_id bigint NOT NULL,
    "position" integer NOT NULL,
    source_term character varying NOT NULL,
    preferred_target_term character varying NOT NULL,
    note character varying,
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL,
    CONSTRAINT glossary_entries_note_check CHECK (((note IS NULL) OR (char_length((note)::text) <= 500))),
    CONSTRAINT glossary_entries_position_check CHECK (("position" > 0)),
    CONSTRAINT glossary_entries_source_term_check CHECK (((char_length(btrim((source_term)::text)) >= 1) AND (char_length(btrim((source_term)::text)) <= 200))),
    CONSTRAINT glossary_entries_target_term_check CHECK (((char_length(btrim((preferred_target_term)::text)) >= 1) AND (char_length(btrim((preferred_target_term)::text)) <= 200)))
);


--
-- Name: glossary_entries_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.glossary_entries_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: glossary_entries_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.glossary_entries_id_seq OWNED BY public.glossary_entries.id;


--
-- Name: glossary_revisions; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.glossary_revisions (
    id bigint NOT NULL,
    glossary_id bigint NOT NULL,
    version integer NOT NULL,
    name character varying NOT NULL,
    description character varying,
    source_language character varying NOT NULL,
    target_language character varying NOT NULL,
    configuration_digest character varying NOT NULL,
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL,
    entry_set_sealed boolean DEFAULT false NOT NULL,
    CONSTRAINT glossary_revisions_description_check CHECK (((description IS NULL) OR (char_length((description)::text) <= 500))),
    CONSTRAINT glossary_revisions_digest_check CHECK ((char_length((configuration_digest)::text) = 64)),
    CONSTRAINT glossary_revisions_name_check CHECK (((char_length(btrim((name)::text)) >= 1) AND (char_length(btrim((name)::text)) <= 150))),
    CONSTRAINT glossary_revisions_source_language_check CHECK (((char_length(btrim((source_language)::text)) >= 1) AND (char_length(btrim((source_language)::text)) <= 100))),
    CONSTRAINT glossary_revisions_target_language_check CHECK (((char_length(btrim((target_language)::text)) >= 1) AND (char_length(btrim((target_language)::text)) <= 100))),
    CONSTRAINT glossary_revisions_version_check CHECK ((version > 0))
);


--
-- Name: glossary_revisions_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.glossary_revisions_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: glossary_revisions_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.glossary_revisions_id_seq OWNED BY public.glossary_revisions.id;


--
-- Name: judge_evaluations; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.judge_evaluations (
    id bigint NOT NULL,
    anonymous_label character varying NOT NULL,
    created_at timestamp(6) without time zone NOT NULL,
    judge_run_id bigint NOT NULL,
    overall_score integer,
    rank integer,
    rationale text,
    risks text,
    strengths text,
    translation_run_id bigint NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL,
    CONSTRAINT judge_evaluations_label_check CHECK (((anonymous_label)::text ~ '^Candidate [A-Z]+$'::text)),
    CONSTRAINT judge_evaluations_overall_score_check CHECK (((overall_score IS NULL) OR ((overall_score >= 1) AND (overall_score <= 100)))),
    CONSTRAINT judge_evaluations_rank_check CHECK (((rank IS NULL) OR (rank > 0)))
);


--
-- Name: judge_evaluations_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.judge_evaluations_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: judge_evaluations_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.judge_evaluations_id_seq OWNED BY public.judge_evaluations.id;


--
-- Name: judge_rounds; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.judge_rounds (
    id bigint NOT NULL,
    aggregate_rankings jsonb DEFAULT '[]'::jsonb NOT NULL,
    aggregation_explanation text,
    created_at timestamp(6) without time zone NOT NULL,
    review_round_id bigint NOT NULL,
    status character varying DEFAULT 'pending'::character varying NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL,
    winner_translation_run_id bigint,
    CONSTRAINT judge_rounds_aggregate_rankings_array_check CHECK ((jsonb_typeof(aggregate_rankings) = 'array'::text)),
    CONSTRAINT judge_rounds_completed_winner_check CHECK ((((status)::text = 'completed'::text) = (winner_translation_run_id IS NOT NULL))),
    CONSTRAINT judge_rounds_status_check CHECK (((status)::text = ANY (ARRAY[('pending'::character varying)::text, ('running'::character varying)::text, ('completed'::character varying)::text, ('failed'::character varying)::text])))
);


--
-- Name: judge_rounds_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.judge_rounds_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: judge_rounds_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.judge_rounds_id_seq OWNED BY public.judge_rounds.id;


--
-- Name: judge_runs; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.judge_runs (
    id bigint NOT NULL,
    cached_tokens bigint,
    completed_at timestamp(6) without time zone,
    completion_tokens bigint,
    confidence_score integer,
    cost numeric(20,10),
    created_at timestamp(6) without time zone NOT NULL,
    error_code character varying,
    error_message text,
    judge_llm_model_id bigint NOT NULL,
    judge_round_id bigint NOT NULL,
    prompt_tokens bigint,
    provider_response_id character varying,
    reasoning_tokens bigint,
    resolved_model_identifier character varying,
    started_at timestamp(6) without time zone,
    status character varying DEFAULT 'pending'::character varying NOT NULL,
    total_tokens bigint,
    updated_at timestamp(6) without time zone NOT NULL,
    winner_rationale text,
    winner_translation_run_id bigint,
    last_claimed_at timestamp(6) without time zone,
    execution_attempt integer DEFAULT 0 NOT NULL,
    scheduled_job_id character varying,
    claimed_job_execution integer DEFAULT 0 NOT NULL,
    pending_since timestamp(6) without time zone,
    context_window_tokens_snapshot integer,
    max_output_tokens_snapshot integer,
    estimated_input_tokens integer,
    reserved_output_tokens integer,
    context_safety_margin_tokens integer,
    budget_policy_version character varying,
    telemetry_complete boolean DEFAULT true NOT NULL,
    cost_complete boolean DEFAULT false NOT NULL,
    CONSTRAINT judge_runs_budget_numbers_check CHECK (((estimated_input_tokens IS NULL) OR ((estimated_input_tokens >= 0) AND (reserved_output_tokens > 0) AND (context_safety_margin_tokens > 0)))),
    CONSTRAINT judge_runs_budget_snapshot_integrity_check CHECK ((((context_window_tokens_snapshot IS NULL) AND (max_output_tokens_snapshot IS NULL) AND (estimated_input_tokens IS NULL) AND (reserved_output_tokens IS NULL) AND (context_safety_margin_tokens IS NULL) AND (budget_policy_version IS NULL)) OR ((context_window_tokens_snapshot IS NOT NULL) AND (max_output_tokens_snapshot IS NOT NULL) AND (estimated_input_tokens IS NOT NULL) AND (reserved_output_tokens IS NOT NULL) AND (context_safety_margin_tokens IS NOT NULL) AND (budget_policy_version IS NOT NULL) AND ((char_length((budget_policy_version)::text) >= 1) AND (char_length((budget_policy_version)::text) <= 100)) AND (max_output_tokens_snapshot < context_window_tokens_snapshot) AND (reserved_output_tokens <= max_output_tokens_snapshot) AND (((estimated_input_tokens + reserved_output_tokens) + context_safety_margin_tokens) <= context_window_tokens_snapshot)))),
    CONSTRAINT judge_runs_cached_tokens_check CHECK (((cached_tokens IS NULL) OR (cached_tokens >= 0))),
    CONSTRAINT judge_runs_claimed_job_execution_check CHECK ((claimed_job_execution >= 0)),
    CONSTRAINT judge_runs_complete_cost_present_check CHECK (((NOT cost_complete) OR (cost IS NOT NULL))),
    CONSTRAINT judge_runs_completion_tokens_check CHECK (((completion_tokens IS NULL) OR (completion_tokens >= 0))),
    CONSTRAINT judge_runs_confidence_score_check CHECK (((confidence_score IS NULL) OR ((confidence_score >= 1) AND (confidence_score <= 100)))),
    CONSTRAINT judge_runs_context_snapshot_check CHECK (((context_window_tokens_snapshot IS NULL) OR ((context_window_tokens_snapshot >= 1024) AND (context_window_tokens_snapshot <= 2000000)))),
    CONSTRAINT judge_runs_cost_check CHECK (((cost IS NULL) OR (cost >= (0)::numeric))),
    CONSTRAINT judge_runs_execution_attempt_check CHECK ((execution_attempt >= 0)),
    CONSTRAINT judge_runs_output_snapshot_check CHECK (((max_output_tokens_snapshot IS NULL) OR ((max_output_tokens_snapshot >= 256) AND (max_output_tokens_snapshot <= 200000)))),
    CONSTRAINT judge_runs_prompt_tokens_check CHECK (((prompt_tokens IS NULL) OR (prompt_tokens >= 0))),
    CONSTRAINT judge_runs_reasoning_tokens_check CHECK (((reasoning_tokens IS NULL) OR (reasoning_tokens >= 0))),
    CONSTRAINT judge_runs_status_check CHECK (((status)::text = ANY (ARRAY[('pending'::character varying)::text, ('running'::character varying)::text, ('completed'::character varying)::text, ('failed'::character varying)::text]))),
    CONSTRAINT judge_runs_total_tokens_check CHECK (((total_tokens IS NULL) OR (total_tokens >= 0))),
    CONSTRAINT judge_runs_winner_status_check CHECK (((winner_translation_run_id IS NULL) OR ((status)::text = 'completed'::text)))
);


--
-- Name: judge_runs_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.judge_runs_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: judge_runs_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.judge_runs_id_seq OWNED BY public.judge_runs.id;


--
-- Name: judge_segment_runs; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.judge_segment_runs (
    id bigint NOT NULL,
    judge_run_id bigint NOT NULL,
    experiment_segment_id bigint NOT NULL,
    status character varying DEFAULT 'pending'::character varying NOT NULL,
    scheduled_job_id character varying,
    claimed_job_execution integer DEFAULT 0 NOT NULL,
    execution_attempt integer DEFAULT 0 NOT NULL,
    pending_since timestamp(6) without time zone,
    last_claimed_at timestamp(6) without time zone,
    started_at timestamp(6) without time zone,
    completed_at timestamp(6) without time zone,
    error_code character varying,
    error_message text,
    provider_response_id character varying,
    resolved_model_identifier character varying,
    prompt_tokens bigint,
    completion_tokens bigint,
    total_tokens bigint,
    cached_tokens bigint,
    reasoning_tokens bigint,
    cost numeric(20,10),
    context_window_tokens_snapshot integer NOT NULL,
    max_output_tokens_snapshot integer NOT NULL,
    estimated_input_tokens integer NOT NULL,
    reserved_output_tokens integer NOT NULL,
    context_safety_margin_tokens integer NOT NULL,
    budget_policy_version character varying NOT NULL,
    judgment jsonb DEFAULT '{}'::jsonb NOT NULL,
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL,
    CONSTRAINT judge_segment_runs_budget_numbers_check CHECK (((estimated_input_tokens >= 0) AND (reserved_output_tokens > 0) AND (context_safety_margin_tokens > 0))),
    CONSTRAINT judge_segment_runs_budget_snapshot_integrity_check CHECK (((char_length((budget_policy_version)::text) >= 1) AND (char_length((budget_policy_version)::text) <= 100) AND (reserved_output_tokens <= max_output_tokens_snapshot) AND (((estimated_input_tokens + reserved_output_tokens) + context_safety_margin_tokens) <= context_window_tokens_snapshot))),
    CONSTRAINT judge_segment_runs_cached_tokens_check CHECK (((cached_tokens IS NULL) OR (cached_tokens >= 0))),
    CONSTRAINT judge_segment_runs_claimed_execution_check CHECK ((claimed_job_execution >= 0)),
    CONSTRAINT judge_segment_runs_completion_tokens_check CHECK (((completion_tokens IS NULL) OR (completion_tokens >= 0))),
    CONSTRAINT judge_segment_runs_context_snapshot_check CHECK (((context_window_tokens_snapshot >= 1024) AND (context_window_tokens_snapshot <= 2000000))),
    CONSTRAINT judge_segment_runs_cost_check CHECK (((cost IS NULL) OR (cost >= (0)::numeric))),
    CONSTRAINT judge_segment_runs_execution_attempt_check CHECK ((execution_attempt >= 0)),
    CONSTRAINT judge_segment_runs_judgment_check CHECK (((jsonb_typeof(judgment) = 'object'::text) AND (octet_length((judgment)::text) <= 100000))),
    CONSTRAINT judge_segment_runs_output_snapshot_check CHECK (((max_output_tokens_snapshot >= 256) AND (max_output_tokens_snapshot <= 200000) AND (max_output_tokens_snapshot < context_window_tokens_snapshot))),
    CONSTRAINT judge_segment_runs_prompt_tokens_check CHECK (((prompt_tokens IS NULL) OR (prompt_tokens >= 0))),
    CONSTRAINT judge_segment_runs_reasoning_tokens_check CHECK (((reasoning_tokens IS NULL) OR (reasoning_tokens >= 0))),
    CONSTRAINT judge_segment_runs_status_check CHECK (((status)::text = ANY (ARRAY[('pending'::character varying)::text, ('running'::character varying)::text, ('completed'::character varying)::text, ('failed'::character varying)::text]))),
    CONSTRAINT judge_segment_runs_total_tokens_check CHECK (((total_tokens IS NULL) OR (total_tokens >= 0)))
);


--
-- Name: judge_segment_runs_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.judge_segment_runs_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: judge_segment_runs_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.judge_segment_runs_id_seq OWNED BY public.judge_segment_runs.id;


--
-- Name: llm_models; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.llm_models (
    id bigint NOT NULL,
    active boolean DEFAULT true NOT NULL,
    created_at timestamp(6) without time zone NOT NULL,
    display_name character varying NOT NULL,
    gateway character varying NOT NULL,
    model_identifier character varying NOT NULL,
    provider character varying NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL,
    context_window_tokens integer,
    max_output_tokens integer,
    CONSTRAINT llm_models_context_capabilities_complete_check CHECK (((context_window_tokens IS NULL) = (max_output_tokens IS NULL))),
    CONSTRAINT llm_models_context_window_tokens_check CHECK (((context_window_tokens IS NULL) OR ((context_window_tokens >= 1024) AND (context_window_tokens <= 2000000)))),
    CONSTRAINT llm_models_max_output_tokens_check CHECK (((max_output_tokens IS NULL) OR ((max_output_tokens >= 256) AND (max_output_tokens <= 200000)))),
    CONSTRAINT llm_models_output_below_context_check CHECK (((context_window_tokens IS NULL) OR (max_output_tokens IS NULL) OR (max_output_tokens < context_window_tokens)))
);


--
-- Name: llm_models_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.llm_models_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: llm_models_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.llm_models_id_seq OWNED BY public.llm_models.id;


--
-- Name: methodology_profile_revisions; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.methodology_profile_revisions (
    id bigint NOT NULL,
    methodology_profile_id bigint NOT NULL,
    version integer NOT NULL,
    name character varying NOT NULL,
    description character varying,
    source_language character varying NOT NULL,
    target_language character varying NOT NULL,
    guidance text NOT NULL,
    configuration_digest character varying NOT NULL,
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL,
    CONSTRAINT methodology_profile_revisions_description_check CHECK (((description IS NULL) OR (char_length((description)::text) <= 500))),
    CONSTRAINT methodology_profile_revisions_digest_check CHECK (((configuration_digest)::text ~ '^[0-9a-f]{64}$'::text)),
    CONSTRAINT methodology_profile_revisions_guidance_check CHECK (((char_length(btrim(guidance)) >= 1) AND (char_length(btrim(guidance)) <= 10000))),
    CONSTRAINT methodology_profile_revisions_name_check CHECK (((char_length(btrim((name)::text)) >= 1) AND (char_length(btrim((name)::text)) <= 150))),
    CONSTRAINT methodology_profile_revisions_payload_digest_check CHECK (((configuration_digest)::text = public.methodology_revision_configuration_digest((source_language)::text, (target_language)::text, guidance))),
    CONSTRAINT methodology_profile_revisions_source_language_check CHECK (((char_length(btrim((source_language)::text)) >= 1) AND (char_length(btrim((source_language)::text)) <= 100))),
    CONSTRAINT methodology_profile_revisions_target_language_check CHECK (((char_length(btrim((target_language)::text)) >= 1) AND (char_length(btrim((target_language)::text)) <= 100))),
    CONSTRAINT methodology_profile_revisions_version_check CHECK ((version > 0))
);


--
-- Name: methodology_profile_revisions_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.methodology_profile_revisions_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: methodology_profile_revisions_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.methodology_profile_revisions_id_seq OWNED BY public.methodology_profile_revisions.id;


--
-- Name: methodology_profiles; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.methodology_profiles (
    id bigint NOT NULL,
    user_id bigint NOT NULL,
    current_revision_id bigint,
    active boolean DEFAULT true NOT NULL,
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL
);


--
-- Name: methodology_profiles_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.methodology_profiles_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: methodology_profiles_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.methodology_profiles_id_seq OWNED BY public.methodology_profiles.id;


--
-- Name: pipeline_events; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.pipeline_events (
    id bigint NOT NULL,
    pipeline_run_id bigint NOT NULL,
    sequence_number integer NOT NULL,
    event_key character varying NOT NULL,
    event_type character varying NOT NULL,
    from_stage character varying,
    to_stage character varying,
    reason_code character varying,
    metadata jsonb DEFAULT '{}'::jsonb NOT NULL,
    created_at timestamp(6) without time zone NOT NULL,
    CONSTRAINT pipeline_events_from_stage_check CHECK (((from_stage IS NULL) OR ((from_stage)::text = ANY (ARRAY[('translation'::character varying)::text, ('review'::character varying)::text, ('judge'::character varying)::text, ('finalization'::character varying)::text, ('editor'::character varying)::text])))),
    CONSTRAINT pipeline_events_key_check CHECK (((char_length((event_key)::text) >= 1) AND (char_length((event_key)::text) <= 120))),
    CONSTRAINT pipeline_events_metadata_check CHECK (((jsonb_typeof(metadata) = 'object'::text) AND (octet_length((metadata)::text) <= 2048))),
    CONSTRAINT pipeline_events_reason_check CHECK (((reason_code IS NULL) OR (char_length((reason_code)::text) <= 80))),
    CONSTRAINT pipeline_events_sequence_check CHECK ((sequence_number > 0)),
    CONSTRAINT pipeline_events_to_stage_check CHECK (((to_stage IS NULL) OR ((to_stage)::text = ANY (ARRAY[('translation'::character varying)::text, ('review'::character varying)::text, ('judge'::character varying)::text, ('finalization'::character varying)::text, ('editor'::character varying)::text])))),
    CONSTRAINT pipeline_events_type_check CHECK (((char_length((event_type)::text) >= 1) AND (char_length((event_type)::text) <= 80)))
);


--
-- Name: pipeline_events_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.pipeline_events_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: pipeline_events_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.pipeline_events_id_seq OWNED BY public.pipeline_events.id;


--
-- Name: pipeline_runs; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.pipeline_runs (
    id bigint NOT NULL,
    experiment_id bigint NOT NULL,
    workflow_profile_revision_id bigint NOT NULL,
    finalization_round_id bigint,
    status character varying DEFAULT 'running'::character varying NOT NULL,
    current_stage character varying DEFAULT 'translation'::character varying NOT NULL,
    blocked_stage character varying,
    blocked_reason_code character varying,
    blocked_message character varying,
    completion_mode character varying NOT NULL,
    translator_count integer NOT NULL,
    reviewer_count integer NOT NULL,
    judge_count integer NOT NULL,
    finalizer_count integer NOT NULL,
    authorized_initial_provider_run_count integer NOT NULL,
    configuration_digest character varying NOT NULL,
    confirmed_at timestamp(6) without time zone NOT NULL,
    started_at timestamp(6) without time zone NOT NULL,
    ready_for_editor_at timestamp(6) without time zone,
    stopped_at timestamp(6) without time zone,
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL,
    last_reconciled_at timestamp(6) without time zone,
    provider_work_plan jsonb DEFAULT '{}'::jsonb NOT NULL,
    CONSTRAINT pipeline_runs_authorized_count_check CHECK ((((provider_work_plan = '{}'::jsonb) AND (authorized_initial_provider_run_count = (((translator_count + reviewer_count) + judge_count) + finalizer_count))) OR ((provider_work_plan <> '{}'::jsonb) AND (jsonb_typeof((provider_work_plan -> 'roles'::text)) = 'object'::text) AND (((provider_work_plan ->> 'authorized_initial_provider_request_slots'::text))::integer = authorized_initial_provider_run_count) AND (authorized_initial_provider_run_count >= (((translator_count + reviewer_count) + judge_count) + finalizer_count))))),
    CONSTRAINT pipeline_runs_blocked_message_check CHECK (((blocked_message IS NULL) OR (char_length((blocked_message)::text) <= 500))),
    CONSTRAINT pipeline_runs_blocked_reason_check CHECK (((blocked_reason_code IS NULL) OR (char_length((blocked_reason_code)::text) <= 80))),
    CONSTRAINT pipeline_runs_blocked_stage_check CHECK (((blocked_stage IS NULL) OR ((blocked_stage)::text = ANY (ARRAY[('translation'::character varying)::text, ('review'::character varying)::text, ('judge'::character varying)::text, ('finalization'::character varying)::text])))),
    CONSTRAINT pipeline_runs_blocked_state_check CHECK ((((status)::text = 'blocked'::text) = ((blocked_stage IS NOT NULL) AND (blocked_reason_code IS NOT NULL)))),
    CONSTRAINT pipeline_runs_completion_finalizer_check CHECK (((((completion_mode)::text = 'winner_draft'::text) AND (finalizer_count = 0)) OR (((completion_mode)::text = 'refinement_proposals'::text) AND (finalizer_count > 0)))),
    CONSTRAINT pipeline_runs_completion_mode_check CHECK (((completion_mode)::text = ANY (ARRAY[('winner_draft'::character varying)::text, ('refinement_proposals'::character varying)::text]))),
    CONSTRAINT pipeline_runs_current_stage_check CHECK (((current_stage)::text = ANY (ARRAY[('translation'::character varying)::text, ('review'::character varying)::text, ('judge'::character varying)::text, ('finalization'::character varying)::text, ('editor'::character varying)::text]))),
    CONSTRAINT pipeline_runs_digest_check CHECK ((char_length((configuration_digest)::text) = 64)),
    CONSTRAINT pipeline_runs_provider_work_plan_check CHECK (((jsonb_typeof(provider_work_plan) = 'object'::text) AND (octet_length((provider_work_plan)::text) <= 16384))),
    CONSTRAINT pipeline_runs_ready_timestamp_check CHECK ((((status)::text = 'ready_for_editor'::text) = (ready_for_editor_at IS NOT NULL))),
    CONSTRAINT pipeline_runs_role_counts_check CHECK (((translator_count >= 2) AND (translator_count <= 6) AND ((reviewer_count >= 1) AND (reviewer_count <= 5)) AND ((judge_count >= 1) AND (judge_count <= 5)) AND ((finalizer_count >= 0) AND (finalizer_count <= 5)))),
    CONSTRAINT pipeline_runs_status_check CHECK (((status)::text = ANY (ARRAY[('running'::character varying)::text, ('blocked'::character varying)::text, ('ready_for_editor'::character varying)::text, ('stopped'::character varying)::text]))),
    CONSTRAINT pipeline_runs_stopped_timestamp_check CHECK ((((status)::text = 'stopped'::text) = (stopped_at IS NOT NULL)))
);


--
-- Name: pipeline_runs_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.pipeline_runs_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: pipeline_runs_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.pipeline_runs_id_seq OWNED BY public.pipeline_runs.id;


--
-- Name: projects; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.projects (
    id bigint NOT NULL,
    created_at timestamp(6) without time zone NOT NULL,
    description text,
    name character varying NOT NULL,
    source_language character varying NOT NULL,
    target_language character varying NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL,
    user_id bigint NOT NULL
);


--
-- Name: projects_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.projects_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: projects_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.projects_id_seq OWNED BY public.projects.id;


--
-- Name: review_evaluations; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.review_evaluations (
    id bigint NOT NULL,
    anonymous_label character varying NOT NULL,
    created_at timestamp(6) without time zone NOT NULL,
    faithfulness_score integer,
    instruction_adherence_score integer,
    issues text,
    naturalness_score integer,
    overall_score integer,
    recommended_corrections text,
    review_run_id bigint NOT NULL,
    strengths text,
    suggested_translation text,
    terminology_score integer,
    translation_run_id bigint NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL,
    CONSTRAINT review_evaluations_faithfulness_score_check CHECK (((faithfulness_score IS NULL) OR ((faithfulness_score >= 1) AND (faithfulness_score <= 10)))),
    CONSTRAINT review_evaluations_instruction_adherence_score_check CHECK (((instruction_adherence_score IS NULL) OR ((instruction_adherence_score >= 1) AND (instruction_adherence_score <= 10)))),
    CONSTRAINT review_evaluations_label_check CHECK (((anonymous_label)::text ~ '^Candidate [A-Z]+$'::text)),
    CONSTRAINT review_evaluations_naturalness_score_check CHECK (((naturalness_score IS NULL) OR ((naturalness_score >= 1) AND (naturalness_score <= 10)))),
    CONSTRAINT review_evaluations_overall_score_check CHECK (((overall_score IS NULL) OR ((overall_score >= 1) AND (overall_score <= 10)))),
    CONSTRAINT review_evaluations_terminology_score_check CHECK (((terminology_score IS NULL) OR ((terminology_score >= 1) AND (terminology_score <= 10))))
);


--
-- Name: review_evaluations_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.review_evaluations_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: review_evaluations_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.review_evaluations_id_seq OWNED BY public.review_evaluations.id;


--
-- Name: review_rounds; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.review_rounds (
    id bigint NOT NULL,
    created_at timestamp(6) without time zone NOT NULL,
    experiment_id bigint NOT NULL,
    status character varying DEFAULT 'pending'::character varying NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL,
    CONSTRAINT review_rounds_status_check CHECK (((status)::text = ANY (ARRAY[('pending'::character varying)::text, ('running'::character varying)::text, ('completed'::character varying)::text, ('failed'::character varying)::text])))
);


--
-- Name: review_rounds_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.review_rounds_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: review_rounds_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.review_rounds_id_seq OWNED BY public.review_rounds.id;


--
-- Name: review_runs; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.review_runs (
    id bigint NOT NULL,
    cached_tokens bigint,
    completed_at timestamp(6) without time zone,
    completion_tokens bigint,
    cost numeric(20,10),
    created_at timestamp(6) without time zone NOT NULL,
    error_code character varying,
    error_message text,
    prompt_tokens bigint,
    provider_response_id character varying,
    reasoning_tokens bigint,
    resolved_model_identifier character varying,
    review_round_id bigint NOT NULL,
    reviewer_llm_model_id bigint NOT NULL,
    started_at timestamp(6) without time zone,
    status character varying DEFAULT 'pending'::character varying NOT NULL,
    total_tokens bigint,
    updated_at timestamp(6) without time zone NOT NULL,
    last_claimed_at timestamp(6) without time zone,
    execution_attempt integer DEFAULT 0 NOT NULL,
    scheduled_job_id character varying,
    claimed_job_execution integer DEFAULT 0 NOT NULL,
    pending_since timestamp(6) without time zone,
    context_window_tokens_snapshot integer,
    max_output_tokens_snapshot integer,
    estimated_input_tokens integer,
    reserved_output_tokens integer,
    context_safety_margin_tokens integer,
    budget_policy_version character varying,
    telemetry_complete boolean DEFAULT true NOT NULL,
    cost_complete boolean DEFAULT false NOT NULL,
    CONSTRAINT review_runs_budget_numbers_check CHECK (((estimated_input_tokens IS NULL) OR ((estimated_input_tokens >= 0) AND (reserved_output_tokens > 0) AND (context_safety_margin_tokens > 0)))),
    CONSTRAINT review_runs_budget_snapshot_integrity_check CHECK ((((context_window_tokens_snapshot IS NULL) AND (max_output_tokens_snapshot IS NULL) AND (estimated_input_tokens IS NULL) AND (reserved_output_tokens IS NULL) AND (context_safety_margin_tokens IS NULL) AND (budget_policy_version IS NULL)) OR ((context_window_tokens_snapshot IS NOT NULL) AND (max_output_tokens_snapshot IS NOT NULL) AND (estimated_input_tokens IS NOT NULL) AND (reserved_output_tokens IS NOT NULL) AND (context_safety_margin_tokens IS NOT NULL) AND (budget_policy_version IS NOT NULL) AND ((char_length((budget_policy_version)::text) >= 1) AND (char_length((budget_policy_version)::text) <= 100)) AND (max_output_tokens_snapshot < context_window_tokens_snapshot) AND (reserved_output_tokens <= max_output_tokens_snapshot) AND (((estimated_input_tokens + reserved_output_tokens) + context_safety_margin_tokens) <= context_window_tokens_snapshot)))),
    CONSTRAINT review_runs_cached_tokens_check CHECK (((cached_tokens IS NULL) OR (cached_tokens >= 0))),
    CONSTRAINT review_runs_claimed_job_execution_check CHECK ((claimed_job_execution >= 0)),
    CONSTRAINT review_runs_complete_cost_present_check CHECK (((NOT cost_complete) OR (cost IS NOT NULL))),
    CONSTRAINT review_runs_completion_tokens_check CHECK (((completion_tokens IS NULL) OR (completion_tokens >= 0))),
    CONSTRAINT review_runs_context_snapshot_check CHECK (((context_window_tokens_snapshot IS NULL) OR ((context_window_tokens_snapshot >= 1024) AND (context_window_tokens_snapshot <= 2000000)))),
    CONSTRAINT review_runs_cost_check CHECK (((cost IS NULL) OR (cost >= (0)::numeric))),
    CONSTRAINT review_runs_execution_attempt_check CHECK ((execution_attempt >= 0)),
    CONSTRAINT review_runs_output_snapshot_check CHECK (((max_output_tokens_snapshot IS NULL) OR ((max_output_tokens_snapshot >= 256) AND (max_output_tokens_snapshot <= 200000)))),
    CONSTRAINT review_runs_prompt_tokens_check CHECK (((prompt_tokens IS NULL) OR (prompt_tokens >= 0))),
    CONSTRAINT review_runs_reasoning_tokens_check CHECK (((reasoning_tokens IS NULL) OR (reasoning_tokens >= 0))),
    CONSTRAINT review_runs_status_check CHECK (((status)::text = ANY (ARRAY[('pending'::character varying)::text, ('running'::character varying)::text, ('completed'::character varying)::text, ('failed'::character varying)::text]))),
    CONSTRAINT review_runs_total_tokens_check CHECK (((total_tokens IS NULL) OR (total_tokens >= 0)))
);


--
-- Name: review_runs_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.review_runs_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: review_runs_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.review_runs_id_seq OWNED BY public.review_runs.id;


--
-- Name: review_segment_runs; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.review_segment_runs (
    id bigint NOT NULL,
    review_run_id bigint NOT NULL,
    experiment_segment_id bigint NOT NULL,
    status character varying DEFAULT 'pending'::character varying NOT NULL,
    scheduled_job_id character varying,
    claimed_job_execution integer DEFAULT 0 NOT NULL,
    execution_attempt integer DEFAULT 0 NOT NULL,
    pending_since timestamp(6) without time zone,
    last_claimed_at timestamp(6) without time zone,
    started_at timestamp(6) without time zone,
    completed_at timestamp(6) without time zone,
    error_code character varying,
    error_message text,
    provider_response_id character varying,
    resolved_model_identifier character varying,
    prompt_tokens bigint,
    completion_tokens bigint,
    total_tokens bigint,
    cached_tokens bigint,
    reasoning_tokens bigint,
    cost numeric(20,10),
    context_window_tokens_snapshot integer NOT NULL,
    max_output_tokens_snapshot integer NOT NULL,
    estimated_input_tokens integer NOT NULL,
    reserved_output_tokens integer NOT NULL,
    context_safety_margin_tokens integer NOT NULL,
    budget_policy_version character varying NOT NULL,
    evaluations jsonb DEFAULT '[]'::jsonb NOT NULL,
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL,
    CONSTRAINT review_segment_runs_budget_numbers_check CHECK (((estimated_input_tokens >= 0) AND (reserved_output_tokens > 0) AND (context_safety_margin_tokens > 0))),
    CONSTRAINT review_segment_runs_budget_snapshot_integrity_check CHECK (((char_length((budget_policy_version)::text) >= 1) AND (char_length((budget_policy_version)::text) <= 100) AND (reserved_output_tokens <= max_output_tokens_snapshot) AND (((estimated_input_tokens + reserved_output_tokens) + context_safety_margin_tokens) <= context_window_tokens_snapshot))),
    CONSTRAINT review_segment_runs_cached_tokens_check CHECK (((cached_tokens IS NULL) OR (cached_tokens >= 0))),
    CONSTRAINT review_segment_runs_claimed_execution_check CHECK ((claimed_job_execution >= 0)),
    CONSTRAINT review_segment_runs_completion_tokens_check CHECK (((completion_tokens IS NULL) OR (completion_tokens >= 0))),
    CONSTRAINT review_segment_runs_context_snapshot_check CHECK (((context_window_tokens_snapshot >= 1024) AND (context_window_tokens_snapshot <= 2000000))),
    CONSTRAINT review_segment_runs_cost_check CHECK (((cost IS NULL) OR (cost >= (0)::numeric))),
    CONSTRAINT review_segment_runs_evaluations_check CHECK (((jsonb_typeof(evaluations) = 'array'::text) AND (octet_length((evaluations)::text) <= 100000))),
    CONSTRAINT review_segment_runs_execution_attempt_check CHECK ((execution_attempt >= 0)),
    CONSTRAINT review_segment_runs_output_snapshot_check CHECK (((max_output_tokens_snapshot >= 256) AND (max_output_tokens_snapshot <= 200000) AND (max_output_tokens_snapshot < context_window_tokens_snapshot))),
    CONSTRAINT review_segment_runs_prompt_tokens_check CHECK (((prompt_tokens IS NULL) OR (prompt_tokens >= 0))),
    CONSTRAINT review_segment_runs_reasoning_tokens_check CHECK (((reasoning_tokens IS NULL) OR (reasoning_tokens >= 0))),
    CONSTRAINT review_segment_runs_status_check CHECK (((status)::text = ANY (ARRAY[('pending'::character varying)::text, ('running'::character varying)::text, ('completed'::character varying)::text, ('failed'::character varying)::text]))),
    CONSTRAINT review_segment_runs_total_tokens_check CHECK (((total_tokens IS NULL) OR (total_tokens >= 0)))
);


--
-- Name: review_segment_runs_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.review_segment_runs_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: review_segment_runs_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.review_segment_runs_id_seq OWNED BY public.review_segment_runs.id;


--
-- Name: schema_migrations; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.schema_migrations (
    version character varying NOT NULL
);


--
-- Name: sessions; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.sessions (
    id bigint NOT NULL,
    user_id bigint NOT NULL,
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL
);


--
-- Name: sessions_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.sessions_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: sessions_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.sessions_id_seq OWNED BY public.sessions.id;


--
-- Name: source_imports; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.source_imports (
    id bigint NOT NULL,
    user_id bigint NOT NULL,
    resulting_document_id bigint,
    status character varying DEFAULT 'pending'::character varying NOT NULL,
    original_filename character varying NOT NULL,
    detected_content_type character varying,
    imported_format character varying,
    byte_size bigint,
    sha256 character varying,
    extracted_text text,
    extraction_version character varying,
    failure_code character varying,
    failure_message character varying,
    expires_at timestamp(6) without time zone NOT NULL,
    consumed_at timestamp(6) without time zone,
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL,
    request_key character varying,
    CONSTRAINT source_imports_byte_size_check CHECK (((byte_size IS NULL) OR ((byte_size >= 0) AND (byte_size <= 10485760)))),
    CONSTRAINT source_imports_consumed_at_check CHECK ((((status)::text = 'consumed'::text) = (consumed_at IS NOT NULL))),
    CONSTRAINT source_imports_consumed_document_check CHECK ((((status)::text <> 'consumed'::text) OR (resulting_document_id IS NOT NULL))),
    CONSTRAINT source_imports_format_check CHECK (((imported_format IS NULL) OR ((imported_format)::text = ANY (ARRAY[('txt'::character varying)::text, ('md'::character varying)::text, ('docx'::character varying)::text, ('pdf'::character varying)::text])))),
    CONSTRAINT source_imports_ready_text_check CHECK ((((status)::text <> 'ready'::text) OR (extracted_text IS NOT NULL))),
    CONSTRAINT source_imports_request_key_check CHECK (((request_key IS NULL) OR ((request_key)::text ~ '^[0-9a-f]{32}$'::text))),
    CONSTRAINT source_imports_sha256_check CHECK (((sha256 IS NULL) OR (char_length((sha256)::text) = 64))),
    CONSTRAINT source_imports_status_check CHECK (((status)::text = ANY (ARRAY[('pending'::character varying)::text, ('ready'::character varying)::text, ('failed'::character varying)::text, ('consumed'::character varying)::text])))
);


--
-- Name: source_imports_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.source_imports_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: source_imports_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.source_imports_id_seq OWNED BY public.source_imports.id;


--
-- Name: translation_reference_revisions; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.translation_reference_revisions (
    id bigint NOT NULL,
    translation_reference_id bigint NOT NULL,
    version integer NOT NULL,
    title character varying NOT NULL,
    source_language character varying NOT NULL,
    target_language character varying NOT NULL,
    source_text text NOT NULL,
    approved_translation text NOT NULL,
    configuration_digest character varying NOT NULL,
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL,
    CONSTRAINT translation_reference_revisions_approved_translation_check CHECK (((char_length(btrim(approved_translation)) >= 1) AND (char_length(btrim(approved_translation)) <= 100000))),
    CONSTRAINT translation_reference_revisions_digest_check CHECK (((configuration_digest)::text ~ '^[0-9a-f]{64}$'::text)),
    CONSTRAINT translation_reference_revisions_payload_digest_check CHECK (((configuration_digest)::text = public.translation_reference_revision_configuration_digest((source_language)::text, (target_language)::text, source_text, approved_translation))),
    CONSTRAINT translation_reference_revisions_source_language_check CHECK (((char_length(btrim((source_language)::text)) >= 1) AND (char_length(btrim((source_language)::text)) <= 100))),
    CONSTRAINT translation_reference_revisions_source_text_check CHECK (((char_length(btrim(source_text)) >= 1) AND (char_length(btrim(source_text)) <= 100000))),
    CONSTRAINT translation_reference_revisions_target_language_check CHECK (((char_length(btrim((target_language)::text)) >= 1) AND (char_length(btrim((target_language)::text)) <= 100))),
    CONSTRAINT translation_reference_revisions_title_check CHECK (((char_length(btrim((title)::text)) >= 1) AND (char_length(btrim((title)::text)) <= 150))),
    CONSTRAINT translation_reference_revisions_version_check CHECK ((version > 0))
);


--
-- Name: translation_reference_revisions_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.translation_reference_revisions_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: translation_reference_revisions_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.translation_reference_revisions_id_seq OWNED BY public.translation_reference_revisions.id;


--
-- Name: translation_references; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.translation_references (
    id bigint NOT NULL,
    user_id bigint NOT NULL,
    current_revision_id bigint,
    active boolean DEFAULT true NOT NULL,
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL
);


--
-- Name: translation_references_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.translation_references_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: translation_references_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.translation_references_id_seq OWNED BY public.translation_references.id;


--
-- Name: translation_runs; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.translation_runs (
    id bigint NOT NULL,
    cached_tokens bigint,
    completed_at timestamp(6) without time zone,
    completion_tokens bigint,
    cost numeric(20,10),
    created_at timestamp(6) without time zone NOT NULL,
    error_code character varying,
    error_message text,
    experiment_id bigint NOT NULL,
    llm_model_id bigint NOT NULL,
    prompt_tokens bigint,
    provider_response_id character varying,
    reasoning_tokens bigint,
    resolved_model_identifier character varying,
    started_at timestamp(6) without time zone,
    status character varying DEFAULT 'pending'::character varying NOT NULL,
    total_tokens bigint,
    translated_text text,
    updated_at timestamp(6) without time zone NOT NULL,
    last_claimed_at timestamp(6) without time zone,
    execution_attempt integer DEFAULT 0 NOT NULL,
    scheduled_job_id character varying,
    claimed_job_execution integer DEFAULT 0 NOT NULL,
    pending_since timestamp(6) without time zone,
    context_window_tokens_snapshot integer,
    max_output_tokens_snapshot integer,
    estimated_input_tokens integer,
    reserved_output_tokens integer,
    context_safety_margin_tokens integer,
    budget_policy_version character varying,
    telemetry_complete boolean DEFAULT true NOT NULL,
    cost_complete boolean DEFAULT false NOT NULL,
    CONSTRAINT translation_runs_budget_numbers_check CHECK (((estimated_input_tokens IS NULL) OR ((estimated_input_tokens >= 0) AND (reserved_output_tokens > 0) AND (context_safety_margin_tokens > 0)))),
    CONSTRAINT translation_runs_budget_snapshot_integrity_check CHECK ((((context_window_tokens_snapshot IS NULL) AND (max_output_tokens_snapshot IS NULL) AND (estimated_input_tokens IS NULL) AND (reserved_output_tokens IS NULL) AND (context_safety_margin_tokens IS NULL) AND (budget_policy_version IS NULL)) OR ((context_window_tokens_snapshot IS NOT NULL) AND (max_output_tokens_snapshot IS NOT NULL) AND (estimated_input_tokens IS NOT NULL) AND (reserved_output_tokens IS NOT NULL) AND (context_safety_margin_tokens IS NOT NULL) AND (budget_policy_version IS NOT NULL) AND ((char_length((budget_policy_version)::text) >= 1) AND (char_length((budget_policy_version)::text) <= 100)) AND (max_output_tokens_snapshot < context_window_tokens_snapshot) AND (reserved_output_tokens <= max_output_tokens_snapshot) AND (((estimated_input_tokens + reserved_output_tokens) + context_safety_margin_tokens) <= context_window_tokens_snapshot)))),
    CONSTRAINT translation_runs_claimed_job_execution_check CHECK ((claimed_job_execution >= 0)),
    CONSTRAINT translation_runs_complete_cost_present_check CHECK (((NOT cost_complete) OR (cost IS NOT NULL))),
    CONSTRAINT translation_runs_context_snapshot_check CHECK (((context_window_tokens_snapshot IS NULL) OR ((context_window_tokens_snapshot >= 1024) AND (context_window_tokens_snapshot <= 2000000)))),
    CONSTRAINT translation_runs_execution_attempt_check CHECK ((execution_attempt >= 0)),
    CONSTRAINT translation_runs_output_length_check CHECK (((translated_text IS NULL) OR (char_length(translated_text) <= 100000))),
    CONSTRAINT translation_runs_output_snapshot_check CHECK (((max_output_tokens_snapshot IS NULL) OR ((max_output_tokens_snapshot >= 256) AND (max_output_tokens_snapshot <= 200000))))
);


--
-- Name: translation_runs_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.translation_runs_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: translation_runs_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.translation_runs_id_seq OWNED BY public.translation_runs.id;


--
-- Name: translation_segment_runs; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.translation_segment_runs (
    id bigint NOT NULL,
    translation_run_id bigint NOT NULL,
    experiment_segment_id bigint NOT NULL,
    status character varying DEFAULT 'pending'::character varying NOT NULL,
    scheduled_job_id character varying,
    claimed_job_execution integer DEFAULT 0 NOT NULL,
    execution_attempt integer DEFAULT 0 NOT NULL,
    pending_since timestamp(6) without time zone,
    last_claimed_at timestamp(6) without time zone,
    started_at timestamp(6) without time zone,
    completed_at timestamp(6) without time zone,
    error_code character varying,
    error_message text,
    provider_response_id character varying,
    resolved_model_identifier character varying,
    prompt_tokens bigint,
    completion_tokens bigint,
    total_tokens bigint,
    cached_tokens bigint,
    reasoning_tokens bigint,
    cost numeric(20,10),
    context_window_tokens_snapshot integer NOT NULL,
    max_output_tokens_snapshot integer NOT NULL,
    estimated_input_tokens integer NOT NULL,
    reserved_output_tokens integer NOT NULL,
    context_safety_margin_tokens integer NOT NULL,
    budget_policy_version character varying NOT NULL,
    translated_text text,
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL,
    CONSTRAINT translation_segment_runs_budget_numbers_check CHECK (((estimated_input_tokens >= 0) AND (reserved_output_tokens > 0) AND (context_safety_margin_tokens > 0))),
    CONSTRAINT translation_segment_runs_budget_snapshot_integrity_check CHECK (((char_length((budget_policy_version)::text) >= 1) AND (char_length((budget_policy_version)::text) <= 100) AND (reserved_output_tokens <= max_output_tokens_snapshot) AND (((estimated_input_tokens + reserved_output_tokens) + context_safety_margin_tokens) <= context_window_tokens_snapshot))),
    CONSTRAINT translation_segment_runs_cached_tokens_check CHECK (((cached_tokens IS NULL) OR (cached_tokens >= 0))),
    CONSTRAINT translation_segment_runs_claimed_execution_check CHECK ((claimed_job_execution >= 0)),
    CONSTRAINT translation_segment_runs_completion_tokens_check CHECK (((completion_tokens IS NULL) OR (completion_tokens >= 0))),
    CONSTRAINT translation_segment_runs_context_snapshot_check CHECK (((context_window_tokens_snapshot >= 1024) AND (context_window_tokens_snapshot <= 2000000))),
    CONSTRAINT translation_segment_runs_cost_check CHECK (((cost IS NULL) OR (cost >= (0)::numeric))),
    CONSTRAINT translation_segment_runs_execution_attempt_check CHECK ((execution_attempt >= 0)),
    CONSTRAINT translation_segment_runs_output_length_check CHECK (((translated_text IS NULL) OR (char_length(translated_text) <= 20000))),
    CONSTRAINT translation_segment_runs_output_snapshot_check CHECK (((max_output_tokens_snapshot >= 256) AND (max_output_tokens_snapshot <= 200000) AND (max_output_tokens_snapshot < context_window_tokens_snapshot))),
    CONSTRAINT translation_segment_runs_prompt_tokens_check CHECK (((prompt_tokens IS NULL) OR (prompt_tokens >= 0))),
    CONSTRAINT translation_segment_runs_reasoning_tokens_check CHECK (((reasoning_tokens IS NULL) OR (reasoning_tokens >= 0))),
    CONSTRAINT translation_segment_runs_status_check CHECK (((status)::text = ANY (ARRAY[('pending'::character varying)::text, ('running'::character varying)::text, ('completed'::character varying)::text, ('failed'::character varying)::text]))),
    CONSTRAINT translation_segment_runs_total_tokens_check CHECK (((total_tokens IS NULL) OR (total_tokens >= 0)))
);


--
-- Name: translation_segment_runs_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.translation_segment_runs_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: translation_segment_runs_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.translation_segment_runs_id_seq OWNED BY public.translation_segment_runs.id;


--
-- Name: translation_workspace_drafts; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.translation_workspace_drafts (
    id bigint NOT NULL,
    user_id bigint NOT NULL,
    public_id character varying NOT NULL,
    context_key character varying NOT NULL,
    workspace_payload text NOT NULL,
    lock_version integer DEFAULT 0 NOT NULL,
    expires_at timestamp(6) without time zone NOT NULL,
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL,
    editor_id character varying,
    editor_sequence bigint,
    CONSTRAINT workspace_drafts_context_key_check CHECK ((char_length((context_key)::text) <= 80)),
    CONSTRAINT workspace_drafts_editor_id_check CHECK (((editor_id IS NULL) OR ((editor_id)::text ~ '^[0-9a-f]{32}$'::text))),
    CONSTRAINT workspace_drafts_editor_pair_check CHECK (((editor_id IS NULL) = (editor_sequence IS NULL))),
    CONSTRAINT workspace_drafts_editor_sequence_check CHECK (((editor_sequence IS NULL) OR (editor_sequence > 0))),
    CONSTRAINT workspace_drafts_lock_version_check CHECK ((lock_version >= 0))
);


--
-- Name: translation_workspace_drafts_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.translation_workspace_drafts_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: translation_workspace_drafts_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.translation_workspace_drafts_id_seq OWNED BY public.translation_workspace_drafts.id;


--
-- Name: translation_workspace_submissions; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.translation_workspace_submissions (
    id bigint NOT NULL,
    user_id bigint NOT NULL,
    experiment_id bigint,
    token_digest character varying NOT NULL,
    status character varying DEFAULT 'available'::character varying NOT NULL,
    expires_at timestamp(6) without time zone NOT NULL,
    consumed_at timestamp(6) without time zone,
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL,
    CONSTRAINT translation_workspace_submissions_digest_check CHECK ((char_length((token_digest)::text) = 64)),
    CONSTRAINT translation_workspace_submissions_expiry_check CHECK ((expires_at > created_at)),
    CONSTRAINT translation_workspace_submissions_lifecycle_check CHECK (((((status)::text = 'available'::text) AND (consumed_at IS NULL) AND (experiment_id IS NULL)) OR (((status)::text = 'consumed'::text) AND (consumed_at IS NOT NULL) AND (experiment_id IS NOT NULL)))),
    CONSTRAINT translation_workspace_submissions_status_check CHECK (((status)::text = ANY (ARRAY[('available'::character varying)::text, ('consumed'::character varying)::text])))
);


--
-- Name: translation_workspace_submissions_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.translation_workspace_submissions_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: translation_workspace_submissions_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.translation_workspace_submissions_id_seq OWNED BY public.translation_workspace_submissions.id;


--
-- Name: users; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.users (
    id bigint NOT NULL,
    created_at timestamp(6) without time zone NOT NULL,
    email character varying NOT NULL,
    password_digest character varying,
    role character varying DEFAULT 'user'::character varying NOT NULL,
    status character varying DEFAULT 'active'::character varying NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL,
    email_verified_at timestamp(6) without time zone,
    confirmation_sent_at timestamp(6) without time zone,
    locale character varying DEFAULT 'en'::character varying NOT NULL,
    managed_ai_access boolean DEFAULT false NOT NULL,
    appearance character varying DEFAULT 'system'::character varying NOT NULL,
    CONSTRAINT users_appearance_check CHECK (((appearance)::text = ANY (ARRAY[('system'::character varying)::text, ('light'::character varying)::text, ('dark'::character varying)::text]))),
    CONSTRAINT users_locale_check CHECK (((locale)::text = ANY (ARRAY[('en'::character varying)::text, ('vi'::character varying)::text, ('ja'::character varying)::text]))),
    CONSTRAINT users_normalized_email_check CHECK ((((email)::text = lower(btrim((email)::text))) AND (char_length((email)::text) >= 3) AND (char_length((email)::text) <= 254))),
    CONSTRAINT users_role_check CHECK (((role)::text = ANY (ARRAY[('user'::character varying)::text, ('admin'::character varying)::text]))),
    CONSTRAINT users_status_check CHECK (((status)::text = ANY (ARRAY[('active'::character varying)::text, ('disabled'::character varying)::text])))
);


--
-- Name: users_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.users_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: users_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.users_id_seq OWNED BY public.users.id;


--
-- Name: workflow_profile_model_selections; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.workflow_profile_model_selections (
    id bigint NOT NULL,
    workflow_profile_revision_id bigint NOT NULL,
    llm_model_id bigint NOT NULL,
    role character varying NOT NULL,
    "position" integer NOT NULL,
    gateway_snapshot character varying NOT NULL,
    provider_snapshot character varying NOT NULL,
    model_identifier_snapshot character varying NOT NULL,
    display_name_snapshot character varying NOT NULL,
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL,
    CONSTRAINT workflow_profile_model_selections_position_check CHECK (("position" > 0)),
    CONSTRAINT workflow_profile_model_selections_role_check CHECK (((role)::text = ANY (ARRAY[('translator'::character varying)::text, ('reviewer'::character varying)::text, ('judge'::character varying)::text, ('finalizer'::character varying)::text]))),
    CONSTRAINT workflow_profile_selections_display_name_check CHECK (((char_length((display_name_snapshot)::text) >= 1) AND (char_length((display_name_snapshot)::text) <= 150))),
    CONSTRAINT workflow_profile_selections_gateway_check CHECK (((char_length((gateway_snapshot)::text) >= 1) AND (char_length((gateway_snapshot)::text) <= 50))),
    CONSTRAINT workflow_profile_selections_identifier_check CHECK (((char_length((model_identifier_snapshot)::text) >= 1) AND (char_length((model_identifier_snapshot)::text) <= 255))),
    CONSTRAINT workflow_profile_selections_provider_check CHECK (((char_length((provider_snapshot)::text) >= 1) AND (char_length((provider_snapshot)::text) <= 100)))
);


--
-- Name: workflow_profile_model_selections_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.workflow_profile_model_selections_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: workflow_profile_model_selections_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.workflow_profile_model_selections_id_seq OWNED BY public.workflow_profile_model_selections.id;


--
-- Name: workflow_profile_revisions; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.workflow_profile_revisions (
    id bigint NOT NULL,
    workflow_profile_id bigint NOT NULL,
    version integer NOT NULL,
    name character varying NOT NULL,
    description character varying,
    completion_mode character varying NOT NULL,
    configuration_digest character varying NOT NULL,
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL,
    CONSTRAINT workflow_profile_revisions_completion_mode_check CHECK (((completion_mode)::text = ANY (ARRAY[('winner_draft'::character varying)::text, ('refinement_proposals'::character varying)::text]))),
    CONSTRAINT workflow_profile_revisions_description_check CHECK (((description IS NULL) OR (char_length((description)::text) <= 500))),
    CONSTRAINT workflow_profile_revisions_digest_check CHECK ((char_length((configuration_digest)::text) = 64)),
    CONSTRAINT workflow_profile_revisions_name_check CHECK (((char_length(btrim((name)::text)) >= 1) AND (char_length(btrim((name)::text)) <= 150))),
    CONSTRAINT workflow_profile_revisions_version_check CHECK ((version > 0))
);


--
-- Name: workflow_profile_revisions_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.workflow_profile_revisions_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: workflow_profile_revisions_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.workflow_profile_revisions_id_seq OWNED BY public.workflow_profile_revisions.id;


--
-- Name: workflow_profiles; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.workflow_profiles (
    id bigint NOT NULL,
    user_id bigint NOT NULL,
    current_revision_id bigint,
    active boolean DEFAULT true NOT NULL,
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL
);


--
-- Name: workflow_profiles_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.workflow_profiles_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: workflow_profiles_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.workflow_profiles_id_seq OWNED BY public.workflow_profiles.id;


--
-- Name: active_storage_attachments id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.active_storage_attachments ALTER COLUMN id SET DEFAULT nextval('public.active_storage_attachments_id_seq'::regclass);


--
-- Name: active_storage_blobs id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.active_storage_blobs ALTER COLUMN id SET DEFAULT nextval('public.active_storage_blobs_id_seq'::regclass);


--
-- Name: active_storage_variant_records id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.active_storage_variant_records ALTER COLUMN id SET DEFAULT nextval('public.active_storage_variant_records_id_seq'::regclass);


--
-- Name: ai_provider_attempts id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.ai_provider_attempts ALTER COLUMN id SET DEFAULT nextval('public.ai_provider_attempts_id_seq'::regclass);


--
-- Name: document_execution_plans id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.document_execution_plans ALTER COLUMN id SET DEFAULT nextval('public.document_execution_plans_id_seq'::regclass);


--
-- Name: documents id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.documents ALTER COLUMN id SET DEFAULT nextval('public.documents_id_seq'::regclass);


--
-- Name: experiment_reference_revisions id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.experiment_reference_revisions ALTER COLUMN id SET DEFAULT nextval('public.experiment_reference_revisions_id_seq'::regclass);


--
-- Name: experiment_segments id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.experiment_segments ALTER COLUMN id SET DEFAULT nextval('public.experiment_segments_id_seq'::regclass);


--
-- Name: experiments id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.experiments ALTER COLUMN id SET DEFAULT nextval('public.experiments_id_seq'::regclass);


--
-- Name: federated_identities id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.federated_identities ALTER COLUMN id SET DEFAULT nextval('public.federated_identities_id_seq'::regclass);


--
-- Name: final_translation_version_segments id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.final_translation_version_segments ALTER COLUMN id SET DEFAULT nextval('public.final_translation_version_segments_id_seq'::regclass);


--
-- Name: final_translation_versions id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.final_translation_versions ALTER COLUMN id SET DEFAULT nextval('public.final_translation_versions_id_seq'::regclass);


--
-- Name: final_translations id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.final_translations ALTER COLUMN id SET DEFAULT nextval('public.final_translations_id_seq'::regclass);


--
-- Name: finalization_rounds id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.finalization_rounds ALTER COLUMN id SET DEFAULT nextval('public.finalization_rounds_id_seq'::regclass);


--
-- Name: finalization_runs id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.finalization_runs ALTER COLUMN id SET DEFAULT nextval('public.finalization_runs_id_seq'::regclass);


--
-- Name: finalization_segment_runs id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.finalization_segment_runs ALTER COLUMN id SET DEFAULT nextval('public.finalization_segment_runs_id_seq'::regclass);


--
-- Name: glossaries id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.glossaries ALTER COLUMN id SET DEFAULT nextval('public.glossaries_id_seq'::regclass);


--
-- Name: glossary_entries id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.glossary_entries ALTER COLUMN id SET DEFAULT nextval('public.glossary_entries_id_seq'::regclass);


--
-- Name: glossary_revisions id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.glossary_revisions ALTER COLUMN id SET DEFAULT nextval('public.glossary_revisions_id_seq'::regclass);


--
-- Name: judge_evaluations id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.judge_evaluations ALTER COLUMN id SET DEFAULT nextval('public.judge_evaluations_id_seq'::regclass);


--
-- Name: judge_rounds id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.judge_rounds ALTER COLUMN id SET DEFAULT nextval('public.judge_rounds_id_seq'::regclass);


--
-- Name: judge_runs id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.judge_runs ALTER COLUMN id SET DEFAULT nextval('public.judge_runs_id_seq'::regclass);


--
-- Name: judge_segment_runs id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.judge_segment_runs ALTER COLUMN id SET DEFAULT nextval('public.judge_segment_runs_id_seq'::regclass);


--
-- Name: llm_models id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.llm_models ALTER COLUMN id SET DEFAULT nextval('public.llm_models_id_seq'::regclass);


--
-- Name: methodology_profile_revisions id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.methodology_profile_revisions ALTER COLUMN id SET DEFAULT nextval('public.methodology_profile_revisions_id_seq'::regclass);


--
-- Name: methodology_profiles id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.methodology_profiles ALTER COLUMN id SET DEFAULT nextval('public.methodology_profiles_id_seq'::regclass);


--
-- Name: pipeline_events id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.pipeline_events ALTER COLUMN id SET DEFAULT nextval('public.pipeline_events_id_seq'::regclass);


--
-- Name: pipeline_runs id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.pipeline_runs ALTER COLUMN id SET DEFAULT nextval('public.pipeline_runs_id_seq'::regclass);


--
-- Name: projects id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.projects ALTER COLUMN id SET DEFAULT nextval('public.projects_id_seq'::regclass);


--
-- Name: review_evaluations id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.review_evaluations ALTER COLUMN id SET DEFAULT nextval('public.review_evaluations_id_seq'::regclass);


--
-- Name: review_rounds id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.review_rounds ALTER COLUMN id SET DEFAULT nextval('public.review_rounds_id_seq'::regclass);


--
-- Name: review_runs id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.review_runs ALTER COLUMN id SET DEFAULT nextval('public.review_runs_id_seq'::regclass);


--
-- Name: review_segment_runs id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.review_segment_runs ALTER COLUMN id SET DEFAULT nextval('public.review_segment_runs_id_seq'::regclass);


--
-- Name: sessions id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.sessions ALTER COLUMN id SET DEFAULT nextval('public.sessions_id_seq'::regclass);


--
-- Name: source_imports id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.source_imports ALTER COLUMN id SET DEFAULT nextval('public.source_imports_id_seq'::regclass);


--
-- Name: translation_reference_revisions id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.translation_reference_revisions ALTER COLUMN id SET DEFAULT nextval('public.translation_reference_revisions_id_seq'::regclass);


--
-- Name: translation_references id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.translation_references ALTER COLUMN id SET DEFAULT nextval('public.translation_references_id_seq'::regclass);


--
-- Name: translation_runs id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.translation_runs ALTER COLUMN id SET DEFAULT nextval('public.translation_runs_id_seq'::regclass);


--
-- Name: translation_segment_runs id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.translation_segment_runs ALTER COLUMN id SET DEFAULT nextval('public.translation_segment_runs_id_seq'::regclass);


--
-- Name: translation_workspace_drafts id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.translation_workspace_drafts ALTER COLUMN id SET DEFAULT nextval('public.translation_workspace_drafts_id_seq'::regclass);


--
-- Name: translation_workspace_submissions id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.translation_workspace_submissions ALTER COLUMN id SET DEFAULT nextval('public.translation_workspace_submissions_id_seq'::regclass);


--
-- Name: users id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.users ALTER COLUMN id SET DEFAULT nextval('public.users_id_seq'::regclass);


--
-- Name: workflow_profile_model_selections id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.workflow_profile_model_selections ALTER COLUMN id SET DEFAULT nextval('public.workflow_profile_model_selections_id_seq'::regclass);


--
-- Name: workflow_profile_revisions id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.workflow_profile_revisions ALTER COLUMN id SET DEFAULT nextval('public.workflow_profile_revisions_id_seq'::regclass);


--
-- Name: workflow_profiles id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.workflow_profiles ALTER COLUMN id SET DEFAULT nextval('public.workflow_profiles_id_seq'::regclass);


--
-- Name: active_storage_attachments active_storage_attachments_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.active_storage_attachments
    ADD CONSTRAINT active_storage_attachments_pkey PRIMARY KEY (id);


--
-- Name: active_storage_blobs active_storage_blobs_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.active_storage_blobs
    ADD CONSTRAINT active_storage_blobs_pkey PRIMARY KEY (id);


--
-- Name: active_storage_variant_records active_storage_variant_records_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.active_storage_variant_records
    ADD CONSTRAINT active_storage_variant_records_pkey PRIMARY KEY (id);


--
-- Name: ai_provider_attempts ai_provider_attempts_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.ai_provider_attempts
    ADD CONSTRAINT ai_provider_attempts_pkey PRIMARY KEY (id);


--
-- Name: ar_internal_metadata ar_internal_metadata_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.ar_internal_metadata
    ADD CONSTRAINT ar_internal_metadata_pkey PRIMARY KEY (key);


--
-- Name: document_execution_plans document_execution_plans_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.document_execution_plans
    ADD CONSTRAINT document_execution_plans_pkey PRIMARY KEY (id);


--
-- Name: documents documents_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.documents
    ADD CONSTRAINT documents_pkey PRIMARY KEY (id);


--
-- Name: experiment_reference_revisions experiment_reference_revisions_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.experiment_reference_revisions
    ADD CONSTRAINT experiment_reference_revisions_pkey PRIMARY KEY (id);


--
-- Name: experiment_segments experiment_segments_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.experiment_segments
    ADD CONSTRAINT experiment_segments_pkey PRIMARY KEY (id);


--
-- Name: experiments experiments_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.experiments
    ADD CONSTRAINT experiments_pkey PRIMARY KEY (id);


--
-- Name: federated_identities federated_identities_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.federated_identities
    ADD CONSTRAINT federated_identities_pkey PRIMARY KEY (id);


--
-- Name: final_translation_version_segments final_translation_version_segments_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.final_translation_version_segments
    ADD CONSTRAINT final_translation_version_segments_pkey PRIMARY KEY (id);


--
-- Name: final_translation_versions final_translation_versions_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.final_translation_versions
    ADD CONSTRAINT final_translation_versions_pkey PRIMARY KEY (id);


--
-- Name: final_translations final_translations_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.final_translations
    ADD CONSTRAINT final_translations_pkey PRIMARY KEY (id);


--
-- Name: finalization_rounds finalization_rounds_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.finalization_rounds
    ADD CONSTRAINT finalization_rounds_pkey PRIMARY KEY (id);


--
-- Name: finalization_runs finalization_runs_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.finalization_runs
    ADD CONSTRAINT finalization_runs_pkey PRIMARY KEY (id);


--
-- Name: finalization_segment_runs finalization_segment_runs_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.finalization_segment_runs
    ADD CONSTRAINT finalization_segment_runs_pkey PRIMARY KEY (id);


--
-- Name: glossaries glossaries_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.glossaries
    ADD CONSTRAINT glossaries_pkey PRIMARY KEY (id);


--
-- Name: glossary_entries glossary_entries_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.glossary_entries
    ADD CONSTRAINT glossary_entries_pkey PRIMARY KEY (id);


--
-- Name: glossary_revisions glossary_revisions_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.glossary_revisions
    ADD CONSTRAINT glossary_revisions_pkey PRIMARY KEY (id);


--
-- Name: judge_evaluations judge_evaluations_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.judge_evaluations
    ADD CONSTRAINT judge_evaluations_pkey PRIMARY KEY (id);


--
-- Name: judge_rounds judge_rounds_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.judge_rounds
    ADD CONSTRAINT judge_rounds_pkey PRIMARY KEY (id);


--
-- Name: judge_runs judge_runs_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.judge_runs
    ADD CONSTRAINT judge_runs_pkey PRIMARY KEY (id);


--
-- Name: judge_segment_runs judge_segment_runs_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.judge_segment_runs
    ADD CONSTRAINT judge_segment_runs_pkey PRIMARY KEY (id);


--
-- Name: llm_models llm_models_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.llm_models
    ADD CONSTRAINT llm_models_pkey PRIMARY KEY (id);


--
-- Name: methodology_profile_revisions methodology_profile_revisions_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.methodology_profile_revisions
    ADD CONSTRAINT methodology_profile_revisions_pkey PRIMARY KEY (id);


--
-- Name: methodology_profiles methodology_profiles_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.methodology_profiles
    ADD CONSTRAINT methodology_profiles_pkey PRIMARY KEY (id);


--
-- Name: pipeline_events pipeline_events_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.pipeline_events
    ADD CONSTRAINT pipeline_events_pkey PRIMARY KEY (id);


--
-- Name: pipeline_runs pipeline_runs_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.pipeline_runs
    ADD CONSTRAINT pipeline_runs_pkey PRIMARY KEY (id);


--
-- Name: projects projects_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.projects
    ADD CONSTRAINT projects_pkey PRIMARY KEY (id);


--
-- Name: review_evaluations review_evaluations_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.review_evaluations
    ADD CONSTRAINT review_evaluations_pkey PRIMARY KEY (id);


--
-- Name: review_rounds review_rounds_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.review_rounds
    ADD CONSTRAINT review_rounds_pkey PRIMARY KEY (id);


--
-- Name: review_runs review_runs_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.review_runs
    ADD CONSTRAINT review_runs_pkey PRIMARY KEY (id);


--
-- Name: review_segment_runs review_segment_runs_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.review_segment_runs
    ADD CONSTRAINT review_segment_runs_pkey PRIMARY KEY (id);


--
-- Name: schema_migrations schema_migrations_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.schema_migrations
    ADD CONSTRAINT schema_migrations_pkey PRIMARY KEY (version);


--
-- Name: sessions sessions_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.sessions
    ADD CONSTRAINT sessions_pkey PRIMARY KEY (id);


--
-- Name: source_imports source_imports_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.source_imports
    ADD CONSTRAINT source_imports_pkey PRIMARY KEY (id);


--
-- Name: translation_reference_revisions translation_reference_revisions_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.translation_reference_revisions
    ADD CONSTRAINT translation_reference_revisions_pkey PRIMARY KEY (id);


--
-- Name: translation_references translation_references_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.translation_references
    ADD CONSTRAINT translation_references_pkey PRIMARY KEY (id);


--
-- Name: translation_runs translation_runs_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.translation_runs
    ADD CONSTRAINT translation_runs_pkey PRIMARY KEY (id);


--
-- Name: translation_segment_runs translation_segment_runs_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.translation_segment_runs
    ADD CONSTRAINT translation_segment_runs_pkey PRIMARY KEY (id);


--
-- Name: translation_workspace_drafts translation_workspace_drafts_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.translation_workspace_drafts
    ADD CONSTRAINT translation_workspace_drafts_pkey PRIMARY KEY (id);


--
-- Name: translation_workspace_submissions translation_workspace_submissions_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.translation_workspace_submissions
    ADD CONSTRAINT translation_workspace_submissions_pkey PRIMARY KEY (id);


--
-- Name: users users_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.users
    ADD CONSTRAINT users_pkey PRIMARY KEY (id);


--
-- Name: workflow_profile_model_selections workflow_profile_model_selections_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.workflow_profile_model_selections
    ADD CONSTRAINT workflow_profile_model_selections_pkey PRIMARY KEY (id);


--
-- Name: workflow_profile_revisions workflow_profile_revisions_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.workflow_profile_revisions
    ADD CONSTRAINT workflow_profile_revisions_pkey PRIMARY KEY (id);


--
-- Name: workflow_profiles workflow_profiles_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.workflow_profiles
    ADD CONSTRAINT workflow_profiles_pkey PRIMARY KEY (id);


--
-- Name: idx_on_methodology_profile_id_id_d920f961d0; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX idx_on_methodology_profile_id_id_d920f961d0 ON public.methodology_profile_revisions USING btree (methodology_profile_id, id);


--
-- Name: idx_on_methodology_profile_id_version_9a54e7270e; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX idx_on_methodology_profile_id_version_9a54e7270e ON public.methodology_profile_revisions USING btree (methodology_profile_id, version);


--
-- Name: idx_on_status_expires_at_ed9c9803ce; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_on_status_expires_at_ed9c9803ce ON public.translation_workspace_submissions USING btree (status, expires_at);


--
-- Name: idx_on_translation_reference_id_6fd1e25754; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_on_translation_reference_id_6fd1e25754 ON public.translation_reference_revisions USING btree (translation_reference_id);


--
-- Name: index_active_storage_attachments_on_blob_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_active_storage_attachments_on_blob_id ON public.active_storage_attachments USING btree (blob_id);


--
-- Name: index_active_storage_attachments_uniqueness; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_active_storage_attachments_uniqueness ON public.active_storage_attachments USING btree (record_type, record_id, name, blob_id);


--
-- Name: index_active_storage_blobs_for_cleanup; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_active_storage_blobs_for_cleanup ON public.active_storage_blobs USING btree (created_at, id);


--
-- Name: index_active_storage_blobs_on_key; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_active_storage_blobs_on_key ON public.active_storage_blobs USING btree (key);


--
-- Name: index_active_storage_variant_records_uniqueness; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_active_storage_variant_records_uniqueness ON public.active_storage_variant_records USING btree (blob_id, variation_digest);


--
-- Name: index_ai_provider_attempts_on_run_and_attempt; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_ai_provider_attempts_on_run_and_attempt ON public.ai_provider_attempts USING btree (provider_run_type, provider_run_id, attempt_number);


--
-- Name: index_ai_provider_attempts_on_status_and_completed_at_and_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_ai_provider_attempts_on_status_and_completed_at_and_id ON public.ai_provider_attempts USING btree (status, completed_at, id);


--
-- Name: index_document_execution_plans_on_experiment_id; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_document_execution_plans_on_experiment_id ON public.document_execution_plans USING btree (experiment_id);


--
-- Name: index_documents_on_project_and_recent; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_documents_on_project_and_recent ON public.documents USING btree (project_id, created_at DESC, id DESC);


--
-- Name: index_documents_on_project_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_documents_on_project_id ON public.documents USING btree (project_id);


--
-- Name: index_experiment_reference_revisions_on_experiment_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_experiment_reference_revisions_on_experiment_id ON public.experiment_reference_revisions USING btree (experiment_id);


--
-- Name: index_experiment_reference_revisions_on_experiment_position; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_experiment_reference_revisions_on_experiment_position ON public.experiment_reference_revisions USING btree (experiment_id, "position");


--
-- Name: index_experiment_reference_revisions_on_experiment_revision; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_experiment_reference_revisions_on_experiment_revision ON public.experiment_reference_revisions USING btree (experiment_id, translation_reference_revision_id);


--
-- Name: index_experiment_reference_revisions_on_reference_revision; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_experiment_reference_revisions_on_reference_revision ON public.experiment_reference_revisions USING btree (translation_reference_revision_id);


--
-- Name: index_experiment_segments_on_plan_and_id; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_experiment_segments_on_plan_and_id ON public.experiment_segments USING btree (document_execution_plan_id, id);


--
-- Name: index_experiment_segments_on_plan_and_position; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_experiment_segments_on_plan_and_position ON public.experiment_segments USING btree (document_execution_plan_id, "position");


--
-- Name: index_experiments_on_document_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_experiments_on_document_id ON public.experiments USING btree (document_id);


--
-- Name: index_experiments_on_glossary_revision_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_experiments_on_glossary_revision_id ON public.experiments USING btree (glossary_revision_id);


--
-- Name: index_experiments_on_methodology_profile_revision_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_experiments_on_methodology_profile_revision_id ON public.experiments USING btree (methodology_profile_revision_id);


--
-- Name: index_federated_identities_on_provider_and_provider_uid; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_federated_identities_on_provider_and_provider_uid ON public.federated_identities USING btree (provider, provider_uid);


--
-- Name: index_federated_identities_on_user_id_and_provider; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_federated_identities_on_user_id_and_provider ON public.federated_identities USING btree (user_id, provider);


--
-- Name: index_final_translation_versions_on_final_translation_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_final_translation_versions_on_final_translation_id ON public.final_translation_versions USING btree (final_translation_id);


--
-- Name: index_final_translations_on_experiment_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_final_translations_on_experiment_id ON public.final_translations USING btree (experiment_id);


--
-- Name: index_final_translations_on_id_and_experiment_id; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_final_translations_on_id_and_experiment_id ON public.final_translations USING btree (id, experiment_id);


--
-- Name: index_final_translations_on_judge_round_id; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_final_translations_on_judge_round_id ON public.final_translations USING btree (judge_round_id);


--
-- Name: index_final_translations_on_source_winner_translation_run_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_final_translations_on_source_winner_translation_run_id ON public.final_translations USING btree (source_winner_translation_run_id);


--
-- Name: index_final_version_segments_on_version_and_segment; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_final_version_segments_on_version_and_segment ON public.final_translation_version_segments USING btree (final_translation_version_id, experiment_segment_id);


--
-- Name: index_final_versions_on_translation_and_id; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_final_versions_on_translation_and_id ON public.final_translation_versions USING btree (final_translation_id, id);


--
-- Name: index_final_versions_on_translation_and_number; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_final_versions_on_translation_and_number ON public.final_translation_versions USING btree (final_translation_id, version_number);


--
-- Name: index_final_versions_on_unique_source_run; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_final_versions_on_unique_source_run ON public.final_translation_versions USING btree (source_finalization_run_id) WHERE (source_finalization_run_id IS NOT NULL);


--
-- Name: index_finalization_rounds_on_base_final_translation_version_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_finalization_rounds_on_base_final_translation_version_id ON public.finalization_rounds USING btree (base_final_translation_version_id);


--
-- Name: index_finalization_rounds_on_final_translation_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_finalization_rounds_on_final_translation_id ON public.finalization_rounds USING btree (final_translation_id);


--
-- Name: index_finalization_rounds_on_translation_and_base; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_finalization_rounds_on_translation_and_base ON public.finalization_rounds USING btree (final_translation_id, base_final_translation_version_id);


--
-- Name: index_finalization_rounds_one_running; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_finalization_rounds_one_running ON public.finalization_rounds USING btree (final_translation_id) WHERE ((status)::text = 'running'::text);


--
-- Name: index_finalization_runs_on_finalization_round_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_finalization_runs_on_finalization_round_id ON public.finalization_runs USING btree (finalization_round_id);


--
-- Name: index_finalization_runs_on_finalizer_llm_model_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_finalization_runs_on_finalizer_llm_model_id ON public.finalization_runs USING btree (finalizer_llm_model_id);


--
-- Name: index_finalization_runs_on_pending_since; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_finalization_runs_on_pending_since ON public.finalization_runs USING btree (pending_since) WHERE ((status)::text = 'pending'::text);


--
-- Name: index_finalization_runs_on_recent_failures; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_finalization_runs_on_recent_failures ON public.finalization_runs USING btree (completed_at, id) INCLUDE (error_code) WHERE ((status)::text = 'failed'::text);


--
-- Name: index_finalization_runs_on_round_and_model; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_finalization_runs_on_round_and_model ON public.finalization_runs USING btree (finalization_round_id, finalizer_llm_model_id);


--
-- Name: index_finalization_runs_on_running_last_claimed_at; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_finalization_runs_on_running_last_claimed_at ON public.finalization_runs USING btree (last_claimed_at) WHERE ((status)::text = 'running'::text);


--
-- Name: index_finalization_segment_runs_on_parent_and_id; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_finalization_segment_runs_on_parent_and_id ON public.finalization_segment_runs USING btree (finalization_run_id, id);


--
-- Name: index_finalization_segment_runs_on_parent_and_segment; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_finalization_segment_runs_on_parent_and_segment ON public.finalization_segment_runs USING btree (finalization_run_id, experiment_segment_id);


--
-- Name: index_finalization_segment_runs_on_pending_since; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_finalization_segment_runs_on_pending_since ON public.finalization_segment_runs USING btree (pending_since) WHERE ((status)::text = 'pending'::text);


--
-- Name: index_finalization_segment_runs_on_recent_failures; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_finalization_segment_runs_on_recent_failures ON public.finalization_segment_runs USING btree (completed_at, id) INCLUDE (error_code) WHERE ((status)::text = 'failed'::text);


--
-- Name: index_finalization_segment_runs_on_running_last_claimed_at; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_finalization_segment_runs_on_running_last_claimed_at ON public.finalization_segment_runs USING btree (last_claimed_at) WHERE ((status)::text = 'running'::text);


--
-- Name: index_glossaries_on_owner_and_recent; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_glossaries_on_owner_and_recent ON public.glossaries USING btree (user_id, active DESC, updated_at DESC, id DESC);


--
-- Name: index_glossaries_on_user_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_glossaries_on_user_id ON public.glossaries USING btree (user_id);


--
-- Name: index_glossary_entries_on_glossary_revision_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_glossary_entries_on_glossary_revision_id ON public.glossary_entries USING btree (glossary_revision_id);


--
-- Name: index_glossary_entries_on_glossary_revision_id_and_position; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_glossary_entries_on_glossary_revision_id_and_position ON public.glossary_entries USING btree (glossary_revision_id, "position");


--
-- Name: index_glossary_entries_on_glossary_revision_id_and_source_term; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_glossary_entries_on_glossary_revision_id_and_source_term ON public.glossary_entries USING btree (glossary_revision_id, source_term);


--
-- Name: index_glossary_revisions_on_configuration_digest; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_glossary_revisions_on_configuration_digest ON public.glossary_revisions USING btree (configuration_digest);


--
-- Name: index_glossary_revisions_on_glossary_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_glossary_revisions_on_glossary_id ON public.glossary_revisions USING btree (glossary_id);


--
-- Name: index_glossary_revisions_on_glossary_id_and_id; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_glossary_revisions_on_glossary_id_and_id ON public.glossary_revisions USING btree (glossary_id, id);


--
-- Name: index_glossary_revisions_on_glossary_id_and_version; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_glossary_revisions_on_glossary_id_and_version ON public.glossary_revisions USING btree (glossary_id, version);


--
-- Name: index_judge_evaluations_on_judge_run_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_judge_evaluations_on_judge_run_id ON public.judge_evaluations USING btree (judge_run_id);


--
-- Name: index_judge_evaluations_on_run_and_label; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_judge_evaluations_on_run_and_label ON public.judge_evaluations USING btree (judge_run_id, anonymous_label);


--
-- Name: index_judge_evaluations_on_run_and_rank; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_judge_evaluations_on_run_and_rank ON public.judge_evaluations USING btree (judge_run_id, rank) WHERE (rank IS NOT NULL);


--
-- Name: index_judge_evaluations_on_run_and_translation; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_judge_evaluations_on_run_and_translation ON public.judge_evaluations USING btree (judge_run_id, translation_run_id);


--
-- Name: index_judge_evaluations_on_translation_run_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_judge_evaluations_on_translation_run_id ON public.judge_evaluations USING btree (translation_run_id);


--
-- Name: index_judge_rounds_on_id_and_winner; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_judge_rounds_on_id_and_winner ON public.judge_rounds USING btree (id, winner_translation_run_id);


--
-- Name: index_judge_rounds_on_review_round_id; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_judge_rounds_on_review_round_id ON public.judge_rounds USING btree (review_round_id);


--
-- Name: index_judge_rounds_on_winner_translation_run_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_judge_rounds_on_winner_translation_run_id ON public.judge_rounds USING btree (winner_translation_run_id);


--
-- Name: index_judge_runs_on_judge_llm_model_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_judge_runs_on_judge_llm_model_id ON public.judge_runs USING btree (judge_llm_model_id);


--
-- Name: index_judge_runs_on_judge_round_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_judge_runs_on_judge_round_id ON public.judge_runs USING btree (judge_round_id);


--
-- Name: index_judge_runs_on_judge_round_id_and_judge_llm_model_id; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_judge_runs_on_judge_round_id_and_judge_llm_model_id ON public.judge_runs USING btree (judge_round_id, judge_llm_model_id);


--
-- Name: index_judge_runs_on_pending_since; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_judge_runs_on_pending_since ON public.judge_runs USING btree (pending_since) WHERE ((status)::text = 'pending'::text);


--
-- Name: index_judge_runs_on_recent_failures; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_judge_runs_on_recent_failures ON public.judge_runs USING btree (completed_at, id) INCLUDE (error_code) WHERE ((status)::text = 'failed'::text);


--
-- Name: index_judge_runs_on_running_last_claimed_at; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_judge_runs_on_running_last_claimed_at ON public.judge_runs USING btree (last_claimed_at) WHERE ((status)::text = 'running'::text);


--
-- Name: index_judge_runs_on_winner_translation_run_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_judge_runs_on_winner_translation_run_id ON public.judge_runs USING btree (winner_translation_run_id);


--
-- Name: index_judge_segment_runs_on_parent_and_id; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_judge_segment_runs_on_parent_and_id ON public.judge_segment_runs USING btree (judge_run_id, id);


--
-- Name: index_judge_segment_runs_on_parent_and_segment; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_judge_segment_runs_on_parent_and_segment ON public.judge_segment_runs USING btree (judge_run_id, experiment_segment_id);


--
-- Name: index_judge_segment_runs_on_pending_since; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_judge_segment_runs_on_pending_since ON public.judge_segment_runs USING btree (pending_since) WHERE ((status)::text = 'pending'::text);


--
-- Name: index_judge_segment_runs_on_recent_failures; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_judge_segment_runs_on_recent_failures ON public.judge_segment_runs USING btree (completed_at, id) INCLUDE (error_code) WHERE ((status)::text = 'failed'::text);


--
-- Name: index_judge_segment_runs_on_running_last_claimed_at; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_judge_segment_runs_on_running_last_claimed_at ON public.judge_segment_runs USING btree (last_claimed_at) WHERE ((status)::text = 'running'::text);


--
-- Name: index_llm_models_on_gateway_and_model_identifier; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_llm_models_on_gateway_and_model_identifier ON public.llm_models USING btree (gateway, model_identifier);


--
-- Name: index_methodology_profile_revisions_on_configuration_digest; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_methodology_profile_revisions_on_configuration_digest ON public.methodology_profile_revisions USING btree (configuration_digest);


--
-- Name: index_methodology_profile_revisions_on_methodology_profile_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_methodology_profile_revisions_on_methodology_profile_id ON public.methodology_profile_revisions USING btree (methodology_profile_id);


--
-- Name: index_methodology_profiles_on_owner_and_recent; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_methodology_profiles_on_owner_and_recent ON public.methodology_profiles USING btree (user_id, active DESC, updated_at DESC, id DESC);


--
-- Name: index_methodology_profiles_on_user_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_methodology_profiles_on_user_id ON public.methodology_profiles USING btree (user_id);


--
-- Name: index_pipeline_events_on_pipeline_run_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_pipeline_events_on_pipeline_run_id ON public.pipeline_events USING btree (pipeline_run_id);


--
-- Name: index_pipeline_events_on_run_and_key; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_pipeline_events_on_run_and_key ON public.pipeline_events USING btree (pipeline_run_id, event_key);


--
-- Name: index_pipeline_events_on_run_and_sequence; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_pipeline_events_on_run_and_sequence ON public.pipeline_events USING btree (pipeline_run_id, sequence_number);


--
-- Name: index_pipeline_runs_for_fair_reconciliation; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_pipeline_runs_for_fair_reconciliation ON public.pipeline_runs USING btree (status, last_reconciled_at, id);


--
-- Name: index_pipeline_runs_for_reconciliation; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_pipeline_runs_for_reconciliation ON public.pipeline_runs USING btree (status, updated_at, id);


--
-- Name: index_pipeline_runs_on_current_stage_and_status; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_pipeline_runs_on_current_stage_and_status ON public.pipeline_runs USING btree (current_stage, status);


--
-- Name: index_pipeline_runs_on_experiment_id; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_pipeline_runs_on_experiment_id ON public.pipeline_runs USING btree (experiment_id);


--
-- Name: index_pipeline_runs_on_finalization_round_id; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_pipeline_runs_on_finalization_round_id ON public.pipeline_runs USING btree (finalization_round_id) WHERE (finalization_round_id IS NOT NULL);


--
-- Name: index_pipeline_runs_on_profile_revision; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_pipeline_runs_on_profile_revision ON public.pipeline_runs USING btree (workflow_profile_revision_id);


--
-- Name: index_profile_model_selections_on_revision; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_profile_model_selections_on_revision ON public.workflow_profile_model_selections USING btree (workflow_profile_revision_id);


--
-- Name: index_profile_selections_on_revision_role_model; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_profile_selections_on_revision_role_model ON public.workflow_profile_model_selections USING btree (workflow_profile_revision_id, role, llm_model_id);


--
-- Name: index_profile_selections_on_revision_role_position; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_profile_selections_on_revision_role_position ON public.workflow_profile_model_selections USING btree (workflow_profile_revision_id, role, "position");


--
-- Name: index_projects_on_user_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_projects_on_user_id ON public.projects USING btree (user_id);


--
-- Name: index_review_evaluations_on_review_run_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_review_evaluations_on_review_run_id ON public.review_evaluations USING btree (review_run_id);


--
-- Name: index_review_evaluations_on_run_and_label; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_review_evaluations_on_run_and_label ON public.review_evaluations USING btree (review_run_id, anonymous_label);


--
-- Name: index_review_evaluations_on_run_and_translation; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_review_evaluations_on_run_and_translation ON public.review_evaluations USING btree (review_run_id, translation_run_id);


--
-- Name: index_review_evaluations_on_translation_run_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_review_evaluations_on_translation_run_id ON public.review_evaluations USING btree (translation_run_id);


--
-- Name: index_review_rounds_on_experiment_id; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_review_rounds_on_experiment_id ON public.review_rounds USING btree (experiment_id);


--
-- Name: index_review_runs_on_pending_since; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_review_runs_on_pending_since ON public.review_runs USING btree (pending_since) WHERE ((status)::text = 'pending'::text);


--
-- Name: index_review_runs_on_recent_failures; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_review_runs_on_recent_failures ON public.review_runs USING btree (completed_at, id) INCLUDE (error_code) WHERE ((status)::text = 'failed'::text);


--
-- Name: index_review_runs_on_review_round_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_review_runs_on_review_round_id ON public.review_runs USING btree (review_round_id);


--
-- Name: index_review_runs_on_review_round_id_and_reviewer_llm_model_id; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_review_runs_on_review_round_id_and_reviewer_llm_model_id ON public.review_runs USING btree (review_round_id, reviewer_llm_model_id);


--
-- Name: index_review_runs_on_reviewer_llm_model_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_review_runs_on_reviewer_llm_model_id ON public.review_runs USING btree (reviewer_llm_model_id);


--
-- Name: index_review_runs_on_running_last_claimed_at; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_review_runs_on_running_last_claimed_at ON public.review_runs USING btree (last_claimed_at) WHERE ((status)::text = 'running'::text);


--
-- Name: index_review_segment_runs_on_parent_and_id; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_review_segment_runs_on_parent_and_id ON public.review_segment_runs USING btree (review_run_id, id);


--
-- Name: index_review_segment_runs_on_parent_and_segment; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_review_segment_runs_on_parent_and_segment ON public.review_segment_runs USING btree (review_run_id, experiment_segment_id);


--
-- Name: index_review_segment_runs_on_pending_since; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_review_segment_runs_on_pending_since ON public.review_segment_runs USING btree (pending_since) WHERE ((status)::text = 'pending'::text);


--
-- Name: index_review_segment_runs_on_recent_failures; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_review_segment_runs_on_recent_failures ON public.review_segment_runs USING btree (completed_at, id) INCLUDE (error_code) WHERE ((status)::text = 'failed'::text);


--
-- Name: index_review_segment_runs_on_running_last_claimed_at; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_review_segment_runs_on_running_last_claimed_at ON public.review_segment_runs USING btree (last_claimed_at) WHERE ((status)::text = 'running'::text);


--
-- Name: index_sessions_on_created_at; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_sessions_on_created_at ON public.sessions USING btree (created_at);


--
-- Name: index_sessions_on_user_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_sessions_on_user_id ON public.sessions USING btree (user_id);


--
-- Name: index_source_imports_for_cleanup; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_source_imports_for_cleanup ON public.source_imports USING btree (status, expires_at, id);


--
-- Name: index_source_imports_on_resulting_document_id; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_source_imports_on_resulting_document_id ON public.source_imports USING btree (resulting_document_id) WHERE (resulting_document_id IS NOT NULL);


--
-- Name: index_source_imports_on_user_and_request_key; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_source_imports_on_user_and_request_key ON public.source_imports USING btree (user_id, request_key) WHERE (request_key IS NOT NULL);


--
-- Name: index_source_imports_on_user_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_source_imports_on_user_id ON public.source_imports USING btree (user_id);


--
-- Name: index_source_imports_on_user_id_and_status; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_source_imports_on_user_id_and_status ON public.source_imports USING btree (user_id, status);


--
-- Name: index_translation_reference_revisions_on_configuration_digest; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_translation_reference_revisions_on_configuration_digest ON public.translation_reference_revisions USING btree (configuration_digest);


--
-- Name: index_translation_reference_revisions_on_reference_and_id; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_translation_reference_revisions_on_reference_and_id ON public.translation_reference_revisions USING btree (translation_reference_id, id);


--
-- Name: index_translation_reference_revisions_on_reference_and_version; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_translation_reference_revisions_on_reference_and_version ON public.translation_reference_revisions USING btree (translation_reference_id, version);


--
-- Name: index_translation_references_on_owner_and_recent; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_translation_references_on_owner_and_recent ON public.translation_references USING btree (user_id, active DESC, updated_at DESC, id DESC);


--
-- Name: index_translation_references_on_user_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_translation_references_on_user_id ON public.translation_references USING btree (user_id);


--
-- Name: index_translation_runs_on_experiment_and_id; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_translation_runs_on_experiment_and_id ON public.translation_runs USING btree (experiment_id, id);


--
-- Name: index_translation_runs_on_experiment_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_translation_runs_on_experiment_id ON public.translation_runs USING btree (experiment_id);


--
-- Name: index_translation_runs_on_experiment_id_and_llm_model_id; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_translation_runs_on_experiment_id_and_llm_model_id ON public.translation_runs USING btree (experiment_id, llm_model_id);


--
-- Name: index_translation_runs_on_llm_model_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_translation_runs_on_llm_model_id ON public.translation_runs USING btree (llm_model_id);


--
-- Name: index_translation_runs_on_pending_since; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_translation_runs_on_pending_since ON public.translation_runs USING btree (pending_since) WHERE ((status)::text = 'pending'::text);


--
-- Name: index_translation_runs_on_recent_failures; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_translation_runs_on_recent_failures ON public.translation_runs USING btree (completed_at, id) INCLUDE (error_code) WHERE ((status)::text = 'failed'::text);


--
-- Name: index_translation_runs_on_running_last_claimed_at; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_translation_runs_on_running_last_claimed_at ON public.translation_runs USING btree (last_claimed_at) WHERE ((status)::text = 'running'::text);


--
-- Name: index_translation_segment_runs_on_parent_and_id; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_translation_segment_runs_on_parent_and_id ON public.translation_segment_runs USING btree (translation_run_id, id);


--
-- Name: index_translation_segment_runs_on_parent_and_segment; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_translation_segment_runs_on_parent_and_segment ON public.translation_segment_runs USING btree (translation_run_id, experiment_segment_id);


--
-- Name: index_translation_segment_runs_on_pending_since; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_translation_segment_runs_on_pending_since ON public.translation_segment_runs USING btree (pending_since) WHERE ((status)::text = 'pending'::text);


--
-- Name: index_translation_segment_runs_on_recent_failures; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_translation_segment_runs_on_recent_failures ON public.translation_segment_runs USING btree (completed_at, id) INCLUDE (error_code) WHERE ((status)::text = 'failed'::text);


--
-- Name: index_translation_segment_runs_on_running_last_claimed_at; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_translation_segment_runs_on_running_last_claimed_at ON public.translation_segment_runs USING btree (last_claimed_at) WHERE ((status)::text = 'running'::text);


--
-- Name: index_translation_workspace_drafts_on_expires_at_and_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_translation_workspace_drafts_on_expires_at_and_id ON public.translation_workspace_drafts USING btree (expires_at, id);


--
-- Name: index_translation_workspace_drafts_on_public_id; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_translation_workspace_drafts_on_public_id ON public.translation_workspace_drafts USING btree (public_id);


--
-- Name: index_translation_workspace_drafts_on_user_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_translation_workspace_drafts_on_user_id ON public.translation_workspace_drafts USING btree (user_id);


--
-- Name: index_translation_workspace_drafts_on_user_id_and_context_key; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_translation_workspace_drafts_on_user_id_and_context_key ON public.translation_workspace_drafts USING btree (user_id, context_key);


--
-- Name: index_translation_workspace_submissions_on_experiment_id; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_translation_workspace_submissions_on_experiment_id ON public.translation_workspace_submissions USING btree (experiment_id) WHERE (experiment_id IS NOT NULL);


--
-- Name: index_translation_workspace_submissions_on_token_digest; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_translation_workspace_submissions_on_token_digest ON public.translation_workspace_submissions USING btree (token_digest);


--
-- Name: index_translation_workspace_submissions_on_user_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_translation_workspace_submissions_on_user_id ON public.translation_workspace_submissions USING btree (user_id);


--
-- Name: index_translation_workspace_submissions_on_user_id_and_status; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_translation_workspace_submissions_on_user_id_and_status ON public.translation_workspace_submissions USING btree (user_id, status);


--
-- Name: index_users_on_lower_email; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_users_on_lower_email ON public.users USING btree (lower((email)::text));


--
-- Name: index_workflow_profile_model_selections_on_llm_model_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_workflow_profile_model_selections_on_llm_model_id ON public.workflow_profile_model_selections USING btree (llm_model_id);


--
-- Name: index_workflow_profile_revisions_on_configuration_digest; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_workflow_profile_revisions_on_configuration_digest ON public.workflow_profile_revisions USING btree (configuration_digest);


--
-- Name: index_workflow_profile_revisions_on_profile_and_id; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_workflow_profile_revisions_on_profile_and_id ON public.workflow_profile_revisions USING btree (workflow_profile_id, id);


--
-- Name: index_workflow_profile_revisions_on_profile_and_version; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_workflow_profile_revisions_on_profile_and_version ON public.workflow_profile_revisions USING btree (workflow_profile_id, version);


--
-- Name: index_workflow_profile_revisions_on_workflow_profile_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_workflow_profile_revisions_on_workflow_profile_id ON public.workflow_profile_revisions USING btree (workflow_profile_id);


--
-- Name: index_workflow_profiles_on_owner_and_recent; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_workflow_profiles_on_owner_and_recent ON public.workflow_profiles USING btree (user_id, active DESC, updated_at DESC, id DESC);


--
-- Name: index_workflow_profiles_on_user_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_workflow_profiles_on_user_id ON public.workflow_profiles USING btree (user_id);


--
-- Name: index_workspace_submissions_for_cleanup; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_workspace_submissions_for_cleanup ON public.translation_workspace_submissions USING btree (status, expires_at, id);


--
-- Name: ai_provider_attempts enforce_ai_provider_attempt_lineage; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER enforce_ai_provider_attempt_lineage BEFORE INSERT OR UPDATE OF provider_run_type, provider_run_id, stage ON public.ai_provider_attempts FOR EACH ROW EXECUTE FUNCTION public.enforce_provider_attempt_lineage();


--
-- Name: documents enforce_document_glossary_owner_trigger; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER enforce_document_glossary_owner_trigger BEFORE UPDATE OF project_id ON public.documents FOR EACH ROW EXECUTE FUNCTION public.enforce_document_glossary_owner();


--
-- Name: documents enforce_document_methodology_snapshots_trigger; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER enforce_document_methodology_snapshots_trigger BEFORE UPDATE OF project_id ON public.documents FOR EACH ROW EXECUTE FUNCTION public.enforce_document_methodology_snapshots();


--
-- Name: documents enforce_document_reference_snapshots_trigger; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER enforce_document_reference_snapshots_trigger BEFORE UPDATE OF project_id ON public.documents FOR EACH ROW EXECUTE FUNCTION public.enforce_document_reference_snapshots();


--
-- Name: experiments enforce_experiment_glossary_owner_trigger; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER enforce_experiment_glossary_owner_trigger AFTER INSERT OR UPDATE OF document_id, glossary_revision_id ON public.experiments FOR EACH ROW EXECUTE FUNCTION public.enforce_experiment_glossary_owner();


--
-- Name: experiments enforce_experiment_methodology_snapshot_trigger; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER enforce_experiment_methodology_snapshot_trigger AFTER INSERT OR UPDATE OF document_id, methodology_profile_revision_id ON public.experiments FOR EACH ROW EXECUTE FUNCTION public.enforce_experiment_methodology_snapshot();


--
-- Name: experiments enforce_experiment_reference_snapshots_trigger; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER enforce_experiment_reference_snapshots_trigger BEFORE UPDATE OF document_id ON public.experiments FOR EACH ROW EXECUTE FUNCTION public.enforce_experiment_reference_snapshots();


--
-- Name: final_translation_version_segments enforce_final_version_segment_lineage; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER enforce_final_version_segment_lineage BEFORE INSERT OR UPDATE OF final_translation_version_id, experiment_segment_id ON public.final_translation_version_segments FOR EACH ROW EXECUTE FUNCTION public.enforce_segment_lineage();


--
-- Name: final_translation_versions enforce_final_version_sequence; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER enforce_final_version_sequence BEFORE INSERT ON public.final_translation_versions FOR EACH ROW EXECUTE FUNCTION public.enforce_final_version_sequence();


--
-- Name: final_translation_versions enforce_final_version_source_lineage; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER enforce_final_version_source_lineage BEFORE INSERT OR UPDATE OF final_translation_id, source_finalization_run_id ON public.final_translation_versions FOR EACH ROW EXECUTE FUNCTION public.enforce_final_version_lineage();


--
-- Name: finalization_segment_runs enforce_finalization_segment_runs_lineage; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER enforce_finalization_segment_runs_lineage BEFORE INSERT OR UPDATE OF finalization_run_id, experiment_segment_id ON public.finalization_segment_runs FOR EACH ROW EXECUTE FUNCTION public.enforce_segment_lineage();


--
-- Name: glossary_entries enforce_glossary_entry_set_seal_trigger; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER enforce_glossary_entry_set_seal_trigger BEFORE INSERT OR DELETE OR UPDATE ON public.glossary_entries FOR EACH ROW EXECUTE FUNCTION public.enforce_glossary_entry_set_seal();


--
-- Name: glossaries enforce_glossary_owner_trigger; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER enforce_glossary_owner_trigger BEFORE UPDATE OF user_id ON public.glossaries FOR EACH ROW EXECUTE FUNCTION public.enforce_glossary_owner();


--
-- Name: glossary_revisions enforce_glossary_revisions_sequence; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER enforce_glossary_revisions_sequence BEFORE INSERT ON public.glossary_revisions FOR EACH ROW EXECUTE FUNCTION public.enforce_revision_sequence('glossaries', 'glossary_id');


--
-- Name: judge_evaluations enforce_judge_evaluation_lineage; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER enforce_judge_evaluation_lineage BEFORE INSERT OR UPDATE OF judge_run_id, translation_run_id ON public.judge_evaluations FOR EACH ROW EXECUTE FUNCTION public.enforce_evaluation_lineage();


--
-- Name: judge_rounds enforce_judge_round_winner_lineage; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER enforce_judge_round_winner_lineage BEFORE INSERT OR UPDATE OF review_round_id, winner_translation_run_id ON public.judge_rounds FOR EACH ROW EXECUTE FUNCTION public.enforce_judge_winner_lineage();


--
-- Name: judge_runs enforce_judge_run_winner_lineage; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER enforce_judge_run_winner_lineage BEFORE INSERT OR UPDATE OF judge_round_id, winner_translation_run_id ON public.judge_runs FOR EACH ROW EXECUTE FUNCTION public.enforce_judge_winner_lineage();


--
-- Name: judge_segment_runs enforce_judge_segment_runs_lineage; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER enforce_judge_segment_runs_lineage BEFORE INSERT OR UPDATE OF judge_run_id, experiment_segment_id ON public.judge_segment_runs FOR EACH ROW EXECUTE FUNCTION public.enforce_segment_lineage();


--
-- Name: methodology_profiles enforce_methodology_profile_owner_trigger; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER enforce_methodology_profile_owner_trigger BEFORE UPDATE OF user_id ON public.methodology_profiles FOR EACH ROW EXECUTE FUNCTION public.enforce_methodology_profile_owner();


--
-- Name: methodology_profile_revisions enforce_methodology_profile_revisions_sequence; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER enforce_methodology_profile_revisions_sequence BEFORE INSERT ON public.methodology_profile_revisions FOR EACH ROW EXECUTE FUNCTION public.enforce_revision_sequence('methodology_profiles', 'methodology_profile_id');


--
-- Name: experiment_reference_revisions enforce_new_experiment_reference_snapshot_trigger; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER enforce_new_experiment_reference_snapshot_trigger BEFORE INSERT ON public.experiment_reference_revisions FOR EACH ROW EXECUTE FUNCTION public.enforce_new_experiment_reference_snapshot();


--
-- Name: pipeline_runs enforce_pipeline_owner_lineage; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER enforce_pipeline_owner_lineage BEFORE INSERT OR UPDATE OF experiment_id, workflow_profile_revision_id, finalization_round_id ON public.pipeline_runs FOR EACH ROW EXECUTE FUNCTION public.enforce_owned_workflow_lineage();


--
-- Name: projects enforce_project_glossary_owner_trigger; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER enforce_project_glossary_owner_trigger BEFORE UPDATE OF user_id ON public.projects FOR EACH ROW EXECUTE FUNCTION public.enforce_project_glossary_owner();


--
-- Name: projects enforce_project_methodology_snapshots_trigger; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER enforce_project_methodology_snapshots_trigger BEFORE UPDATE OF user_id, source_language, target_language ON public.projects FOR EACH ROW EXECUTE FUNCTION public.enforce_project_methodology_snapshots();


--
-- Name: projects enforce_project_reference_snapshots_trigger; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER enforce_project_reference_snapshots_trigger BEFORE UPDATE OF user_id, source_language, target_language ON public.projects FOR EACH ROW EXECUTE FUNCTION public.enforce_project_reference_snapshots();


--
-- Name: review_evaluations enforce_review_evaluation_lineage; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER enforce_review_evaluation_lineage BEFORE INSERT OR UPDATE OF review_run_id, translation_run_id ON public.review_evaluations FOR EACH ROW EXECUTE FUNCTION public.enforce_evaluation_lineage();


--
-- Name: review_segment_runs enforce_review_segment_runs_lineage; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER enforce_review_segment_runs_lineage BEFORE INSERT OR UPDATE OF review_run_id, experiment_segment_id ON public.review_segment_runs FOR EACH ROW EXECUTE FUNCTION public.enforce_segment_lineage();


--
-- Name: source_imports enforce_source_import_owner_lineage; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER enforce_source_import_owner_lineage BEFORE INSERT OR UPDATE OF user_id, resulting_document_id ON public.source_imports FOR EACH ROW EXECUTE FUNCTION public.enforce_owned_workflow_lineage();


--
-- Name: translation_references enforce_translation_reference_owner_trigger; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER enforce_translation_reference_owner_trigger BEFORE UPDATE OF user_id ON public.translation_references FOR EACH ROW EXECUTE FUNCTION public.enforce_translation_reference_owner();


--
-- Name: translation_reference_revisions enforce_translation_reference_revisions_sequence; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER enforce_translation_reference_revisions_sequence BEFORE INSERT ON public.translation_reference_revisions FOR EACH ROW EXECUTE FUNCTION public.enforce_revision_sequence('translation_references', 'translation_reference_id');


--
-- Name: translation_segment_runs enforce_translation_segment_runs_lineage; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER enforce_translation_segment_runs_lineage BEFORE INSERT OR UPDATE OF translation_run_id, experiment_segment_id ON public.translation_segment_runs FOR EACH ROW EXECUTE FUNCTION public.enforce_segment_lineage();


--
-- Name: workflow_profile_revisions enforce_workflow_profile_revisions_sequence; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER enforce_workflow_profile_revisions_sequence BEFORE INSERT ON public.workflow_profile_revisions FOR EACH ROW EXECUTE FUNCTION public.enforce_revision_sequence('workflow_profiles', 'workflow_profile_id');


--
-- Name: translation_workspace_submissions enforce_workspace_submission_owner_lineage; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER enforce_workspace_submission_owner_lineage BEFORE INSERT OR UPDATE OF user_id, experiment_id ON public.translation_workspace_submissions FOR EACH ROW EXECUTE FUNCTION public.enforce_owned_workflow_lineage();


--
-- Name: ai_provider_attempts prevent_ai_provider_attempt_mutation; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER prevent_ai_provider_attempt_mutation BEFORE DELETE OR UPDATE ON public.ai_provider_attempts FOR EACH ROW EXECUTE FUNCTION public.prevent_provider_attempt_mutation();


--
-- Name: finalization_rounds prevent_completed_finalization_rounds_mutation; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER prevent_completed_finalization_rounds_mutation BEFORE INSERT OR DELETE OR UPDATE ON public.finalization_rounds FOR EACH ROW EXECUTE FUNCTION public.prevent_completed_record_mutation();


--
-- Name: finalization_runs prevent_completed_finalization_runs_mutation; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER prevent_completed_finalization_runs_mutation BEFORE INSERT OR DELETE OR UPDATE ON public.finalization_runs FOR EACH ROW EXECUTE FUNCTION public.prevent_completed_record_mutation();


--
-- Name: finalization_segment_runs prevent_completed_finalization_segment_runs_mutation; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER prevent_completed_finalization_segment_runs_mutation BEFORE INSERT OR DELETE OR UPDATE ON public.finalization_segment_runs FOR EACH ROW EXECUTE FUNCTION public.prevent_completed_record_mutation();


--
-- Name: judge_evaluations prevent_completed_judge_evaluation_mutation; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER prevent_completed_judge_evaluation_mutation BEFORE INSERT OR DELETE OR UPDATE ON public.judge_evaluations FOR EACH ROW EXECUTE FUNCTION public.prevent_terminal_evaluation_mutation('judge_runs', 'judge_run_id');


--
-- Name: judge_rounds prevent_completed_judge_rounds_mutation; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER prevent_completed_judge_rounds_mutation BEFORE INSERT OR DELETE OR UPDATE ON public.judge_rounds FOR EACH ROW EXECUTE FUNCTION public.prevent_completed_record_mutation();


--
-- Name: judge_runs prevent_completed_judge_runs_mutation; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER prevent_completed_judge_runs_mutation BEFORE INSERT OR DELETE OR UPDATE ON public.judge_runs FOR EACH ROW EXECUTE FUNCTION public.prevent_completed_record_mutation();


--
-- Name: judge_segment_runs prevent_completed_judge_segment_runs_mutation; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER prevent_completed_judge_segment_runs_mutation BEFORE INSERT OR DELETE OR UPDATE ON public.judge_segment_runs FOR EACH ROW EXECUTE FUNCTION public.prevent_completed_record_mutation();


--
-- Name: review_evaluations prevent_completed_review_evaluation_mutation; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER prevent_completed_review_evaluation_mutation BEFORE INSERT OR DELETE OR UPDATE ON public.review_evaluations FOR EACH ROW EXECUTE FUNCTION public.prevent_terminal_evaluation_mutation('review_runs', 'review_run_id');


--
-- Name: review_rounds prevent_completed_review_rounds_mutation; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER prevent_completed_review_rounds_mutation BEFORE INSERT OR DELETE OR UPDATE ON public.review_rounds FOR EACH ROW EXECUTE FUNCTION public.prevent_completed_record_mutation();


--
-- Name: review_runs prevent_completed_review_runs_mutation; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER prevent_completed_review_runs_mutation BEFORE INSERT OR DELETE OR UPDATE ON public.review_runs FOR EACH ROW EXECUTE FUNCTION public.prevent_completed_record_mutation();


--
-- Name: review_segment_runs prevent_completed_review_segment_runs_mutation; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER prevent_completed_review_segment_runs_mutation BEFORE INSERT OR DELETE OR UPDATE ON public.review_segment_runs FOR EACH ROW EXECUTE FUNCTION public.prevent_completed_record_mutation();


--
-- Name: translation_runs prevent_completed_translation_runs_mutation; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER prevent_completed_translation_runs_mutation BEFORE INSERT OR DELETE OR UPDATE ON public.translation_runs FOR EACH ROW EXECUTE FUNCTION public.prevent_completed_record_mutation();


--
-- Name: translation_segment_runs prevent_completed_translation_segment_runs_mutation; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER prevent_completed_translation_segment_runs_mutation BEFORE INSERT OR DELETE OR UPDATE ON public.translation_segment_runs FOR EACH ROW EXECUTE FUNCTION public.prevent_completed_record_mutation();


--
-- Name: document_execution_plans prevent_document_execution_plans_mutation; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER prevent_document_execution_plans_mutation BEFORE DELETE OR UPDATE ON public.document_execution_plans FOR EACH ROW EXECUTE FUNCTION public.prevent_immutable_row_mutation();


--
-- Name: experiments prevent_experiment_glossary_revision_mutation_trigger; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER prevent_experiment_glossary_revision_mutation_trigger BEFORE UPDATE OF glossary_revision_id ON public.experiments FOR EACH ROW EXECUTE FUNCTION public.prevent_experiment_glossary_revision_mutation();


--
-- Name: experiments prevent_experiment_guidance_preference_mutation_trigger; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER prevent_experiment_guidance_preference_mutation_trigger BEFORE UPDATE OF guidance_preference ON public.experiments FOR EACH ROW EXECUTE FUNCTION public.prevent_experiment_guidance_preference_mutation();


--
-- Name: experiment_reference_revisions prevent_experiment_reference_snapshot_mutation_trigger; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER prevent_experiment_reference_snapshot_mutation_trigger BEFORE DELETE OR UPDATE ON public.experiment_reference_revisions FOR EACH ROW EXECUTE FUNCTION public.prevent_experiment_reference_snapshot_mutation();


--
-- Name: experiment_segments prevent_experiment_segments_mutation; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER prevent_experiment_segments_mutation BEFORE DELETE OR UPDATE ON public.experiment_segments FOR EACH ROW EXECUTE FUNCTION public.prevent_immutable_row_mutation();


--
-- Name: final_translation_version_segments prevent_final_translation_version_segments_mutation; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER prevent_final_translation_version_segments_mutation BEFORE DELETE OR UPDATE ON public.final_translation_version_segments FOR EACH ROW EXECUTE FUNCTION public.prevent_immutable_row_mutation();


--
-- Name: final_translation_versions prevent_final_translation_versions_mutation; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER prevent_final_translation_versions_mutation BEFORE DELETE OR UPDATE ON public.final_translation_versions FOR EACH ROW EXECUTE FUNCTION public.prevent_immutable_row_mutation();


--
-- Name: final_translations prevent_final_translations_parent_mutation; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER prevent_final_translations_parent_mutation BEFORE UPDATE OF experiment_id ON public.final_translations FOR EACH ROW EXECUTE FUNCTION public.prevent_parent_lineage_mutation('experiment_id');


--
-- Name: finalization_rounds prevent_finalization_rounds_parent_mutation; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER prevent_finalization_rounds_parent_mutation BEFORE UPDATE OF final_translation_id ON public.finalization_rounds FOR EACH ROW EXECUTE FUNCTION public.prevent_parent_lineage_mutation('final_translation_id');


--
-- Name: finalization_runs prevent_finalization_runs_parent_mutation; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER prevent_finalization_runs_parent_mutation BEFORE UPDATE OF finalization_round_id ON public.finalization_runs FOR EACH ROW EXECUTE FUNCTION public.prevent_parent_lineage_mutation('finalization_round_id');


--
-- Name: glossary_revisions prevent_glossary_revision_mutation_trigger; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER prevent_glossary_revision_mutation_trigger BEFORE DELETE OR UPDATE ON public.glossary_revisions FOR EACH ROW EXECUTE FUNCTION public.prevent_glossary_revision_mutation();


--
-- Name: judge_rounds prevent_judge_rounds_parent_mutation; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER prevent_judge_rounds_parent_mutation BEFORE UPDATE OF review_round_id ON public.judge_rounds FOR EACH ROW EXECUTE FUNCTION public.prevent_parent_lineage_mutation('review_round_id');


--
-- Name: judge_runs prevent_judge_runs_parent_mutation; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER prevent_judge_runs_parent_mutation BEFORE UPDATE OF judge_round_id ON public.judge_runs FOR EACH ROW EXECUTE FUNCTION public.prevent_parent_lineage_mutation('judge_round_id');


--
-- Name: methodology_profile_revisions prevent_methodology_profile_revision_mutation_trigger; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER prevent_methodology_profile_revision_mutation_trigger BEFORE DELETE OR UPDATE ON public.methodology_profile_revisions FOR EACH ROW EXECUTE FUNCTION public.prevent_methodology_profile_revision_mutation();


--
-- Name: pipeline_events prevent_pipeline_events_mutation; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER prevent_pipeline_events_mutation BEFORE DELETE OR UPDATE ON public.pipeline_events FOR EACH ROW EXECUTE FUNCTION public.prevent_immutable_row_mutation();


--
-- Name: review_rounds prevent_review_rounds_parent_mutation; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER prevent_review_rounds_parent_mutation BEFORE UPDATE OF experiment_id ON public.review_rounds FOR EACH ROW EXECUTE FUNCTION public.prevent_parent_lineage_mutation('experiment_id');


--
-- Name: review_runs prevent_review_runs_parent_mutation; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER prevent_review_runs_parent_mutation BEFORE UPDATE OF review_round_id ON public.review_runs FOR EACH ROW EXECUTE FUNCTION public.prevent_parent_lineage_mutation('review_round_id');


--
-- Name: translation_reference_revisions prevent_translation_reference_revision_mutation_trigger; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER prevent_translation_reference_revision_mutation_trigger BEFORE DELETE OR UPDATE ON public.translation_reference_revisions FOR EACH ROW EXECUTE FUNCTION public.prevent_translation_reference_revision_mutation();


--
-- Name: translation_runs prevent_translation_runs_parent_mutation; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER prevent_translation_runs_parent_mutation BEFORE UPDATE OF experiment_id ON public.translation_runs FOR EACH ROW EXECUTE FUNCTION public.prevent_parent_lineage_mutation('experiment_id');


--
-- Name: workflow_profile_model_selections prevent_workflow_profile_model_selections_mutation; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER prevent_workflow_profile_model_selections_mutation BEFORE DELETE OR UPDATE ON public.workflow_profile_model_selections FOR EACH ROW EXECUTE FUNCTION public.prevent_immutable_row_mutation();


--
-- Name: workflow_profile_revisions prevent_workflow_profile_revisions_mutation; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER prevent_workflow_profile_revisions_mutation BEFORE DELETE OR UPDATE ON public.workflow_profile_revisions FOR EACH ROW EXECUTE FUNCTION public.prevent_immutable_row_mutation();


--
-- Name: finalization_runs restrict_finalization_runs_attempt_deletion; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER restrict_finalization_runs_attempt_deletion BEFORE DELETE ON public.finalization_runs FOR EACH ROW EXECUTE FUNCTION public.restrict_provider_run_deletion('FinalizationRun');


--
-- Name: finalization_segment_runs restrict_finalization_segment_runs_attempt_deletion; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER restrict_finalization_segment_runs_attempt_deletion BEFORE DELETE ON public.finalization_segment_runs FOR EACH ROW EXECUTE FUNCTION public.restrict_provider_run_deletion('FinalizationSegmentRun');


--
-- Name: judge_runs restrict_judge_runs_attempt_deletion; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER restrict_judge_runs_attempt_deletion BEFORE DELETE ON public.judge_runs FOR EACH ROW EXECUTE FUNCTION public.restrict_provider_run_deletion('JudgeRun');


--
-- Name: judge_segment_runs restrict_judge_segment_runs_attempt_deletion; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER restrict_judge_segment_runs_attempt_deletion BEFORE DELETE ON public.judge_segment_runs FOR EACH ROW EXECUTE FUNCTION public.restrict_provider_run_deletion('JudgeSegmentRun');


--
-- Name: review_runs restrict_review_runs_attempt_deletion; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER restrict_review_runs_attempt_deletion BEFORE DELETE ON public.review_runs FOR EACH ROW EXECUTE FUNCTION public.restrict_provider_run_deletion('ReviewRun');


--
-- Name: review_segment_runs restrict_review_segment_runs_attempt_deletion; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER restrict_review_segment_runs_attempt_deletion BEFORE DELETE ON public.review_segment_runs FOR EACH ROW EXECUTE FUNCTION public.restrict_provider_run_deletion('ReviewSegmentRun');


--
-- Name: translation_runs restrict_translation_runs_attempt_deletion; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER restrict_translation_runs_attempt_deletion BEFORE DELETE ON public.translation_runs FOR EACH ROW EXECUTE FUNCTION public.restrict_provider_run_deletion('TranslationRun');


--
-- Name: translation_segment_runs restrict_translation_segment_runs_attempt_deletion; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER restrict_translation_segment_runs_attempt_deletion BEFORE DELETE ON public.translation_segment_runs FOR EACH ROW EXECUTE FUNCTION public.restrict_provider_run_deletion('TranslationSegmentRun');


--
-- Name: glossary_revisions seal_glossary_revision_entry_set_trigger; Type: TRIGGER; Schema: public; Owner: -
--

CREATE CONSTRAINT TRIGGER seal_glossary_revision_entry_set_trigger AFTER INSERT ON public.glossary_revisions DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION public.seal_glossary_revision_entry_set();


--
-- Name: final_translations fk_final_translations_current_owned_version; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.final_translations
    ADD CONSTRAINT fk_final_translations_current_owned_version FOREIGN KEY (id, current_version_id) REFERENCES public.final_translation_versions(final_translation_id, id);


--
-- Name: final_translations fk_final_translations_official_judge_winner; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.final_translations
    ADD CONSTRAINT fk_final_translations_official_judge_winner FOREIGN KEY (judge_round_id, source_winner_translation_run_id) REFERENCES public.judge_rounds(id, winner_translation_run_id);


--
-- Name: final_translations fk_final_translations_winner_in_experiment; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.final_translations
    ADD CONSTRAINT fk_final_translations_winner_in_experiment FOREIGN KEY (experiment_id, source_winner_translation_run_id) REFERENCES public.translation_runs(experiment_id, id);


--
-- Name: finalization_rounds fk_finalization_rounds_owned_base_version; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.finalization_rounds
    ADD CONSTRAINT fk_finalization_rounds_owned_base_version FOREIGN KEY (final_translation_id, base_final_translation_version_id) REFERENCES public.final_translation_versions(final_translation_id, id);


--
-- Name: glossaries fk_glossaries_owned_current_revision; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.glossaries
    ADD CONSTRAINT fk_glossaries_owned_current_revision FOREIGN KEY (id, current_revision_id) REFERENCES public.glossary_revisions(glossary_id, id);


--
-- Name: methodology_profiles fk_methodology_profiles_owned_current_revision; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.methodology_profiles
    ADD CONSTRAINT fk_methodology_profiles_owned_current_revision FOREIGN KEY (id, current_revision_id) REFERENCES public.methodology_profile_revisions(methodology_profile_id, id);


--
-- Name: pipeline_runs fk_rails_02b34ec927; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.pipeline_runs
    ADD CONSTRAINT fk_rails_02b34ec927 FOREIGN KEY (finalization_round_id) REFERENCES public.finalization_rounds(id) ON DELETE RESTRICT;


--
-- Name: final_translations fk_rails_11477c9323; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.final_translations
    ADD CONSTRAINT fk_rails_11477c9323 FOREIGN KEY (source_winner_translation_run_id) REFERENCES public.translation_runs(id);


--
-- Name: workflow_profile_model_selections fk_rails_1477fef2c0; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.workflow_profile_model_selections
    ADD CONSTRAINT fk_rails_1477fef2c0 FOREIGN KEY (llm_model_id) REFERENCES public.llm_models(id) ON DELETE RESTRICT;


--
-- Name: pipeline_runs fk_rails_17da527305; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.pipeline_runs
    ADD CONSTRAINT fk_rails_17da527305 FOREIGN KEY (experiment_id) REFERENCES public.experiments(id) ON DELETE RESTRICT;


--
-- Name: experiment_reference_revisions fk_rails_1fc4e85b1c; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.experiment_reference_revisions
    ADD CONSTRAINT fk_rails_1fc4e85b1c FOREIGN KEY (translation_reference_revision_id) REFERENCES public.translation_reference_revisions(id) ON DELETE RESTRICT;


--
-- Name: finalization_runs fk_rails_215d2c72e3; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.finalization_runs
    ADD CONSTRAINT fk_rails_215d2c72e3 FOREIGN KEY (finalization_round_id) REFERENCES public.finalization_rounds(id);


--
-- Name: source_imports fk_rails_258d226d74; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.source_imports
    ADD CONSTRAINT fk_rails_258d226d74 FOREIGN KEY (resulting_document_id) REFERENCES public.documents(id) ON DELETE RESTRICT;


--
-- Name: glossary_entries fk_rails_2962604813; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.glossary_entries
    ADD CONSTRAINT fk_rails_2962604813 FOREIGN KEY (glossary_revision_id) REFERENCES public.glossary_revisions(id) ON DELETE RESTRICT;


--
-- Name: review_runs fk_rails_2a5d7cdc72; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.review_runs
    ADD CONSTRAINT fk_rails_2a5d7cdc72 FOREIGN KEY (review_round_id) REFERENCES public.review_rounds(id);


--
-- Name: translation_runs fk_rails_337450749a; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.translation_runs
    ADD CONSTRAINT fk_rails_337450749a FOREIGN KEY (experiment_id) REFERENCES public.experiments(id);


--
-- Name: review_runs fk_rails_33a94490a1; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.review_runs
    ADD CONSTRAINT fk_rails_33a94490a1 FOREIGN KEY (reviewer_llm_model_id) REFERENCES public.llm_models(id);


--
-- Name: experiment_segments fk_rails_33b68b55b7; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.experiment_segments
    ADD CONSTRAINT fk_rails_33b68b55b7 FOREIGN KEY (document_execution_plan_id) REFERENCES public.document_execution_plans(id) ON DELETE RESTRICT;


--
-- Name: judge_rounds fk_rails_342274ea1b; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.judge_rounds
    ADD CONSTRAINT fk_rails_342274ea1b FOREIGN KEY (winner_translation_run_id) REFERENCES public.translation_runs(id);


--
-- Name: methodology_profile_revisions fk_rails_385708fe63; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.methodology_profile_revisions
    ADD CONSTRAINT fk_rails_385708fe63 FOREIGN KEY (methodology_profile_id) REFERENCES public.methodology_profiles(id) ON DELETE RESTRICT;


--
-- Name: judge_runs fk_rails_3963283c36; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.judge_runs
    ADD CONSTRAINT fk_rails_3963283c36 FOREIGN KEY (judge_round_id) REFERENCES public.judge_rounds(id);


--
-- Name: review_segment_runs fk_rails_3ac156684e; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.review_segment_runs
    ADD CONSTRAINT fk_rails_3ac156684e FOREIGN KEY (review_run_id) REFERENCES public.review_runs(id) ON DELETE RESTRICT;


--
-- Name: judge_runs fk_rails_3de8db20ef; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.judge_runs
    ADD CONSTRAINT fk_rails_3de8db20ef FOREIGN KEY (winner_translation_run_id) REFERENCES public.translation_runs(id);


--
-- Name: judge_evaluations fk_rails_3e021788d6; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.judge_evaluations
    ADD CONSTRAINT fk_rails_3e021788d6 FOREIGN KEY (translation_run_id) REFERENCES public.translation_runs(id);


--
-- Name: translation_workspace_submissions fk_rails_3ff9b0ea69; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.translation_workspace_submissions
    ADD CONSTRAINT fk_rails_3ff9b0ea69 FOREIGN KEY (experiment_id) REFERENCES public.experiments(id) ON DELETE RESTRICT;


--
-- Name: pipeline_events fk_rails_44fc9ea51a; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.pipeline_events
    ADD CONSTRAINT fk_rails_44fc9ea51a FOREIGN KEY (pipeline_run_id) REFERENCES public.pipeline_runs(id) ON DELETE RESTRICT;


--
-- Name: source_imports fk_rails_4770a41ce7; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.source_imports
    ADD CONSTRAINT fk_rails_4770a41ce7 FOREIGN KEY (user_id) REFERENCES public.users(id) ON DELETE RESTRICT;


--
-- Name: experiment_reference_revisions fk_rails_4c5edad130; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.experiment_reference_revisions
    ADD CONSTRAINT fk_rails_4c5edad130 FOREIGN KEY (experiment_id) REFERENCES public.experiments(id) ON DELETE RESTRICT;


--
-- Name: translation_runs fk_rails_4f7b20a5c6; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.translation_runs
    ADD CONSTRAINT fk_rails_4f7b20a5c6 FOREIGN KEY (llm_model_id) REFERENCES public.llm_models(id);


--
-- Name: judge_segment_runs fk_rails_509aa0248c; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.judge_segment_runs
    ADD CONSTRAINT fk_rails_509aa0248c FOREIGN KEY (experiment_segment_id) REFERENCES public.experiment_segments(id) ON DELETE RESTRICT;


--
-- Name: documents fk_rails_55cfc1b0e0; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.documents
    ADD CONSTRAINT fk_rails_55cfc1b0e0 FOREIGN KEY (project_id) REFERENCES public.projects(id);


--
-- Name: workflow_profile_revisions fk_rails_583a4f3dd8; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.workflow_profile_revisions
    ADD CONSTRAINT fk_rails_583a4f3dd8 FOREIGN KEY (workflow_profile_id) REFERENCES public.workflow_profiles(id) ON DELETE RESTRICT;


--
-- Name: review_segment_runs fk_rails_5a4f381196; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.review_segment_runs
    ADD CONSTRAINT fk_rails_5a4f381196 FOREIGN KEY (experiment_segment_id) REFERENCES public.experiment_segments(id) ON DELETE RESTRICT;


--
-- Name: final_translation_versions fk_rails_66d447950e; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.final_translation_versions
    ADD CONSTRAINT fk_rails_66d447950e FOREIGN KEY (source_finalization_run_id) REFERENCES public.finalization_runs(id);


--
-- Name: glossaries fk_rails_69f9289450; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.glossaries
    ADD CONSTRAINT fk_rails_69f9289450 FOREIGN KEY (user_id) REFERENCES public.users(id) ON DELETE RESTRICT;


--
-- Name: review_evaluations fk_rails_6ebbd5788e; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.review_evaluations
    ADD CONSTRAINT fk_rails_6ebbd5788e FOREIGN KEY (translation_run_id) REFERENCES public.translation_runs(id);


--
-- Name: judge_evaluations fk_rails_726a6c8b0b; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.judge_evaluations
    ADD CONSTRAINT fk_rails_726a6c8b0b FOREIGN KEY (judge_run_id) REFERENCES public.judge_runs(id);


--
-- Name: translation_workspace_drafts fk_rails_72cbb19784; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.translation_workspace_drafts
    ADD CONSTRAINT fk_rails_72cbb19784 FOREIGN KEY (user_id) REFERENCES public.users(id) ON DELETE CASCADE;


--
-- Name: sessions fk_rails_758836b4f0; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.sessions
    ADD CONSTRAINT fk_rails_758836b4f0 FOREIGN KEY (user_id) REFERENCES public.users(id) ON DELETE CASCADE;


--
-- Name: experiments fk_rails_78c1da6c54; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.experiments
    ADD CONSTRAINT fk_rails_78c1da6c54 FOREIGN KEY (glossary_revision_id) REFERENCES public.glossary_revisions(id) ON DELETE RESTRICT;


--
-- Name: workflow_profile_model_selections fk_rails_7f68048efb; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.workflow_profile_model_selections
    ADD CONSTRAINT fk_rails_7f68048efb FOREIGN KEY (workflow_profile_revision_id) REFERENCES public.workflow_profile_revisions(id) ON DELETE RESTRICT;


--
-- Name: experiments fk_rails_82525cd803; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.experiments
    ADD CONSTRAINT fk_rails_82525cd803 FOREIGN KEY (methodology_profile_revision_id) REFERENCES public.methodology_profile_revisions(id) ON DELETE RESTRICT;


--
-- Name: translation_segment_runs fk_rails_87331f9d13; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.translation_segment_runs
    ADD CONSTRAINT fk_rails_87331f9d13 FOREIGN KEY (experiment_segment_id) REFERENCES public.experiment_segments(id) ON DELETE RESTRICT;


--
-- Name: workflow_profiles fk_rails_878191656d; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.workflow_profiles
    ADD CONSTRAINT fk_rails_878191656d FOREIGN KEY (user_id) REFERENCES public.users(id) ON DELETE RESTRICT;


--
-- Name: final_translations fk_rails_880ac8bc08; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.final_translations
    ADD CONSTRAINT fk_rails_880ac8bc08 FOREIGN KEY (experiment_id) REFERENCES public.experiments(id);


--
-- Name: judge_runs fk_rails_8a4030c1c3; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.judge_runs
    ADD CONSTRAINT fk_rails_8a4030c1c3 FOREIGN KEY (judge_llm_model_id) REFERENCES public.llm_models(id);


--
-- Name: final_translations fk_rails_8ba8994fe0; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.final_translations
    ADD CONSTRAINT fk_rails_8ba8994fe0 FOREIGN KEY (judge_round_id) REFERENCES public.judge_rounds(id);


--
-- Name: finalization_rounds fk_rails_8fd1ee5160; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.finalization_rounds
    ADD CONSTRAINT fk_rails_8fd1ee5160 FOREIGN KEY (base_final_translation_version_id) REFERENCES public.final_translation_versions(id);


--
-- Name: final_translation_version_segments fk_rails_9521c97ed5; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.final_translation_version_segments
    ADD CONSTRAINT fk_rails_9521c97ed5 FOREIGN KEY (experiment_segment_id) REFERENCES public.experiment_segments(id) ON DELETE RESTRICT;


--
-- Name: active_storage_variant_records fk_rails_993965df05; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.active_storage_variant_records
    ADD CONSTRAINT fk_rails_993965df05 FOREIGN KEY (blob_id) REFERENCES public.active_storage_blobs(id);


--
-- Name: pipeline_runs fk_rails_99531aa0f4; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.pipeline_runs
    ADD CONSTRAINT fk_rails_99531aa0f4 FOREIGN KEY (workflow_profile_revision_id) REFERENCES public.workflow_profile_revisions(id) ON DELETE RESTRICT;


--
-- Name: methodology_profiles fk_rails_a1b3f8d960; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.methodology_profiles
    ADD CONSTRAINT fk_rails_a1b3f8d960 FOREIGN KEY (user_id) REFERENCES public.users(id) ON DELETE RESTRICT;


--
-- Name: glossary_revisions fk_rails_a1c3a688ad; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.glossary_revisions
    ADD CONSTRAINT fk_rails_a1c3a688ad FOREIGN KEY (glossary_id) REFERENCES public.glossaries(id) ON DELETE RESTRICT;


--
-- Name: experiments fk_rails_a797eeb5e6; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.experiments
    ADD CONSTRAINT fk_rails_a797eeb5e6 FOREIGN KEY (document_id) REFERENCES public.documents(id);


--
-- Name: finalization_rounds fk_rails_a9008f6c19; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.finalization_rounds
    ADD CONSTRAINT fk_rails_a9008f6c19 FOREIGN KEY (final_translation_id) REFERENCES public.final_translations(id);


--
-- Name: final_translation_version_segments fk_rails_aaea87ab7f; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.final_translation_version_segments
    ADD CONSTRAINT fk_rails_aaea87ab7f FOREIGN KEY (final_translation_version_id) REFERENCES public.final_translation_versions(id) ON DELETE RESTRICT;


--
-- Name: review_evaluations fk_rails_b26ead8ac6; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.review_evaluations
    ADD CONSTRAINT fk_rails_b26ead8ac6 FOREIGN KEY (review_run_id) REFERENCES public.review_runs(id);


--
-- Name: document_execution_plans fk_rails_b3e9d0a27e; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.document_execution_plans
    ADD CONSTRAINT fk_rails_b3e9d0a27e FOREIGN KEY (experiment_id) REFERENCES public.experiments(id) ON DELETE RESTRICT;


--
-- Name: judge_segment_runs fk_rails_b653d64002; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.judge_segment_runs
    ADD CONSTRAINT fk_rails_b653d64002 FOREIGN KEY (judge_run_id) REFERENCES public.judge_runs(id) ON DELETE RESTRICT;


--
-- Name: projects fk_rails_b872a6760a; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.projects
    ADD CONSTRAINT fk_rails_b872a6760a FOREIGN KEY (user_id) REFERENCES public.users(id) ON DELETE RESTRICT;


--
-- Name: federated_identities fk_rails_ba05d5a23b; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.federated_identities
    ADD CONSTRAINT fk_rails_ba05d5a23b FOREIGN KEY (user_id) REFERENCES public.users(id) ON DELETE CASCADE;


--
-- Name: finalization_segment_runs fk_rails_c171c093d3; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.finalization_segment_runs
    ADD CONSTRAINT fk_rails_c171c093d3 FOREIGN KEY (finalization_run_id) REFERENCES public.finalization_runs(id) ON DELETE RESTRICT;


--
-- Name: final_translation_versions fk_rails_c19fcd6f30; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.final_translation_versions
    ADD CONSTRAINT fk_rails_c19fcd6f30 FOREIGN KEY (final_translation_id) REFERENCES public.final_translations(id);


--
-- Name: active_storage_attachments fk_rails_c3b3935057; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.active_storage_attachments
    ADD CONSTRAINT fk_rails_c3b3935057 FOREIGN KEY (blob_id) REFERENCES public.active_storage_blobs(id);


--
-- Name: finalization_runs fk_rails_c4273eec6a; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.finalization_runs
    ADD CONSTRAINT fk_rails_c4273eec6a FOREIGN KEY (finalizer_llm_model_id) REFERENCES public.llm_models(id);


--
-- Name: translation_segment_runs fk_rails_c71cadafbc; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.translation_segment_runs
    ADD CONSTRAINT fk_rails_c71cadafbc FOREIGN KEY (translation_run_id) REFERENCES public.translation_runs(id) ON DELETE RESTRICT;


--
-- Name: translation_reference_revisions fk_rails_c9dcbca26e; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.translation_reference_revisions
    ADD CONSTRAINT fk_rails_c9dcbca26e FOREIGN KEY (translation_reference_id) REFERENCES public.translation_references(id) ON DELETE RESTRICT;


--
-- Name: translation_references fk_rails_ccc71a71c6; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.translation_references
    ADD CONSTRAINT fk_rails_ccc71a71c6 FOREIGN KEY (user_id) REFERENCES public.users(id) ON DELETE RESTRICT;


--
-- Name: review_rounds fk_rails_e4d2c9843a; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.review_rounds
    ADD CONSTRAINT fk_rails_e4d2c9843a FOREIGN KEY (experiment_id) REFERENCES public.experiments(id);


--
-- Name: finalization_segment_runs fk_rails_ee050b2119; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.finalization_segment_runs
    ADD CONSTRAINT fk_rails_ee050b2119 FOREIGN KEY (experiment_segment_id) REFERENCES public.experiment_segments(id) ON DELETE RESTRICT;


--
-- Name: translation_workspace_submissions fk_rails_f630897a9e; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.translation_workspace_submissions
    ADD CONSTRAINT fk_rails_f630897a9e FOREIGN KEY (user_id) REFERENCES public.users(id) ON DELETE RESTRICT;


--
-- Name: judge_rounds fk_rails_f6e43a8dc5; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.judge_rounds
    ADD CONSTRAINT fk_rails_f6e43a8dc5 FOREIGN KEY (review_round_id) REFERENCES public.review_rounds(id);


--
-- Name: translation_references fk_translation_references_owned_current_revision; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.translation_references
    ADD CONSTRAINT fk_translation_references_owned_current_revision FOREIGN KEY (id, current_revision_id) REFERENCES public.translation_reference_revisions(translation_reference_id, id);


--
-- Name: workflow_profiles fk_workflow_profiles_owned_current_revision; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.workflow_profiles
    ADD CONSTRAINT fk_workflow_profiles_owned_current_revision FOREIGN KEY (id, current_revision_id) REFERENCES public.workflow_profile_revisions(workflow_profile_id, id);


--
-- PostgreSQL database dump complete
--

SET search_path TO "$user", public;

INSERT INTO "schema_migrations" (version) VALUES
('20261002090000'),
('20260930090000'),
('20260929120200'),
('20260929120100'),
('20260929120000'),
('20260929090200'),
('20260929090100'),
('20260929090000'),
('20260924090200'),
('20260924090100'),
('20260924090000'),
('20260920090100'),
('20260920090000'),
('20260914090300'),
('20260914090200'),
('20260914090100'),
('20260914090000'),
('20260907090000'),
('20260906090000'),
('20260901110000'),
('20260901100000'),
('20260901025500'),
('20260901025400'),
('20260831090000'),
('20260830170400'),
('20260830170300'),
('20260830170200'),
('20260830170100'),
('20260830170000'),
('20260830090000'),
('20260829090000'),
('20260828120002'),
('20260828120001'),
('20260828120000'),
('20260828100000'),
('20260827120000'),
('20260827100001'),
('20260827100000'),
('20260827090001'),
('20260827090000'),
('20260826090000'),
('20260825090000'),
('20260824090001'),
('20260824090000'),
('20260824064807'),
('20260824064757'),
('20260824050255'),
('20260824050254'),
('20260824050253'),
('20260824050252');

