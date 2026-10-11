module AiBillingHelper
  # Who would pay for an explicit retry clicked now: the same authorization
  # Ai::BillingPolicy.authorize_confirmed! checks and the retry stamps.
  # A Denied explains why no retry can start.
  def retry_payer_label(payer)
    return t("ai_billing.retry_payer.managed") unless payer.personal?

    hint = OpenRouterCredential.where(id: payer.open_router_credential_id).pick(:key_hint)
    t("ai_billing.retry_payer.personal", hint: hint)
  end

  def retry_payer
    return @retry_payer if defined?(@retry_payer)

    @retry_payer = Ai::BillingPolicy.authorize!(current_user)
  rescue Ai::BillingPolicy::Denied => denial
    @retry_payer = denial
  end
end
