# The guided product tours and the account's onboarding outcome.
#
# Tours are educational only: the island (app/frontend/islands/product_tour)
# highlights elements marked with data-tour-target and never clicks, submits,
# or changes anything. This registry is the single source of what each tour
# shows; text comes from config/locales/product_tour.*.yml.
#
# Durable state is two users columns: the tour version the account resolved
# and how. Only the global tour's offer is persisted; contextual page tours
# start from Help and are never offered automatically, so they keep no state.
module ProductTour
  # Raise when the global tour changes enough that every account, including
  # those that completed or dismissed an earlier version, should be offered
  # it again.
  VERSION = 1
  OUTCOMES = %w[completed dismissed].freeze

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

  def self.offered?(user)
    user.product_tour_version.nil? || user.product_tour_version < VERSION
  end

  # Records how the account resolved the current tour version. The first
  # resolution wins: one conditional UPDATE, so a double click, a retried
  # request, or a second tab never overwrites it or writes twice. Returns
  # whether this call recorded it.
  def self.record_outcome!(user, outcome)
    raise ArgumentError, "unknown product tour outcome" unless OUTCOMES.include?(outcome)

    User.where(id: user.id)
      .where("product_tour_version IS NULL OR product_tour_version < ?", VERSION)
      .update_all(product_tour_version: VERSION, product_tour_outcome: outcome, updated_at: Time.current) == 1
  end
end
