module Ai
  # The payment identity AI work was authorized under (see Ai::BillingPolicy).
  # The database enforces the same shape with a check constraint.
  module BillingIdentity
    extend ActiveSupport::Concern

    included do
      # The run tables have no database default, so code that predates this
      # column cannot create runs (see 20261010090100); this code always
      # names a payer, which scheduling then stamps from the authorization.
      attribute :billing_source, :string, default: "managed"

      # The foreign key guarantees existence; validating the id avoids a query
      # on every run update.
      belongs_to :open_router_credential, optional: true

      validates :billing_source, inclusion: { in: User::AI_PAYMENT_SOURCES }
      validates :open_router_credential_id, presence: true, if: -> { billing_source == "personal" }
      validates :open_router_credential_id, absence: true, unless: -> { billing_source == "personal" }
    end
  end
end
