module MethodologyProfileTestHelper
  def methodology_profile_attributes(
    name: "Faithful literary methodology",
    source_language: "Vietnamese",
    target_language: "Japanese",
    guidance: "Preserve theological nuance.\n\nUse a natural literary register."
  )
    {
      name: name,
      description: "Reusable translation method",
      source_language: source_language,
      target_language: target_language,
      guidance: guidance
    }
  end

  def create_methodology_profile(user: users(:normal), **attributes)
    MethodologyProfiles::Create.call(
      user: user,
      attributes: methodology_profile_attributes(**attributes)
    )
  end
end
