# MultiSub 隱私權政策

最後更新：2026 年 11 月 17 日

MultiSub 是 macOS 上的 Safari 延伸功能，在 Netflix 顯示雙語字幕。這份文件說明 MultiSub 會處理哪些資料、資料會送到哪裡。

## 一句話版本

MultiSub 沒有帳號、沒有分析工具、也沒有開發者自己的伺服器。開發者收不到你的任何資料。只有在你自己選擇「雲端 AI」並填入自己的 API Key 時，字幕文字才會從你的 Mac 直接送到你選的 AI 服務。

## 會處理的資料

**Netflix 字幕文字。** 延伸功能讀取你正在看的影片的字幕，用來顯示雙語字幕、標註生字。按「整理本集單字」時，也會把這一集的英文字幕交給 MultiSub App 整理成生詞本。字幕只在你的 Mac 上處理，下面「雲端 AI」的情況除外。

**設定與快取。** 字幕模式、語言、字幕樣式、翻譯結果的快取（會記下影集和集數名稱）和生詞本，都存在你的 Mac 上（Safari 延伸功能的儲存空間與 App 的共享資料夾）。按「整理本集單字」時，這一集的英文字幕會先暫存在共享資料夾，整理完就刪除。整理失敗的話會留著讓你按「重試」，按「移除」或超過一天後就會刪掉。

翻譯快取在 App 的「快取管理」刪除，生詞本在「生詞本」刪除，本機模型在「一般設定」刪除，API Key 在 AI 引擎設定按「移除」。macOS 刪除 App 時，不會一併清掉共享資料夾和鑰匙圈裡的 API Key，想完全清除，請先在 App 裡刪掉這些資料再刪除 App。

**API Key。** 如果你使用雲端 AI，API Key 在 MultiSub App 裡輸入，存在 macOS 鑰匙圈，只會附在送往你選的 AI 服務的請求裡。Netflix 網頁拿不到，也不會送到開發者手上。按「儲存並測試」後，測試成功才會存進鑰匙圈。（自行從原始碼建置、而且簽章時沒有鑰匙圈權限的版本，會改存在只有 MultiSub 能讀取的共享資料夾。App Store 版一律使用鑰匙圈。）

## 什麼時候會連上網路

| 情況 | 連到哪裡 | 送出的內容 |
|---|---|---|
| 「Netflix 雙語字幕」模式 | 只連到 Netflix，取得這一集的原文和第二語言字幕檔 | 不送出其他資料 |
| 在 App 展開「可下載的模型」、在 AI 引擎設定查看還沒下載的本機模型、下載本機模型 | Hugging Face（huggingface.co） | 查詢模型檔案大小、下載模型，不含字幕。已經下載好的模型直接從 Mac 載入，不會連線 |
| 使用雲端 AI（你自己選的） | 你選的服務：Anthropic、OpenAI、OpenRouter、Google Gemini，或你自己填的網址 | AI 翻譯和生字標註：這一集的原文字幕（從你正在看的地方開始，整集分批送出）、對應的 Netflix 官方字幕（有的話，用來統一人名和用詞）和目標語言。整理生詞本：這一集全部的英文字幕和目標語言。每次都會附上你的 API Key |
| 檢查更新（只有從 GitHub 下載的版本） | GitHub Releases 公開 API | 一般的 HTTP 請求 |

使用雲端 AI 時，字幕文字由你的 Mac 直接送到該服務，MultiSub 開發者不會經手。這些服務怎麼處理資料，依照各自的隱私權政策：

- Anthropic：https://www.anthropic.com/legal/privacy
- OpenAI：https://openai.com/policies/privacy-policy
- OpenRouter：https://openrouter.ai/privacy
- Google：https://policies.google.com/privacy

第一次用某個雲端服務按「儲存並測試」時，App 會寫明字幕會送到哪個服務（自訂網址就列出你填的網址），要你按下同意。自訂網址換成沒同意過的網址時，會再問一次。沒同意過的服務，MultiSub 不會送任何字幕過去。測試只送一句固定的英文例句，不含字幕。測試沒成功的話，設定和 Key 都不會存。

AI 引擎改用本機模型，就不會再送出任何字幕。只用「Netflix 雙語字幕」看片也不會送出字幕，但按「整理本集單字」時，字幕還是會交給你設定的 AI 引擎整理。

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

Last updated: November 17, 2026

MultiSub is a Safari extension for macOS that shows bilingual subtitles on Netflix.

**In short:** MultiSub has no accounts, no analytics and no developer-run servers. The developers never receive your data. Subtitle text leaves your Mac only if you choose a cloud AI engine and enter your own API key; it is then sent directly from your Mac to the provider you picked.

**Data processed on your Mac:** the subtitles of what you are watching (to display and annotate them), your settings, translation caches (which record show and episode titles) and vocabulary lists. When you click “Organize this episode's words” (整理本集單字), the episode's English subtitles are handed to the MultiSub app and staged in its shared folder until the word list is built. A failed run keeps them for Retry until you remove it, or for about a day. Delete caches in Cache Management (快取管理), word lists in Vocabulary (生詞本), on-device models in General Settings (一般設定) and API keys with Remove (移除) in the AI engine settings. Deleting the app does not remove its shared folder or its Keychain items, so delete them in the app first.

**API keys** are entered in the MultiSub app and stored in the macOS Keychain. A key is attached only to requests to the AI provider you chose; Netflix pages can't read it, and it is never sent to the developers. After Save and test (儲存並測試), it is stored only if the test succeeds. (A self-built copy signed without the keychain entitlement stores them in a file only MultiSub can read; the App Store version always uses the Keychain.)

**Network connections:**

- “Netflix bilingual subtitles” mode connects only to Netflix, to fetch the episode's original and second-language subtitle files, and sends nothing else.
- Expanding “Downloadable models” (可下載的模型) in the app, viewing an on-device model that isn't downloaded yet in the AI engine settings, or downloading a model contacts Hugging Face to check model sizes and download files (no subtitle data). A model that is already downloaded loads from your Mac without connecting.
- The optional cloud AI engine receives, for AI translation and Word Notes, the episode's subtitle lines (the whole episode in batches, starting where you are watching) with the matching official Netflix lines when there are any (as a terminology reference) and the target language; and, when you click “Organize this episode's words”, all of the episode's English subtitle lines with the target language. Every request carries your API key. Providers: Anthropic, OpenAI, OpenRouter, Google Gemini, or a custom endpoint you enter. Their own privacy policies apply.
- The first time you save a provider, the app names it (or shows the custom URL you entered) and asks you to agree. Changing a custom URL to one you haven't agreed to asks again. MultiSub sends no subtitle text to a provider you haven't agreed to. Testing a setup sends one fixed English sentence, not subtitles, and nothing is saved unless the test succeeds.
- With the on-device model as the AI engine, no subtitles are sent anywhere. Watching with Netflix bilingual subtitles sends none either, but “Organize this episode's words” still uses the AI engine you set up.
- The update check in the GitHub-distributed build contacts the public GitHub Releases API. The Mac App Store build has no update check.

**We don't** collect usage statistics, crash reports or tracking data; use advertising or analytics SDKs; sell or share your data; or download or store Netflix video.

**Contact:** https://github.com/snch1211/multisub/issues
