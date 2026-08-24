class AddInstructionPromptToExperiments < ActiveRecord::Migration[8.1]
  def change
    add_column :experiments,
               :instruction_prompt,
               :text,
               null: false,
               default: ""

    change_column_default :experiments,
                          :instruction_prompt,
                          from: "",
                          to: nil
  end
end
