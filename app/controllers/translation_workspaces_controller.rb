class TranslationWorkspacesController < ApplicationController
  before_action :load_available_models

  def new
    @translation_workspace = TranslationWorkspace.new
  end

  def create
    @translation_workspace = TranslationWorkspace.new(translation_workspace_params)

    if @translation_workspace.submit
      redirect_to @translation_workspace.experiment,
                  notice: "Translation experiment started."
    else
      render :new, status: :unprocessable_content
    end
  end

  private

  def load_available_models
    @available_models = LlmModel.active_openrouter.order(:display_name, :id)
  end

  def translation_workspace_params
    params.require(:translation_workspace).permit(
      :project_name,
      :source_language,
      :target_language,
      :document_title,
      :source_text,
      :experiment_name,
      :instruction_prompt,
      model_ids: []
    )
  end
end
