# Captures the README product-tour screenshots from the real application.
#
# Run it with bin/capture-readme-screenshots, never as part of the normal
# suite. It is a browser test so it inherits the suite's safety rails: the test
# database, Active Job's test adapter, the loopback-only network guard, and a
# browser that cannot reach Google. Every AI response comes from DemoClient
# below, so no provider request is made and nothing here costs money.
#
# All names, texts, scores, token counts, and costs are synthetic demo values.
require_relative "../../test/application_system_test_case"

class ReadmeScreenshotsTest < ApplicationSystemTestCase
  include ActiveJob::TestHelper

  driven_by :selenium, using: :headless_chrome, screen_size: [ 1440, 1000 ] do |options|
    options.add_argument("--no-sandbox")
    options.add_argument("--disable-dev-shm-usage")
    options.add_argument("--hide-scrollbars")
    options.binary = ENV["CHROME_BIN"].presence ||
      Selenium::WebDriver::SeleniumManager.binary_paths("--browser", options.browser_name).fetch("browser_path")
  end

  OUTPUT_DIRECTORY = Pathname(ENV.fetch("README_SCREENSHOT_DIR", Rails.root.join("docs/images/readme").to_s))
  PASSWORD = "synthetic demo password 2026"
  # Segment jobs only run for long documents, but they get the demo client too
  # so a longer demo text can never fall through to the real provider client.
  AI_JOBS = [
    TranslationRunJob, ReviewRunJob, JudgeRunJob, FinalizationRunJob,
    TranslationSegmentRunJob, ReviewSegmentRunJob, JudgeSegmentRunJob, FinalizationSegmentRunJob
  ].freeze

  SERMON_SOURCE = <<~TEXT.strip
    Grace is not a reward for the strong. It is a gift for the weary.

    When we come to the end of our own strength, we discover that salvation was never our achievement. It was always God's gift, offered freely.

    So this week, rest in that grace. Let faith be less about holding on, and more about being held.
  TEXT

  ADVENT_SOURCE = <<~TEXT.strip
    Hope is not the absence of waiting. It is waiting with open hands.

    Advent reminds us that God keeps His promises, even when they arrive slowly.
  TEXT

  # Demo translations keyed by source passage and translator model.
  TRANSLATIONS = {
    sermon: {
      "demo/lumen" => <<~TEXT.strip,
        恵みは、強い人へのごほうびではありません。疲れた人への贈り物です。

        自分の力が尽きたとき、私たちは気づきます。救いは一度も自分の功績ではなかったのだと。それはいつも、惜しみなく差し出された神からの贈り物でした。

        ですから今週は、その恵みの中で休んでください。信仰とは、しがみつくことよりも、抱きとめられることなのです。
      TEXT
      "demo/meridian" => <<~TEXT.strip,
        恩恵は強い者への報酬ではありません。それは疲れた者への賜物です。

        私たちが自分自身の力の終わりに来るとき、救いは決して私たちの達成ではなかったことを発見します。それは常に神の賜物であり、無償で提供されていました。

        ですから今週、その恵みの中で休息してください。信仰を、しがみつくことについてではなく、抱かれることについてのものにしてください。
      TEXT
      "demo/quill" => <<~TEXT.strip
        恵みは強い者へのご褒美ではない。疲れ果てた者への贈り物だ。

        自分の力が尽きたとき、私たちは知る。救いは自分で勝ち取ったものではなかった。最初から、神が惜しみなく与えてくださった贈り物だったのだ。

        だから今週は、その恵みに身をゆだねよう。信仰とは、しがみつくことではなく、抱きとめられることなのだから。
      TEXT
    },
    advent: {
      "demo/lumen" => <<~TEXT.strip,
        希望とは、待つことがなくなることではありません。手を開いて待つことです。

        待降節は、神が約束を守られる方であることを思い出させてくれます。たとえその約束が、ゆっくりと届くとしても。
      TEXT
      "demo/quill" => <<~TEXT.strip
        希望とは待たずに済むことではない。両手を開いて待つことだ。

        待降節は思い出させてくれる。神は約束を守る方だと。たとえそれがゆっくり届くとしても。
      TEXT
    }
  }.freeze

  REFINEMENTS = {
    sermon: <<~TEXT.strip,
      恵みは、強い人へのごほうびではありません。疲れた人への贈り物です。

      自分の力が尽きたとき、私たちは気づきます。救いは、自分の力で得たものではありませんでした。いつも、神が惜しみなく与えてくださった贈り物だったのです。

      ですから今週は、その恵みの中で休んでください。信仰とは、しがみつくことではなく、支えられることなのです。
    TEXT
    advent: <<~TEXT.strip
      希望とは、待つ必要がなくなることではありません。手を開いて待つことです。

      待降節は、神が約束を必ず守られる方だと思い出させてくれます。たとえその約束が、ゆっくりと届くとしても。
    TEXT
  }.freeze

  # Reviewer feedback for each demo translator: scores, then strengths, issues, corrections.
  FEEDBACK = {
    "demo/lumen" => [ [ 9, 9, 10, 9, 9 ],
                      "Warm です/ます register that reads well aloud. 恵み, 救い, and 信仰 match the glossary exactly.",
                      "「抱きとめられる」 is beautiful but slightly literary for a spoken sermon.",
                      "Consider 「支えられる」 if the congregation includes many children." ],
    "demo/quill" => [ [ 8, 9, 10, 5, 7 ],
                      "Vivid and natural. Every glossary term is used correctly.",
                      "Uses plain だ/である endings although the instructions ask for です/ます.",
                      "Convert the sentence endings to です/ます for a Sunday congregation." ],
    "demo/meridian" => [ [ 8, 5, 6, 8, 6 ],
                         "Follows the English closely; nothing is left out.",
                         "Opens with 恩恵 instead of the required 恵み, and 「力の終わりに来る」 reads as translated rather than spoken.",
                         "Replace 恩恵 with 恵み and split the second paragraph into shorter sentences." ]
  }.freeze

  JUDGE_ORDER = %w[demo/lumen demo/quill demo/meridian].freeze

  # Deterministic stand-in for Ai::OpenRouterClient at the provider boundary.
  class DemoClient
    # Per-model usage so the candidate cards do not all show the same numbers.
    TRANSLATION_USAGE = {
      "demo/lumen" => [ 612, 318, "0.0021" ],
      "demo/meridian" => [ 598, 352, "0.0012" ],
      "demo/quill" => [ 605, 301, "0.0035" ]
    }.freeze

    def chat_completion(model_identifier:, source_text:, **)
      prompt_tokens, completion_tokens, cost = TRANSLATION_USAGE.fetch(model_identifier)
      result(TRANSLATIONS.fetch(passage(source_text)).fetch(model_identifier), prompt_tokens:, completion_tokens:, cost:)
    end

    def review_completion(model_identifier:, **prompt)
      second_reviewer = model_identifier == "demo/sage"
      evaluations = candidates(prompt).map do |label, translator|
        scores, strengths, issues, corrections = FEEDBACK.fetch(translator)
        scores = scores.map { |score| second_reviewer ? [ score - 1, 1 ].max : score }
        {
          candidate_label: label,
          faithfulness_score: scores[0],
          naturalness_score: scores[1],
          terminology_score: scores[2],
          instruction_adherence_score: scores[3],
          overall_score: scores[4],
          strengths: strengths,
          issues: issues,
          recommended_corrections: corrections,
          suggested_translation: nil
        }
      end
      result(JSON.generate(evaluations: evaluations), prompt_tokens: 1_480, completion_tokens: 540, cost: "0.0046")
    end

    def judge_completion(model_identifier:, **prompt)
      ranked = candidates(prompt).sort_by { |_label, translator| JUDGE_ORDER.index(translator) }
      rankings = ranked.each_with_index.map do |(label, translator), index|
        {
          candidate_label: label,
          rank: index + 1,
          overall_score: [ 92, 81, 64 ].fetch(index) - (model_identifier == "demo/verdict" ? 2 : 0),
          rationale: JUDGE_RATIONALES.fetch(translator),
          strengths: FEEDBACK.fetch(translator)[1],
          risks: FEEDBACK.fetch(translator)[2]
        }
      end
      result(JSON.generate(
        rankings: rankings,
        winner_label: ranked.first.first,
        winner_rationale: "Faithful to the source, follows the glossary and the です/ます instruction, and is the easiest to read aloud.",
        confidence_score: model_identifier == "demo/verdict" ? 82 : 86
      ), prompt_tokens: 2_210, completion_tokens: 470, cost: "0.0058")
    end

    def finalization_completion(**prompt)
      result(JSON.generate(
        proposed_translation: REFINEMENTS.fetch(passage(prompt.values.grep(String).join("\n"))),
        change_summary: [ "Simplified the second paragraph so it is easier to read aloud.", "Replaced 抱きとめられる with the simpler 支えられる." ],
        terminology_notes: [ "Kept 恵み, 救い, and 信仰 exactly as the glossary requires." ],
        warnings: []
      ), prompt_tokens: 1_350, completion_tokens: 360, cost: "0.0034")
    end

    JUDGE_RATIONALES = {
      "demo/lumen" => "Most faithful and natural; the only candidate that satisfies every instruction.",
      "demo/quill" => "Natural and accurate, but the plain だ/である style ignores the requested register.",
      "demo/meridian" => "Complete but stiff, and it breaks the glossary by using 恩恵."
    }.freeze

    private

    def passage(text)
      text.include?("Hope is not the absence of waiting") ? :advent : :sermon
    end

    # Maps each anonymous label back to the demo translator whose text it carries.
    def candidates(prompt)
      text = prompt.values.grep(String).join("\n")
      data = JSON.parse(text[text.index("{")..text.rindex("}")])
      data.fetch("candidates").to_h do |candidate|
        translator = TRANSLATIONS.values.flat_map(&:to_a).find { |_model, body| body == candidate.fetch("translation") }&.first
        [ candidate.fetch("candidate_label"), translator || "demo/meridian" ]
      end
    end

    def result(content, prompt_tokens:, completion_tokens:, cost:)
      Ai::OpenRouterClient::Result.new(
        content: content,
        provider_response_id: "demo-#{SecureRandom.hex(4)}",
        resolved_model_identifier: nil,
        prompt_tokens: prompt_tokens,
        completion_tokens: completion_tokens,
        total_tokens: prompt_tokens + completion_tokens,
        cached_tokens: 0,
        reasoning_tokens: 0,
        cost: BigDecimal(cost)
      )
    end
  end

  DEMO_MODELS = {
    "demo/lumen" => "Lumen (demo)",
    "demo/meridian" => "Meridian (demo)",
    "demo/quill" => "Quill (demo)",
    "demo/critic" => "Critic (demo)",
    "demo/sage" => "Sage (demo)",
    "demo/arbiter" => "Arbiter (demo)",
    "demo/verdict" => "Verdict (demo)",
    "demo/polish" => "Polish (demo)"
  }.freeze

  setup do
    FileUtils.mkdir_p(OUTPUT_DIRECTORY)
    OpenRouter::Catalog.transport = -> { demo_catalog_json }
    @original_client_factories = AI_JOBS.to_h { |job| [ job, job.client_factory ] }
    client = DemoClient.new
    AI_JOBS.each { |job| job.client_factory = -> { client } }

    LlmModel.update_all(active: false)
    @models = DEMO_MODELS.to_h do |identifier, name|
      model = LlmModel.create!(
        gateway: "openrouter",
        provider: "demo",
        model_identifier: identifier,
        display_name: name,
        active: true,
        context_window_tokens: 128_000,
        max_output_tokens: 16_384
      )
      [ identifier, model ]
    end
    @user = User.create!(
      email: "translator@example.test",
      password: PASSWORD,
      password_confirmation: PASSWORD,
      role: :user,
      status: :active,
      email_verified_at: Time.current,
      managed_ai_access: true
    )
    @glossary = Glossaries::Create.call(
      user: @user,
      attributes: {
        name: "Japanese Sermon Terms",
        description: "Preferred theological vocabulary for the Sunday congregation.",
        source_language: "English",
        target_language: "Japanese",
        entries: [
          { source_term: "Grace", preferred_target_term: "恵み", note: "Never 恩恵." },
          { source_term: "Salvation", preferred_target_term: "救い", note: "" },
          { source_term: "Faith", preferred_target_term: "信仰", note: "" },
          { source_term: "Hope", preferred_target_term: "希望", note: "" },
          { source_term: "Advent", preferred_target_term: "待降節", note: "Protestant usage." },
          { source_term: "God", preferred_target_term: "神", note: "Use 神様 only in children's material." }
        ]
      }
    )
  end

  teardown do
    @original_client_factories&.each { |job, factory| job.client_factory = factory }
  end

  test "captures the README product tour" do
    sign_in

    # 1. A new translation: pasted source, languages, glossary, and three independent models.
    visit new_translation_workspace_path
    fill_in "Project name", with: "Japanese Sermon Translation"
    choose_known_language "Source language", "English"
    choose_known_language "Target language", "Japanese"
    fill_in "Document title", with: "Grace for the Weary"
    fill_in "Source text", with: SERMON_SOURCE
    fill_in "Translation name", with: "Sunday sermon · first draft"
    fill_in "Instructions for the translation", with: "Warm, reverent tone for a Sunday congregation. Use です/ます style and keep sentences short enough to read aloud."
    find("#workspace-glossary summary", text: "Choose saved glossary").click
    find("input[name='translation_workspace[glossary_revision_id]'][value='#{@glossary.current_revision_id}']", visible: :all).choose
    within "#workspace-manual-models" do
      find("input[placeholder='Search OpenRouter models…']").click
      %w[Lumen Meridian Quill].each do |name|
        find("div[role='option']", text: "#{name} (demo)", match: :first).find("button", text: "Add").click
      end
      assert_text "3 models selected"
    end
    assert_no_text "Saving…" # autosave finished
    capture "01-new-translation"

    click_button "Start translation"
    assert_text "Translation started."
    run_ai_jobs
    experiment = Experiment.order(:id).last
    visit experiment_path(experiment)
    assert_text "Lumen (demo)"
    capture "02-translation-candidates", find("h2", text: "Results by model")

    # 2. Blind review by two reviewer models that never see model names.
    check "review_round_reviewer_ids_#{@models.fetch("demo/critic").id}"
    check "review_round_reviewer_ids_#{@models.fetch("demo/sage").id}"
    accept_confirm { click_button "Start blind review" }
    assert_text "Blind review started."
    run_ai_jobs
    visit review_round_path(experiment.reload.review_round)
    capture "03-blind-review"

    # 3. Two independent judges rank the anonymous candidates.
    check "judge_round_judge_ids_#{@models.fetch("demo/arbiter").id}"
    check "judge_round_judge_ids_#{@models.fetch("demo/verdict").id}"
    accept_confirm { click_button "Start judging" }
    assert_text "Judging started."
    run_ai_jobs
    judge_round = experiment.review_round.reload.judge_round
    visit judge_round_path(judge_round)
    assert_button "Edit the winning translation"
    capture "04-judging"

    # 4. The human editor starts from the winner and asks for AI suggestions.
    click_button "Edit the winning translation"
    assert_text "Your final translation draft is ready."
    check "refinement_finalizer_ids_#{@models.fetch("demo/polish").id}"
    accept_confirm { click_button "Get AI suggestions" }
    assert_text "AI suggestions requested."
    run_ai_jobs
    final_translation = judge_round.reload.final_translation
    visit final_translation_path(final_translation)
    assert_text "Ready to apply"
    capture "05-final-editor"
    capture "06-ai-suggestion", find(:xpath, "//*[normalize-space(text())='Suggestions for version 1']")

    # 5. An automatic workflow runs the same steps and stops for the editor.
    profile = WorkflowProfiles::Create.call(
      user: @user,
      attributes: {
        name: "Sunday sermon workflow",
        description: "Two translators, blind review, one judge, then AI suggestions for the editor.",
        completion_mode: "refinement_proposals",
        translator_ids: [ @models.fetch("demo/lumen").id, @models.fetch("demo/quill").id ],
        reviewer_ids: [ @models.fetch("demo/critic").id ],
        judge_ids: [ @models.fetch("demo/arbiter").id ],
        finalizer_ids: [ @models.fetch("demo/polish").id ]
      }
    )
    visit workflow_profile_path(profile)
    capture "07-workflow-setup"

    visit project_path(experiment.document.project)
    click_link "Paste text / start translation", match: :first
    fill_in "Document title", with: "Waiting with Open Hands"
    fill_in "Source text", with: ADVENT_SOURCE
    fill_in "Translation name", with: "Advent devotional"
    fill_in "Instructions for the translation", with: "Gentle devotional tone. Use です/ます style."
    find("#workspace-glossary summary", text: "Choose saved glossary").click
    find("input[name='translation_workspace[glossary_revision_id]'][value='#{@glossary.current_revision_id}']", visible: :all).choose
    choose "Automatic"
    choose "translation_workspace_workflow_profile_revision_id_#{profile.current_revision_id}"
    check "translation_workspace_automatic_confirmation"
    assert_no_text "Saving…"
    capture "08-automatic-approval", find("h2", text: "Your instructions")
    click_button "Start translation"
    assert_text "Automatic workflow started."
    run_ai_jobs
    pipeline = PipelineRun.order(:id).last
    assert pipeline.reload.ready_for_editor?, "demo pipeline stopped at #{pipeline.status}/#{pipeline.current_stage}"
    visit pipeline_run_path(pipeline)
    capture "09-automatic-workflow"

    # 6. Library and history pages.
    visit glossary_path(@glossary)
    capture "10-glossary"
    visit history_path
    capture "11-translation-history"

    # 7. The same editor on a phone, and the Japanese interface.
    with_viewport(390, 844) do
      visit final_translation_path(final_translation)
      capture "12-mobile-final-editor"
    end
    @user.update!(locale: "ja")
    visit judge_round_path(judge_round)
    capture "13-japanese-judging"
  end

  private

  def sign_in
    use_viewport(1440, 1000)
    visit login_path
    fill_in "Email", with: @user.email
    fill_in "Password", with: PASSWORD
    click_button "Sign in"
    assert_text "Signed in successfully."
  end

  # Runs the real jobs the browser enqueued, including the automatic workflow's
  # follow-up stages, until nothing is left. Only DemoClient answers.
  def run_ai_jobs
    20.times do
      break if enqueued_jobs.empty?

      perform_enqueued_jobs
    end
    assert_empty enqueued_jobs, "demo jobs did not settle"
  end

  # Saves the visible viewport, scrolled to the top of the page or to target.
  def capture(name, target = nil)
    if target
      page.execute_script("arguments[0].scrollIntoView({ block: 'start' }); window.scrollBy(0, -24)", target)
    else
      page.execute_script("window.scrollTo(0, 0)")
    end
    page.execute_script("document.activeElement && document.activeElement.blur()")
    sleep 0.3 # let smooth scrolling and fonts settle before the pixels are read
    png = page.driver.browser.execute_cdp("Page.captureScreenshot", format: "png").fetch("data")
    File.binwrite(OUTPUT_DIRECTORY.join("#{name}.png"), Base64.decode64(png))
  end

  # Pins the page viewport (not the window) so every desktop image is exactly
  # the same size.
  def use_viewport(width, height, scale: 1, mobile: false)
    page.driver.browser.execute_cdp("Emulation.setDeviceMetricsOverride", width:, height:, deviceScaleFactor: scale, mobile:)
  end

  def with_viewport(width, height)
    use_viewport(width, height, scale: 2, mobile: true)
    yield
  ensure
    use_viewport(1440, 1000)
  end

  def demo_catalog_json
    JSON.generate("data" => DEMO_MODELS.map do |identifier, name|
      {
        "id" => identifier,
        "name" => name,
        "context_length" => 128_000,
        "architecture" => { "input_modalities" => [ "text" ], "output_modalities" => [ "text" ] },
        "top_provider" => { "max_completion_tokens" => 16_384 },
        "pricing" => { "prompt" => "0.000001", "completion" => "0.000003" },
        "supported_parameters" => %w[max_tokens response_format structured_outputs]
      }
    end)
  end
end
