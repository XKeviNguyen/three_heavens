class ApplicationMailer < ActionMailer::Base
  default from: -> { ENV.fetch("MAIL_FROM", "no-reply@example.test") }
  layout "mailer"
end
