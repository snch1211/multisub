# MultiSub

**MultiSub** 是一個 macOS Safari 擴充功能，為 Netflix 加上**雙語字幕**：擷取 Netflix 原生字幕，用**完全在本機執行**的 Gemma 模型（透過 [MLX](https://github.com/ml-explore/mlx-swift)）翻譯成你設定的語言，並以可調整大小／位置的第二字幕疊加顯示。翻譯不經任何雲端 API。

> MultiSub 是非官方的社群專案，**與 Netflix 無任何關聯，未經其背書或贊助**（not affiliated with, endorsed, or sponsored by Netflix）。

---

## 功能特色

- **雙語字幕**：原文字幕 + 本機翻譯的第二字幕同時顯示
- **完全本地推論**：翻譯在你的 Apple Silicon 上用 MLX 執行，字幕與觀看內容不外傳
- **可自訂顯示**：字級、垂直位置、顏色、外框、字型、行高等皆可在 App 內調整
- **生詞本**：把整集字幕中的單字依 CEFR 等級整理成可複習的生詞表
- **快取管理**：翻譯結果依劇集分組快取，換集不必重譯

## 系統需求

- **Apple Silicon** Mac（M 系列）
- **macOS 15** 或以上
- 建議 **16GB** 以上記憶體
- 模型檔約 **5GB** 磁碟空間（首次於 App 內下載）

## 下載安裝

到 [Releases](https://github.com/snch1211/multisub/releases) 下載最新版 `MultiSub-<版本>.dmg`，開啟後把 **MultiSub** 拖進 **Applications**。

### 首次開啟（Gatekeeper）

本 App 以免費的 Apple 個人開發者憑證簽署、**未經 Apple 公證**，所以在別台 Mac 上等同「未簽署」，首次開啟時 macOS 會擋下。請擇一：

- 在 **Applications** 對 MultiSub 圖示按 **右鍵 → 打開**，於對話框再按一次「打開」；或
- 開一次被擋後，到 **系統設定 → 隱私權與安全性**，找到「已封鎖 MultiSub」的訊息，按 **「仍要打開」**。

只需這樣做一次。之後啟用 Safari 擴充功能：**Safari → 設定 → 擴充功能** 勾選 MultiSub，並允許其存取 Netflix 網站。

## 從原始碼建置

需要 Xcode（含命令列工具）。這是純 vanilla JS 擴充功能 + Swift App，無 npm／bundler 建置鏈。

1. 在 Xcode 登入你的 Apple ID（**Xcode → Settings → Accounts**，免費的 Personal Team 即可）取得開發簽署憑證。
2. 設定你自己的簽署 Team ID：

   ```bash
   cd MultiSub
   cp Local.xcconfig.example Local.xcconfig
   # 編輯 Local.xcconfig，把 YOUR_TEAM_ID 換成你的 10 碼 Apple Team ID
   ```

   `Local.xcconfig` 已被 gitignore，不會被提交；App 與擴充功能共用的容器會在執行期依你的簽署 Team ID 自動推導，無需改動任何原始碼。

3. 建置並安裝：

   ```bash
   ./deploy.sh
   ```

   腳本會建置、複製到 `/Applications`，並向 LaunchServices 去重登錄（避免 Safari 載到重複副本）。完成後於 Safari 啟用擴充功能即可。

模型與設定存放於 App 與擴充功能共用的 App Group 容器：
`~/Library/Group Containers/<你的TeamID>.com.seanhuang.multisub/MultiSub/`。

### 打包 DMG（維護者）

```bash
./deploy.sh --release        # Release 建置 → build/MultiSub.app
./scripts/make-dmg.sh        # 產出 build/MultiSub-<版本>.dmg + SHA256
```

## 運作方式

- `extension/`：Web 擴充功能（純 JS）。`inject.js` 在頁面注入、攔截 Netflix 字幕檔（WebVTT/TTML）；`content.js` 負責第二字幕 overlay 與播放同步；`background.js` 管理翻譯佇列與快取；`popup.*` 是設定介面。
- `MultiSub/`：Xcode 專案。`Shared/TranslatorCore.swift` 用 MLX 載入 Gemma、批次翻譯；host App（SwiftUI）管理模型下載、字幕樣式、快取與生詞本；Safari 擴充功能的 native handler 透過 native messaging 呼叫翻譯。

## 隱私

- **翻譯完全在本機執行**，字幕與觀看資料不外傳。
- 首次使用會從 **Hugging Face** 下載模型權重（一次性）。
- App 的「檢查更新」功能會連線 **GitHub Releases 公開 API** 比對版本。
- 除上述兩者外，MultiSub 不進行其他網路連線。

## 授權

本專案採 **MIT License**（見 [LICENSE](LICENSE)）。

第三方相依套件與資料集的授權聲明見 [THIRD-PARTY-NOTICES.md](THIRD-PARTY-NOTICES.md)，其中包含 MLX／swift-huggingface 等 SPM 相依套件，以及內建 CEFR 詞表的引用義務（CEFR-J Wordlist v1.5 與 Octanove Vocabulary Profile C1/C2，後者為 CC BY-SA 4.0，僅適用於該資料檔本身、不影響本專案程式碼授權）。

## 商標聲明

MultiSub 為非官方社群專案，與 Netflix, Inc. 無任何關聯、未經其背書或贊助。"Netflix" 及相關標誌為其各自所有者之商標，本專案僅為描述性目的提及，未使用任何 Netflix 標誌，亦不暗示任何官方關係。
