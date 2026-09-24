class LandingController < ApplicationController
  layout "public"
  skip_before_action :require_authentication

  def show
  end
end
