# User guide

A walkthrough of Three Heavens from sign-in to an approved translation. Screenshots use synthetic demo data; see [the README](../README.md) for how they are produced. The interface language can be switched between English, Vietnamese, and Japanese at the bottom of the sidebar.

## Key terms

| English | Tiếng Việt | 日本語 | Meaning |
| --- | --- | --- | --- |
| Translation | Lượt dịch | 翻訳 | One source text translated by several models |
| Translation candidates | Bản dịch ứng viên | 翻訳候補 | Each model's independent translation |
| Blind review | Nhận xét ẩn danh | ブラインドレビュー | Models score candidates without seeing who wrote them |
| Judging | Chấm điểm | 判定 | Models rank the candidates; the rankings choose a winner |
| AI suggestions | Đề xuất chỉnh sửa | 修正案 | Proposed improvements you may apply to your draft |
| Version | Phiên bản | 版 | A saved state of your final translation |
| Glossary | Bảng thuật ngữ | 用語集 | Terms that must always be translated the same way |
| Reference | Bản dịch tham khảo | 参考訳 | An approved example translation the AI should imitate |
| Workflow setup | Cấu hình quy trình | ワークフロー設定 | Saved models for an automatic run |
| Translation history | Lịch sử dịch | 翻訳履歴 | Every translation with its winner and cost |

## 1. Sign in

Create an account with your email and a password of at least 12 characters, then confirm your email from the message you receive. If the server has Google sign-in configured you can also continue with Google, or connect Google later under **Account**.

Translation itself needs a way to pay for AI work; see [AI settings and who pays](#ai-settings-and-who-pays). Without one you can still prepare documents, glossaries, references, methodologies, and workflow setups.

### Guided tours

The first time you sign in, a welcome window offers a seven-step tour of the product. **Take the tour** walks through the workspace, your translation library, workflow setups, AI settings, starting a translation, and how candidates become a final translation. **Not now**, **Skip**, or Escape closes it, and you are not asked again.

**Help** is the first button in the sidebar, above the navigation; on a phone it is in the top bar, next to the menu. It opens:

- **Product tour**, which replays the seven steps.
- **Guide to this page**, which explains the page you are on, such as New translation, References, Blind review, or the final editor. Steps for parts the page does not show (an empty list, a section you cannot use) are skipped.
- **Show page guides automatically**, a switch that shows **On** or **Off**.

**Page guides that open by themselves.** If you finish the welcome tour the first time it is offered, the switch is turned on: the first time you open a page that has a guide (Projects, Glossaries, References, a project's own page, and so on), its guide opens once. Finishing it, skipping it, pressing Escape, or leaving the page counts as seen, so it does not open again on that page; **Guide to this page** still replays it. If you chose **Not now** or skipped the welcome tour, guides stay off until you turn the switch on; turning it on also opens the guide of the page you are on, if you have not seen it yet (on a page you returned to with Back or Forward, it waits for the next page). Accounts that existed before page guides were added start with the switch off, and a later, updated welcome tour never changes the switch you already have. Your progress is saved to your account, so it follows you to other browsers and devices.

A guide never opens by itself over another window, while you are typing, after a form was sent back with errors, on a page you return to with Back or Forward, or on a page that is refreshing itself to show running AI work. If you change the switch and open another page right away, that page follows your new choice once it is saved; if saving fails, the switch shows its previous setting again.

Guides only highlight parts of the page. They never click, submit, upload, save a key, change a setting, or start AI work, and leaving the page ends them.

### AI settings and who pays

Open **AI settings** in the sidebar to choose who pays for new AI work:

- **Your own OpenRouter key.** Paste a key from your OpenRouter account and select it; your OpenRouter account is charged for your AI work. You do not need an administrator's permission. The key is stored encrypted; after you save it, only its last few characters are shown, and replacing or deleting it never moves your work to the platform.
- **Platform-managed AI.** Paid by the platform; available only after an administrator allows it for your account.

Each translation, review, judging, and suggestion run records who paid when it started. Changing the setting affects new work only. A failed run whose key was removed or replaced is never retried with the platform's key. Your browser or password manager may still offer to save the key field; the page asks them not to, but cannot force it.

## 2. Start a translation

![New translation form with English to Japanese, a pasted sermon, a glossary, and three selected models](images/readme/01-new-translation.png)

Open **New translation**:

1. **Languages.** Choose the source and target languages (or type a custom language). Use the ⇄ button to swap them.
2. **Project.** Name a new project, or start from an existing project's page to add a translation to it. A project keeps one language pair.
3. **Source document.** Give it a title, then **Paste text** or **Upload file** (TXT, Markdown, DOCX, or text PDF, up to 21 MiB). After an upload, review and edit the extracted text before you start. Uploading never sends anything to AI.
4. **Your instructions (optional).** Tone, audience, names to keep, formatting — every AI step follows them.

The form saves itself as you type. If you close the tab or your browser crashes, the draft is restored the next time you open the page. **Discard draft** clears it.

## 3. Add guidance (optional)

All four kinds of guidance are shown on the page, numbered in reading order; the page guide gives each its own step.

- **Terminology.** Choose a saved glossary, or add terms directly with **+ Add terminology**. A glossary is a list of source terms and the exact target terms to use (for example *Grace → 恵み*). Editing it saves a new version; translations that already used it keep their version.
- **References.** Pick up to five approved bilingual examples that show the wording and style you want. When you create a reference, paste each side or choose one TXT, Markdown, DOCX, or PDF file per side (up to 21 MiB; drop a file on the box or use **Choose file**). The chosen file's name and size are shown, and you can replace or remove it before saving; choosing a file never saves the form. Use pasted text or a file for each side, not both.
- **Methodology.** A reusable style guide describing how the translation should be written.
- **Guidance priority.** If the guidance disagrees, choose which source wins.

Manage these under **Glossaries**, **References**, and **Methodology** in the sidebar.

![Glossary page listing English terms and their preferred Japanese translations](images/readme/10-glossary.png)

## 4. Choose how AI works

In the **AI workflow** panel:

- **Manual** — choose 1–6 models. Each writes its own translation; you start every later step yourself. Blind review and judging need at least two completed translations.
- **Automatic** — choose a saved **workflow setup** (made under **Workflow setups** in the sidebar). It runs translation, blind review, and judging for you — and optionally AI suggestions — then stops so you can edit. Check **I approve the AI requests and limits shown** each time; the panel shows how many AI requests the run may send.

![Automatic mode with a saved workflow setup and the cost approval checkbox](images/readme/08-automatic-approval.png)

Click **Start translation**. Clicking twice, or retrying after a network error, never starts a second paid run.

## 5. Translation candidates

![Translation candidates page with each model's Japanese translation](images/readme/02-translation-candidates.png)

The page refreshes every 5 seconds while models are working. Each card shows the translation, the model you chose, the model actually used, and the cost when the AI service reports it. Token counts (how much text the AI processed) are under **Technical details**. If a model fails, **Retry failed translations** redoes only the failed work after a cost warning. A retry is new AI work: the panel says who will pay for it under your current AI settings: the platform, or your OpenRouter key with its last characters. If that changes before you click (for example in another tab, or by replacing the key), nothing is retried and the page shows the new payer first. Review, judging, and suggestion retries work the same way.

**Long documents run in parts.** A source longer than 4,000 characters is split into parts of about 4,000 characters at paragraph and sentence boundaries; a 29,000-character text becomes 8 parts. Every part of every model is sent at the same time, and each card shows **Processed in parts: 5 / 8 parts done**. The number counts finished parts only: a fast model climbs steadily, while a slower one (one that "thinks" before answering) can stay at 0 / 8 and then jump to 8 / 8, because its parts were running side by side all along. When all parts are done they are joined back in order. If one part fails, only that part is retried. Your glossary, methodology, and references are sent with every part.

![A long document translating in parts](images/readme/15-long-document-parts.png)

## 6. Blind review

Search the OpenRouter catalog for one or more reviewer models and click **Start blind review**. Reviewers do not have to be the models that translated; only models that can return structured answers are offered, and the server refuses any other. Reviewers see the candidates as *Candidate A, B, C…*; the app never tells them which model wrote which. Each review scores faithfulness, naturalness, terminology, and how well the instructions were followed, and lists strengths, issues, and suggested corrections. Only you see "Written by (hidden from AI)".

**Average scores.** The page opens with **Average review scores**: a gauge for the average of all candidates (1–10) and one tile per translation model, highest first, showing its average, how far it is above (▲) or below (▼) the average of all models, and a rating from *Poor* to *Excellent*. It appears as soon as the first reviewer finishes and says how many are done; replaced reviewers are not counted.

If a reviewer fails (for example, no OpenRouter provider can serve it with structured output), its card offers **Replace … with another model** until judging starts. Pick one model from the catalog; after a cost warning, only the new model reviews the same candidates and only its work is billed, under the payer shown. The failed run stays listed under the round with its own cost. Retrying it instead is still possible.

![Replacing a failed reviewer with another model](images/readme/16-replace-failed-reviewer.png)

![Blind review scores for two anonymous candidates](images/readme/03-blind-review.png)

## 7. Judging

Search the OpenRouter catalog for judge models and click **Start judging**. Each judge ranks every candidate; the rankings are combined into one **winning translation**. If any judge fails, no winner is chosen until you retry it or replace it with another model from its card (possible until the final editor is opened; only the new judge's work is billed). **Average judge scores** (1–100) are shown the same way as review scores. The winner is chosen by ranking points first, so it is not always the model with the highest average.

![Judging page with the winning translation and ranking points](images/readme/04-judging.png)

## 8. Edit the final translation

Click **Edit the winning translation**. The winner becomes **version 1** of your draft. The source, instructions, glossary, and the reasons the translation won stay beside the editor.

![Final translation workspace with the editable draft](images/readme/05-final-editor.png)

- **Save version** creates a new version when the text has changed (saving unchanged text keeps the current version); earlier versions are kept and can be viewed or **restored as a new version**.
- **Get AI suggestions** asks one or more models, picked from the OpenRouter catalog, to improve the current version. Each suggestion shows the proposed text, a change summary, and terminology notes. **Apply suggestion** turns it into a new version; nothing is ever applied automatically. A suggestion made for an older version is marked *Out of date*.
- If another tab saved a newer version, you are told before anything is overwritten, and your text stays in the editor so you can combine the changes.

![An AI suggestion ready to apply](images/readme/06-ai-suggestion.png)

## 9. Finalize and download

**Finalize current version** marks it as the approved translation and makes it read-only. **Download TXT** or **Download DOCX** at any time; until finalized, downloads are labeled as drafts. **Reopen for editing** if you need changes later — nothing is lost.

## 10. Automatic workflows

An automatic run has its own progress page with a timeline of each step. It ends at **Ready for you to edit**, with nothing applied or finalized. **Stop automation** prevents the remaining steps; requests already sent still finish, nothing is deleted, and you can continue by hand. **Technical details** on that page shows request counts, tokens, which costs were reported, and the exact models used.

![Automatic workflow page reading Ready for you to edit](images/readme/09-automatic-workflow.png)

## 11. History and benchmarks

**History** lists every translation with its candidates, winner, AI cost (marked partial when a step did not report cost), and links to each step. **Reuse these settings** starts a new translation with the same configuration. **Benchmarks** compares models across your translations: wins, win rate, review and judge scores, cost, and response time, each with its sample size.

![Translation history with two translations and their AI cost](images/readme/11-translation-history.png)

## For administrators

- **Admin → Users:** turn AI access on or off per account.
- **Admin → Models:** add models from the OpenRouter catalog (searching is free), set context-window and output limits needed for long documents, and deactivate models without losing history.
- **Admin → Operations:** aggregate health of the databases, storage, queues, and AI work, plus a button to mark stuck AI work as failed (no AI request is sent).
