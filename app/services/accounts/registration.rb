module Accounts
  # Registers an email-and-password account.
  #
  # An unconfirmed registration proves nothing about the mailbox, so it does
  # not hold the address: registering the same address again replaces its
  # password and confirmation time, which also invalidates the earlier link.
  # Confirming requires the password (EmailConfirmationsController), so the
  # account becomes usable only for someone who controls the mailbox and
  # chose the password. A confirmed or disabled account keeps the address.
  # Like a resend, a replacement waits User::CONFIRMATION_EMAIL_INTERVAL after
  # the previous email, so registering again cannot flood the mailbox; one
  # made sooner changes nothing and answers like any other registration.
  class Registration
    attr_reader :user

    def initialize(email:, password:, password_confirmation:, locale:)
      @attributes = { password:, password_confirmation:, locale:, confirmation_sent_at: Time.current }
      @user = User.new(email:, role: :user, status: :active, managed_ai_access: false, **@attributes)
      @confirmation_due = true
    end

    def confirmation_due? = @confirmation_due

    def save
      pending = User.active.find_by(email: user.email, email_verified_at: nil)
      return replace(pending) if pending

      user.save
    rescue ActiveRecord::RecordNotUnique
      # A registration that commits between this one's uniqueness validation
      # and its insert is caught by the unique email index; the loser gets the
      # same answer as any duplicate address and no email is sent.
      user.errors.add(:email, :taken)
      false
    end

    private

    def replace(pending)
      pending.with_lock do
        if pending.active? && !pending.email_verified?
          emailed_recently = pending.confirmation_sent_at&.after?(User::CONFIRMATION_EMAIL_INTERVAL.ago)
          pending.assign_attributes(@attributes)
          unless pending.valid?
            # The form re-renders for a new registration, not this record.
            pending.errors.each { |error| user.errors.import(error) }
            next false
          end
          if emailed_recently
            @confirmation_due = false
            next true
          end

          pending.save!
          @user = pending
          true
        else
          user.errors.add(:email, :taken)
          false
        end
      end
    end
  end
end
