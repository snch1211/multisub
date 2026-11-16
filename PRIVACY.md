# MultiSub 隱私權政策

最後更新：2026 年 11 月 16 日

MultiSub 是 macOS 上的 Safari 延伸功能，在 Netflix 顯示雙語字幕。這份文件說明 MultiSub 會處理哪些資料、資料會送到哪裡。

## 一句話版本

MultiSub 沒有帳號、沒有分析工具、也沒有開發者自己的伺服器。開發者收不到你的任何資料。只有在你自己選擇「雲端 AI」並填入自己的 API Key 時，字幕文字才會從你的 Mac 直接送到你選的 AI 服務。

## 會處理的資料

**Netflix 字幕文字。** 延伸功能讀取你正在看的影片的字幕，用來顯示雙語字幕、標註生字。字幕只在你的 Mac 上處理，下面「雲端 AI」的情況除外。

**設定與快取。** 字幕模式、語言、字幕樣式、翻譯結果的快取和生詞本，都存在你的 Mac 上（Safari 延伸功能的儲存空間與 App 的共享資料夾）。可以在 App 的「快取管理」「生詞本」刪除，刪除 App 也會一併移除。

**API Key。** 如果你使用雲端 AI，API Key 存在 macOS 鑰匙圈，只在你的 Mac 上使用，也不會送到開發者手上。在 Safari 工具列選單貼上的 Key，會經過延伸功能交給 MultiSub 的原生程式。測試設定、載入模型清單時只用那一次，測試成功、設定存下來時才存進鑰匙圈，之後不會再傳回延伸功能。（自行從原始碼建置、而且簽章時沒有鑰匙圈權限的版本，會改存在只有 MultiSub 能讀取的共享資料夾。App Store 版一律使用鑰匙圈。）

## 什麼時候會連上網路

| 情況 | 連到哪裡 | 送出的內容 |
|---|---|---|
| 「Netflix 雙語字幕」模式 | 不會額外連線（字幕本來就由 Netflix 提供） | 無 |
| 在 App 展開「可下載的模型」、在 AI 引擎設定查看還沒下載的本機模型、下載本機模型 | Hugging Face（huggingface.co） | 查詢模型檔案大小、下載模型，不含字幕 |
| 使用雲端 AI（你自己選的） | 你選的服務：Anthropic、OpenAI、OpenRouter、Google Gemini，或你自己填的網址 | 要翻譯、標註或整理成生詞本的字幕文字、同一段的 Netflix 官方字幕（作為用詞參考）、目標語言，以及你的 API Key |
| 檢查更新（只有從 GitHub 下載的版本） | GitHub Releases 公開 API | 一般的 HTTP 請求 |

使用雲端 AI 時，字幕文字由你的 Mac 直接送到該服務，MultiSub 開發者不會經手。這些服務怎麼處理資料，依照各自的隱私權政策：

- Anthropic：https://www.anthropic.com/legal/privacy
- OpenAI：https://openai.com/policies/privacy-policy
- OpenRouter：https://openrouter.ai/privacy
- Google：https://policies.google.com/privacy

第一次用某個雲端服務按「儲存並測試」時，App 和 Safari 工具列選單都會寫明字幕會送到哪個服務（自訂網址就列出你填的網址），要你按下同意。沒同意過的服務，MultiSub 不會送任何字幕過去。測試只送一句固定的英文例句，不含字幕。測試沒成功的話，設定和 Key 都不會存。改用「本機模型」或「Netflix 雙語字幕」模式，就不會再送出任何字幕。

## 不會做的事

- 不收集使用統計、當機報告或任何追蹤資料
- 不使用廣告或第三方分析 SDK
- 不出售、分享或轉交你的資料
- 不下載或儲存 Netflix 的影片

## 兒童

MultiSub 不針對兒童設計，也不會刻意收集任何人的個人資料。

## 聯絡

有任何問題，請到 GitHub 開 issue：https://github.com/snch1211/multisub/issues

---

# MultiSub Privacy Policy

Last updated: November 16, 2026

MultiSub is a Safari extension for macOS that shows bilingual subtitles on Netflix.

**In short:** MultiSub has no accounts, no analytics and no developer-run servers. The developers never receive your data. Subtitle text leaves your Mac only if you choose a cloud AI engine and enter your own API key; it is then sent directly from your Mac to the provider you picked.

**Data processed on your Mac:** the subtitles of what you are watching (to display and annotate them), your settings, translation caches and vocabulary lists (deletable in the app). API keys are stored in the macOS Keychain and never sent to the developers. A key pasted into the toolbar popup passes through the extension to MultiSub's native code. Testing a setup or loading the model list uses it for that one request only; it is stored in the Keychain only when a setup that passed its test is saved, and it is never handed back to the extension. (A self-built copy signed without the keychain entitlement stores them in a file only MultiSub can read; the App Store version always uses the Keychain.)

**Network connections:**

- "Netflix bilingual subtitles" mode makes no extra connections.
- Expanding “Downloadable models” (可下載的模型) in the app, viewing an on-device model that isn't downloaded yet in the AI engine settings, or downloading a model contacts Hugging Face to check model sizes and download files (no subtitle data).
- The optional cloud AI engine sends the subtitle lines being translated, annotated or organized into a vocabulary list, the matching official Netflix subtitle lines (as a terminology reference), the target language and your API key to the provider you selected (Anthropic, OpenAI, OpenRouter, Google Gemini, or a custom endpoint you enter). Their own privacy policies apply. The first time you save a provider, the app or the toolbar popup names it (or shows the custom URL you entered) and asks you to agree; MultiSub sends no subtitle text to a provider you haven't agreed to. Testing a setup sends one fixed English sentence, not subtitles, and nothing is saved unless the test succeeds.
- The update check in the GitHub-distributed build contacts the public GitHub Releases API. The Mac App Store build has no update check.

**We don't** collect usage statistics, crash reports or tracking data; use advertising or analytics SDKs; sell or share your data; or download or store Netflix video.

**Contact:** https://github.com/snch1211/multisub/issues
