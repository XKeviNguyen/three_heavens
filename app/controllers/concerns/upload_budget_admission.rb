module UploadBudgetAdmission
  private

  def admit_upload
    @upload_budget_receipt = UploadBudget.consume(user: current_user)
    render_rate_limited unless @upload_budget_receipt
  end

  def refund_upload_budget
    UploadBudget.refund(@upload_budget_receipt)
  end
end
