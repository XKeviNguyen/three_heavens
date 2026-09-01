require "test_helper"
require_relative "../support/document_io_test_helper"
require_relative "../support/methodology_profile_test_helper"
require_relative "../support/workflow_profile_test_helper"

class ProjectWorkspacesTest < ActionDispatch::IntegrationTest
  include ActiveJob::TestHelper
  include DocumentIoTestHelper
  include MethodologyProfileTestHelper
  include WorkflowProfileTestHelper

  setup do
    sign_in_as users(:normal)
    @model = llm_models(:openrouter_claude)
    @project = users(:normal).projects.create!(
      name: "Reusable sermons",
      source_language: "Vietnamese",
      target_language: "Japanese"
    )
  end

  test "Project index is owner scoped and shows concise counts and activity" do
    @project.documents.create!(title: "Owned document", source_text: "Owned source")
    projects(:two).update!(name: "Foreign private project")

    get projects_path

    assert_response :success
    assert_select "h1", "Projects"
    assert_select "a[href='#{project_path(@project)}']", text: "Open project"
    assert_select "article", text: /Reusable sermons.*Vietnamese.*Japanese.*Documents.*1.*Experiments.*0/m
    assert_select "article", text: /Foreign private project/, count: 0
    assert_select "a[href='#{new_translation_workspace_path}']", text: /Start a new project translation/
  end

  test "Project index activity includes downstream workflow updates" do
    document = @project.documents.create!(title: "Active document", source_text: "Source")
    experiment = document.experiments.create!(name: "Active experiment", instruction_prompt: "Translate.")
    pipeline = create_pipeline_run(experiment: experiment)
    less_recent = users(:normal).projects.create!(
      name: "Less recent Project",
      source_language: "Vietnamese",
      target_language: "Japanese"
    )
    less_recent.update_columns(updated_at: Time.current)
    pipeline.update_columns(updated_at: 1.minute.from_now)

    get projects_path

    assert_response :success
    assert_operator response.body.index("Reusable sermons"), :<, response.body.index("Less recent Project")
  end

  test "foreign Project routes are not found even for an administrator" do
    get project_path(projects(:two))
    assert_response :not_found

    sign_out
    sign_in_as users(:admin)
    get project_path(@project)
    assert_response :not_found
  end

  test "Project show renders multiple documents and experiment progress newest first" do
    older = @project.documents.create!(title: "Older source", source_text: "Older")
    older.experiments.create!(name: "Manual draft", instruction_prompt: "Translate.", status: :completed)
    newer = @project.documents.create!(title: "Newer source", source_text: "Newer", created_at: 1.minute.from_now)
    automatic = newer.experiments.create!(name: "Automatic draft", instruction_prompt: "Translate.", status: :running)
    pipeline = create_pipeline_run(experiment: automatic)

    get project_path(@project)

    assert_response :success
    assert_select "h1", "Reusable sermons"
    assert_operator response.body.index("Newer source"), :<, response.body.index("Older source")
    assert_select "section", text: /Automatic draft.*Automatic workflow.*Running/m
    assert_select "section", text: /Manual draft.*Manual workflow.*Completed/m
    assert_select "a[href='#{pipeline_run_path(pipeline)}']", text: "Pipeline progress"
    assert_select "a[href='#{new_translation_workspace_path(project_id: @project.id)}']", text: /Paste text/
    assert_select "a[href='#{new_source_import_path(project_id: @project.id)}']", text: "Upload source file"
  end

  test "empty Project show has useful launch actions" do
    get project_path(@project)

    assert_response :success
    assert_select "h2", "No source documents yet"
    assert_select "a[href='#{new_translation_workspace_path(project_id: @project.id)}']", minimum: 1
    assert_select "a[href='#{new_source_import_path(project_id: @project.id)}']", text: "Upload source file"
  end

  test "existing Project workspace hides mutable Project fields and filters language snapshots" do
    matching_methodology = create_methodology_profile(
      source_language: " vietnamese ",
      target_language: "JAPANESE"
    )
    mismatched_methodology = create_methodology_profile(name: "English method", target_language: "English")
    matching_glossary = create_glossary(
      name: "Matching glossary",
      source_language: " vietnamese ",
      target_language: "JAPANESE"
    )
    mismatched_glossary = create_glossary(name: "English glossary", target_language: "English")

    get new_translation_workspace_path(project_id: @project.id)

    assert_response :success
    assert_select "h1", "Add a translation to this Project"
    assert_select "input[name='translation_workspace[project_id]'][value='#{@project.id}']"
    assert_select "input[name='translation_workspace[project_name]']", count: 0
    assert_select "input[name='translation_workspace[source_language]']", count: 0
    assert_select "input[name='translation_workspace[target_language]']", count: 0
    assert_select "input[value='#{matching_methodology.current_revision_id}']"
    assert_select "input[value='#{mismatched_methodology.current_revision_id}']", count: 0
    assert_select "input[value='#{matching_glossary.current_revision_id}']"
    assert_select "input[value='#{mismatched_glossary.current_revision_id}']", count: 0
  end

  test "manual existing Project launch creates only one Document and Experiment with authoritative Project data" do
    glossary = create_glossary
    methodology = create_methodology_profile
    original_attributes = @project.attributes.slice("name", "source_language", "target_language")

    assert_no_difference -> { Project.count } do
      assert_difference -> { Document.count }, 1 do
        assert_difference -> { Experiment.count }, 1 do
          assert_enqueued_jobs 1, only: TranslationRunJob do
            post translation_workspace_path, params: {
              translation_workspace: manual_attributes.merge(
                project_id: @project.id.to_s,
                project_name: "Tampered name",
                source_language: "English",
                target_language: "French",
                glossary_revision_id: glossary.current_revision_id.to_s,
                methodology_profile_revision_id: methodology.current_revision_id.to_s
              )
            }
          end
        end
      end
    end

    experiment = Experiment.order(:id).last
    assert_redirected_to experiment_path(experiment)
    assert_equal @project, experiment.document.project
    assert_equal glossary.current_revision, experiment.glossary_revision
    assert_equal methodology.current_revision, experiment.methodology_profile_revision
    assert_equal original_attributes, @project.reload.attributes.slice("name", "source_language", "target_language")
  end

  test "automatic existing Project launch creates one Pipeline under the selected Project" do
    profile = create_workflow_profile

    assert_no_difference -> { Project.count } do
      assert_difference -> { Document.count }, 1 do
        assert_difference -> { Experiment.count }, 1 do
          assert_difference -> { PipelineRun.count }, 1 do
            assert_enqueued_jobs 2, only: TranslationRunJob do
              post translation_workspace_path, params: {
                translation_workspace: manual_attributes.merge(
                  project_id: @project.id.to_s,
                  workflow_mode: "automatic",
                  model_ids: [],
                  workflow_profile_revision_id: profile.current_revision_id.to_s,
                  automatic_confirmation: "1"
                )
              }
            end
          end
        end
      end
    end

    pipeline = PipelineRun.order(:id).last
    assert_redirected_to pipeline_run_path(pipeline)
    assert_equal @project, pipeline.experiment.document.project
    assert_equal profile.current_revision, pipeline.workflow_profile_revision
  end

  test "malformed foreign and administrator Project IDs fail before persistence or scheduling" do
    [ "not-an-id", "0", "-1" ].each do |project_id|
      assert_no_workspace_or_jobs do
        post translation_workspace_path, params: {
          translation_workspace: manual_attributes.merge(project_id:, submission_token: issue_translation_workspace_token)
        }
      end
      assert_response :bad_request
    end

    assert_no_workspace_or_jobs do
      post translation_workspace_path, params: {
        translation_workspace: manual_attributes.merge(project_id: projects(:two).id.to_s)
      }
    end
    assert_response :not_found

    assert_no_workspace_or_jobs do
      post translation_workspace_path, params: {
        translation_workspace: manual_attributes.merge(project_id: [ @project.id.to_s ])
      }
    end
    assert_response :bad_request

    sign_out
    sign_in_as users(:admin)
    assert_no_workspace_or_jobs do
      post translation_workspace_path, params: {
        translation_workspace: manual_attributes.merge(
          project_id: @project.id.to_s,
          submission_token: issue_translation_workspace_token(user: users(:admin))
        )
      }
    end
    assert_response :not_found
  end

  test "Project ownership is rechecked under lock after earlier validation" do
    workspace = TranslationWorkspace.new(
      manual_attributes.except(:submission_token).merge(user: users(:normal), project_id: @project.id),
      existing_project: @project
    )
    assert workspace.valid?
    @project.update!(user: users(:other))
    lock_queries = []
    test_thread = Thread.current
    subscriber = ActiveSupport::Notifications.subscribe("sql.active_record") do |*, payload|
      lock_queries << payload[:sql] if Thread.current == test_thread && payload[:sql].include?('"projects"')
    end

    begin
      assert_no_difference [ -> { Document.count }, -> { Experiment.count }, -> { TranslationRun.count } ] do
        assert_no_enqueued_jobs only: TranslationRunJob do
          assert_not workspace.submit
        end
      end
    ensure
      ActiveSupport::Notifications.unsubscribe(subscriber)
    end
    assert_includes workspace.errors[:project_id], "is not available"
    assert lock_queries.any? { |sql| sql.include?("FOR UPDATE") }
  end

  test "existing Project submission replay returns the first Experiment without duplicate work" do
    token = issue_translation_workspace_token
    attributes = manual_attributes.merge(project_id: @project.id.to_s, submission_token: token)

    assert_enqueued_jobs 1, only: TranslationRunJob do
      post translation_workspace_path, params: { translation_workspace: attributes }
    end
    experiment = Experiment.order(:id).last
    counts = [ Project.count, Document.count, Experiment.count, TranslationRun.count, PipelineRun.count ]

    assert_no_enqueued_jobs only: TranslationRunJob do
      post translation_workspace_path, params: {
        translation_workspace: attributes.merge(document_title: "Ignored replay")
      }
    end

    assert_redirected_to experiment_path(experiment)
    assert_equal counts, [ Project.count, Document.count, Experiment.count, TranslationRun.count, PipelineRun.count ]
    assert_equal @project, experiment.document.project
  end

  test "Project upload preview and consumption stay bound to the exact owned Project" do
    assert_no_enqueued_jobs only: TranslationRunJob do
      get new_source_import_path(project_id: @project.id)
    end
    assert_response :success
    assert_select "input[name='source_import[project_id]'][value='#{@project.id}']"

    assert_no_enqueued_jobs only: TranslationRunJob do
      post source_imports_path, params: {
        source_import: {
          project_id: @project.id.to_s,
          source_file: uploaded_file("Imported source", filename: "project.txt", content_type: "text/plain")
        }
      }
    end
    source_import = SourceImport.order(:id).last
    redirect_query = Rack::Utils.parse_query(URI.parse(response.location).query)
    project_binding = redirect_query.fetch("source_import_project_token")
    assert_equal source_import.id.to_s, redirect_query.fetch("source_import_id")
    assert_equal @project.id.to_s, redirect_query.fetch("project_id")
    assert SourceImports::ProjectBinding.valid?(
      token: project_binding,
      source_import:,
      project: @project
    )
    follow_redirect!
    assert_select "input[name='translation_workspace[project_id]'][value='#{@project.id}']"
    assert_select "input[name='translation_workspace[source_import_id]'][value='#{source_import.id}']"
    assert_select "input[name='translation_workspace[source_import_project_token]'][value='#{project_binding}']"

    assert_no_difference -> { Project.count } do
      assert_enqueued_jobs 1, only: TranslationRunJob do
        post translation_workspace_path, params: {
          translation_workspace: manual_attributes.merge(
            project_id: @project.id.to_s,
            source_import_id: source_import.id.to_s,
            source_import_project_token: project_binding,
            source_text: "Reviewed imported source"
          )
        }
      end
    end

    document = source_import.reload.resulting_document
    assert_equal @project, document.project
    assert document.uploaded_file?
    assert_equal "Reviewed imported source", document.source_text
    assert source_import.consumed?
  end

  test "foreign Project identity cannot be smuggled through SourceImport boundaries" do
    assert_no_difference -> { SourceImport.count } do
      assert_no_enqueued_jobs only: TranslationRunJob do
        post source_imports_path, params: {
          source_import: {
            project_id: projects(:two).id.to_s,
            source_file: uploaded_file("Private", filename: "private.txt", content_type: "text/plain")
          }
        }
      end
    end
    assert_response :not_found

    source_import = create_ready_import(user: users(:normal))
    assert_no_workspace_or_jobs do
      get new_translation_workspace_path(source_import_id: source_import.id, project_id: projects(:two).id)
    end
    assert_response :not_found
    assert source_import.reload.ready?
  end

  test "an owned upload cannot be moved to another owned Project" do
    other_owned_project = users(:normal).projects.create!(
      name: "Other owned Project",
      source_language: "Vietnamese",
      target_language: "Japanese"
    )
    post source_imports_path, params: {
      source_import: {
        project_id: @project.id.to_s,
        source_file: uploaded_file("Bound source", filename: "bound.txt", content_type: "text/plain")
      }
    }
    source_import = SourceImport.order(:id).last
    redirect_query = Rack::Utils.parse_query(URI.parse(response.location).query)
    project_binding = redirect_query.fetch("source_import_project_token")

    get new_translation_workspace_path(
      source_import_id: source_import.id,
      project_id: other_owned_project.id,
      source_import_project_token: project_binding
    )
    assert_response :not_found

    get new_translation_workspace_path(source_import_id: source_import.id, project_id: @project.id)
    assert_response :not_found

    assert_no_workspace_or_jobs do
      post translation_workspace_path, params: {
        translation_workspace: manual_attributes.merge(
          project_id: other_owned_project.id.to_s,
          source_import_id: source_import.id.to_s,
          source_import_project_token: project_binding
        )
      }
    end
    assert_response :not_found
    assert source_import.reload.ready?
  end

  private

  def manual_attributes
    {
      project_name: "New Project compatibility",
      source_language: "Vietnamese",
      target_language: "Japanese",
      document_title: "Project source",
      source_text: "Source passage",
      experiment_name: "Project experiment",
      instruction_prompt: "Translate faithfully.",
      workflow_mode: "manual",
      model_ids: [ @model.id.to_s ],
      submission_token: issue_translation_workspace_token
    }
  end

  def create_glossary(name: "Project glossary", source_language: "Vietnamese", target_language: "Japanese")
    Glossaries::Create.call(
      user: users(:normal),
      attributes: {
        name:,
        source_language:,
        target_language:,
        entries: [ { source_term: "faith", preferred_target_term: "信仰" } ]
      }
    )
  end

  def assert_no_workspace_or_jobs
    counts = [ Project.count, Document.count, Experiment.count, TranslationRun.count, PipelineRun.count ]
    assert_no_enqueued_jobs only: TranslationRunJob do
      yield
    end
    assert_equal counts, [ Project.count, Document.count, Experiment.count, TranslationRun.count, PipelineRun.count ]
  end
end
