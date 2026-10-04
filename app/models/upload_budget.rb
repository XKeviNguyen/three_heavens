class UploadBudget < ApplicationRecord
  belongs_to :user

  Receipt = Data.define(:user_id, :window_id, :token)

  # One bounded row per account, shared by both upload entry points. PostgreSQL
  # supplies the clock and serializes even the first insert. Each admitted
  # request owns a receipt, so a refund can only remove its own charge once.
  def self.consume(user:)
    token = SecureRandom.uuid
    row = connection.exec_query(sanitize_sql_array([ <<~SQL, user.id, token ])).first
      INSERT INTO upload_budgets (user_id, window_id, count, receipts)
      VALUES (?, #{current_window_sql}, 1, ARRAY[?]::uuid[])
      ON CONFLICT (user_id) DO UPDATE
      SET window_id = EXCLUDED.window_id,
          count = CASE WHEN upload_budgets.window_id < EXCLUDED.window_id
                       THEN 1 ELSE upload_budgets.count + 1 END,
          receipts = CASE WHEN upload_budgets.window_id < EXCLUDED.window_id
                          THEN EXCLUDED.receipts ELSE upload_budgets.receipts || EXCLUDED.receipts END
      WHERE upload_budgets.window_id < EXCLUDED.window_id
         OR (upload_budgets.window_id = EXCLUDED.window_id AND upload_budgets.count < #{SourceImports::Limits::UPLOADS_PER_WINDOW})
      RETURNING window_id
    SQL
    Receipt.new(user_id: user.id, window_id: row.fetch("window_id"), token:) if row
  end

  def self.refund(receipt)
    return false unless receipt

    connection.update(sanitize_sql_array([ <<~SQL, receipt.token, receipt.user_id, receipt.window_id, receipt.token ])) == 1
      UPDATE upload_budgets
      SET count = count - 1, receipts = array_remove(receipts, ?::uuid)
      WHERE user_id = ? AND window_id = ? AND window_id = #{current_window_sql}
        AND count > 0 AND ?::uuid = ANY(receipts)
    SQL
  end

  def self.current_window_sql
    "floor(extract(epoch FROM statement_timestamp()) / #{SourceImports::Limits::UPLOAD_WINDOW.to_i})::bigint"
  end
  private_class_method :current_window_sql
end
