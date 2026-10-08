module UploadBudgetClock
  # Freeze only PostgreSQL's window expression; all statements, connections,
  # locks and commits remain real. A wall-clock boundary must not turn a
  # same-window concurrency assertion into a legitimate rollover.
  def run
    with_upload_budget_window(1_000_000) { super }
  end

  def with_upload_budget_window(window_id)
    original = UploadBudget.method(:current_window_sql)
    UploadBudget.define_singleton_method(:current_window_sql) { "#{window_id}::bigint" }
    yield
  ensure
    UploadBudget.singleton_class.define_method(:current_window_sql, original.unbind)
    UploadBudget.singleton_class.send(:private, :current_window_sql)
  end
end
