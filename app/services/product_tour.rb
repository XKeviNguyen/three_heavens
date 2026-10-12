# The guided product tours and the account's onboarding outcome.
#
# Tours are educational only: the island (app/frontend/islands/product_tour)
# highlights elements marked with data-tour-target and never clicks, submits,
# or changes anything. This registry is the single source of what each tour
# shows; text comes from config/locales/product_tour.*.yml.
#
# Durable state:
# - users.product_tour_version/outcome: how the account resolved the global
#   tour's offer (once per VERSION).
# - users.product_tour_page_guides: whether page guides open by themselves the
#   first time a page is visited. Off for existing accounts; turned on when a
#   newly offered global tour is completed; the account can change it in Help.
# - product_tour_page_outcomes: one row per page context ("projects:list") and
#   PAGE_VERSION, written once when a page guide ends, so it opens by itself
#   at most once. Replaying from Help never removes a row.
module ProductTour
  # Raise when the global tour changes enough that every account, including
  # those that completed or dismissed an earlier version, should be offered
  # it again.
  VERSION = 1
  # Raise to show every page guide automatically again (to accounts with page
  # guides on), for example after rewriting them.
  PAGE_VERSION = 1
  OUTCOMES = %w[completed dismissed].freeze
  # A page family has up to three contexts with different tasks: its list, its
  # forms, and a record's own page. Each context is taught once.
  PAGE_CONTEXTS = {
    "index" => "list",
    "new" => "form", "create" => "form", "edit" => "form", "update" => "form",
    "show" => "detail"
  }.freeze

  # A step is either centered (no target) or anchored to the first visible
  # element among its targets. When none is visible (a closed mobile drawer,
  # an empty state, a permission the user lacks), a global step is shown
  # centered and a page step is skipped.
  GLOBAL_STEPS = [
    { id: "welcome" },
    { id: "workspace", targets: %w[nav-work nav-menu] },
    { id: "knowledge", targets: %w[nav-library nav-menu] },
    { id: "workflows", targets: %w[nav-workflows nav-menu] },
    { id: "ai_access", targets: %w[nav-ai-settings nav-menu] },
    { id: "start", targets: %w[nav-new-translation nav-menu] },
    { id: "quality" }
  ].freeze

  # Page tours by feature family. Each opens with a centered introduction,
  # then points at whichever of its elements the current page shows, so one
  # tour serves the family's index, form, and detail pages.
  PAGE_TOURS = {
    "new_translation" => {
      controllers: %w[translation_workspaces],
      steps: [
        { id: "intro" },
        { id: "languages", targets: %w[workspace-languages] },
        { id: "source", targets: %w[workspace-source] },
        { id: "knowledge", targets: %w[workspace-knowledge] },
        { id: "workflow", targets: %w[workspace-workflow] },
        { id: "launch", targets: %w[workspace-launch] }
      ]
    },
    "source_import" => {
      controllers: %w[source_imports],
      steps: [
        { id: "intro" },
        { id: "file", targets: %w[source-import-file] }
      ]
    },
    "projects" => {
      controllers: %w[projects],
      steps: [
        { id: "intro" },
        { id: "list", targets: %w[record-list] },
        { id: "start", targets: %w[project-start] },
        { id: "documents", targets: %w[project-documents] },
        { id: "next_action", targets: %w[project-next-action] }
      ]
    },
    "history" => {
      controllers: %w[history],
      steps: [
        { id: "intro" },
        { id: "list", targets: %w[record-list] },
        { id: "reopen", targets: %w[history-next-action] }
      ]
    },
    "terminology" => {
      controllers: %w[glossaries],
      steps: [
        { id: "intro" },
        { id: "create", targets: %w[library-new] },
        { id: "list", targets: %w[record-list] },
        { id: "entries", targets: %w[library-form] },
        { id: "revisions", targets: %w[library-revisions] },
        { id: "status", targets: %w[library-status] }
      ]
    },
    "references" => {
      controllers: %w[translation_references],
      steps: [
        { id: "intro" },
        { id: "create", targets: %w[library-new] },
        { id: "list", targets: %w[record-list] },
        { id: "source", targets: %w[reference-source] },
        { id: "translation", targets: %w[reference-translation] },
        { id: "revisions", targets: %w[library-revisions] }
      ]
    },
    "methodology" => {
      controllers: %w[methodology_profiles],
      steps: [
        { id: "intro" },
        { id: "create", targets: %w[library-new] },
        { id: "list", targets: %w[record-list] },
        { id: "instructions", targets: %w[library-form] },
        { id: "revisions", targets: %w[library-revisions] }
      ]
    },
    "workflows" => {
      controllers: %w[workflow_profiles pipeline_runs],
      steps: [
        { id: "intro" },
        { id: "create", targets: %w[library-new] },
        { id: "list", targets: %w[record-list] },
        { id: "configure", targets: %w[library-form] },
        { id: "completion", targets: %w[workflow-completion] },
        { id: "pipeline", targets: %w[pipeline-status] }
      ]
    },
    "ai_settings" => {
      controllers: %w[settings/ai_settings],
      steps: [
        { id: "intro" },
        { id: "status", targets: %w[ai-status] },
        { id: "source", targets: %w[ai-source] },
        { id: "key", targets: %w[ai-key] },
        { id: "billing", targets: %w[ai-billing] }
      ]
    },
    "results" => {
      controllers: %w[experiments],
      steps: [
        { id: "intro" },
        { id: "progress", targets: %w[workflow-steps] },
        { id: "outputs", targets: %w[run-outputs] },
        { id: "retry", targets: %w[run-retry] },
        { id: "next", targets: %w[run-next] }
      ]
    },
    "blind_review" => {
      controllers: %w[review_rounds],
      steps: [
        { id: "intro" },
        { id: "progress", targets: %w[workflow-steps] },
        { id: "evaluations", targets: %w[run-outputs] },
        { id: "retry", targets: %w[run-retry] },
        { id: "next", targets: %w[run-next] }
      ]
    },
    "judging" => {
      controllers: %w[judge_rounds],
      steps: [
        { id: "intro" },
        { id: "progress", targets: %w[workflow-steps] },
        { id: "winner", targets: %w[judge-winner] },
        { id: "runs", targets: %w[run-outputs] },
        { id: "retry", targets: %w[run-retry] }
      ]
    },
    "final_editor" => {
      controllers: %w[final_translations],
      steps: [
        { id: "intro" },
        { id: "guidance", targets: %w[editor-guidance] },
        { id: "draft", targets: %w[editor-draft] },
        { id: "refine", targets: %w[editor-refine] },
        { id: "revisions", targets: %w[library-revisions] },
        { id: "finalize", targets: %w[editor-finalize] }
      ]
    },
    "benchmarks" => {
      controllers: %w[benchmarks],
      steps: [
        { id: "intro" },
        { id: "sort", targets: %w[benchmarks-sort] },
        { id: "list", targets: %w[record-list] },
        { id: "roles", targets: %w[benchmarks-roles] }
      ]
    }
  }.freeze

  PAGE_TOUR_BY_CONTROLLER = PAGE_TOURS.each_with_object({}) do |(key, tour), index|
    tour[:controllers].each { |controller| index[controller] = key }
  end.freeze

  def self.page_tour_key(controller_path)
    PAGE_TOUR_BY_CONTROLLER[controller_path]
  end

  # The context key for the page being rendered, or nil when this page has no
  # guide or is not a plain page view (a re-rendered form after a failed
  # submit is mid-task, never a moment to teach).
  def self.page_context_key(controller_path, action_name, request_method)
    return nil unless request_method == "GET"

    family = page_tour_key(controller_path)
    context = PAGE_CONTEXTS[action_name]
    family && context && "#{family}:#{context}"
  end

  PAGE_KEY = /\A(?<family>[a-z_]+):(?:list|form|detail)\z/

  def self.valid_page_key?(key)
    match = PAGE_KEY.match(key.to_s)
    match.present? && PAGE_TOURS.key?(match[:family])
  end

  def self.page_seen?(user, key)
    user.product_tour_page_outcomes.exists?(tour_key: key, version: PAGE_VERSION)
  end

  # Records how the account ended a page guide. The first outcome per key and
  # version wins (INSERT ... ON CONFLICT DO NOTHING): a double click, a retry,
  # or a second tab writes nothing more. Returns whether this call recorded it.
  def self.record_page_outcome!(user, key, outcome)
    raise ArgumentError, "unknown product tour outcome" unless OUTCOMES.include?(outcome)
    raise ArgumentError, "unknown page guide" unless valid_page_key?(key)

    result = ProductTourPageOutcome.insert_all(
      [ { user_id: user.id, tour_key: key, version: PAGE_VERSION, outcome: outcome, created_at: Time.current } ],
      unique_by: :index_product_tour_page_outcomes_once,
      returning: :id
    )
    result.rows.any?
  end

  def self.set_page_guides!(user, enabled)
    User.where(id: user.id).update_all(product_tour_page_guides: enabled, updated_at: Time.current)
  end

  def self.offered?(user)
    user.product_tour_version.nil? || user.product_tour_version < VERSION
  end

  # Records how the account resolved the current tour version. The first
  # resolution wins: one conditional UPDATE, so a double click, a retried
  # request, or a second tab never overwrites it or writes twice. Completing
  # an account's first tour also turns page guides on, in the same UPDATE; a
  # dismissal leaves them off, so the account is not shown a guide on every
  # page it then opens, and a later tour version never overrides the switch
  # the account already has. Returns whether this call recorded it.
  def self.record_outcome!(user, outcome)
    raise ArgumentError, "unknown product tour outcome" unless OUTCOMES.include?(outcome)

    User.where(id: user.id)
      .where("product_tour_version IS NULL OR product_tour_version < ?", VERSION)
      .update_all([ <<~SQL.squish, VERSION, outcome, Time.current, outcome == "completed" ]) == 1
        product_tour_version = ?, product_tour_outcome = ?, updated_at = ?,
        product_tour_page_guides = CASE WHEN product_tour_version IS NULL AND ? THEN TRUE ELSE product_tour_page_guides END
      SQL
  end
end
