# 發版流程

MultiSub 有兩個發行管道，版本號要一致：

- **DMG + Homebrew**：DMG 用 Developer ID 簽章並經 Apple 公證，發在 [ncchen99/Multisub 的 Releases](https://github.com/ncchen99/Multisub/releases)。Homebrew 的 cask 放在 [ncchen99/homebrew-multisub](https://github.com/ncchen99/homebrew-multisub)，下載的也是同一個 DMG。App 內建的更新檢查（`UpdateChecker.swift`）看的也是這個 repo 的最新 release。
- **Mac App Store**：用 `scripts/archive-appstore.sh` 上傳，見文末。

Homebrew 規定 DMG 不能比 App Store 版舊，所以兩邊要一起發。

## 一次性準備

換一台 Mac 發版時，下面每一項都要先做好。

1. **Developer ID 憑證**。鑰匙圈裡要有「Developer ID Application: Nian-Cheng Chen (V7H59QAJPL)」。用下面的指令檢查，沒有的話到 Xcode ▸ Settings ▸ Accounts ▸ Manage Certificates 按 + 新增「Developer ID Application」。

   ```bash
   security find-identity -v -p codesigning
   ```

2. **`MultiSub/Local.xcconfig`**。從 `Local.xcconfig.example` 複製一份，`DEVELOPMENT_TEAM` 填 `V7H59QAJPL`，`MULTISUB_BUNDLE_ID` 填 `com.ncchen.multisub`。bundle ID 一定要跟之前的版本相同，不然使用者的設定、API Key 和生詞本都接不上。

3. **公證用的帳密**。到 account.apple.com ▸ 登入與安全性 ▸ App 專用密碼產生一組，然後執行下面的指令，把密碼貼進去。帳密會存進鑰匙圈，之後 `make-dmg.sh` 就用 `multisub-notary` 這個名字取用。

   ```bash
   xcrun notarytool store-credentials multisub-notary --apple-id ncchen99@gmail.com --team-id V7H59QAJPL
   ```

4. **讓終端機控制 Finder**。`make-dmg.sh` 會用 Finder 排 DMG 視窗的背景和圖示位置。第一次執行時 macOS 會問，按允許。錯過的話到系統設定 ▸ 隱私權與安全性 ▸ 自動化，打開你的終端機底下的「Finder」。

5. **`gh` 登入 ncchen99**。發 release 和推 tap 都要用到。

   ```bash
   gh auth status
   ```

6. **Clone tap repo**。放在主專案旁邊就好：

   ```bash
   git clone https://github.com/ncchen99/homebrew-multisub.git ~/Documents/homebrew-multisub
   ```

## 每次發版

下面用 `1.2.0` 當例子，換成這次的版本號。

### 1. 改版本號

版本號在兩個地方。Xcode 專案裡有四處 `MARKETING_VERSION`（App 和延伸功能的 Debug、Release），延伸功能的 `extension/manifest.json` 有一處 `"version"`。用下面的指令一次改完：

```bash
NEW=1.2.0
sed -i '' -E "s/MARKETING_VERSION = [0-9.]+;/MARKETING_VERSION = $NEW;/" MultiSub/MultiSub.xcodeproj/project.pbxproj
sed -i '' -E "s/(\"version\": \")[0-9.]+/\1$NEW/" extension/manifest.json
git diff --stat
```

`git diff --stat` 應該只列出這兩個檔案。build number 不用改，每次建置會自動用時間戳記。

### 2. 合併到 main 並推上去

release 要從 `main` 發，所以這一版的改動要先合併進 `main`，再推到 `origin`（ncchen99/Multisub）。

```bash
git switch main
git merge --no-ff <這一版的分支>
git push origin main
```

### 3. 建置 Developer ID 版

```bash
./deploy.sh --release
```

腳本會 archive、用 Developer ID 匯出，再把 App 放到 `build/MultiSub.app`。最後一步會檢查簽章是不是 Developer ID、有沒有開 Hardened Runtime，兩項都要打勾。這個指令不會動到 `/Applications` 裡的開發版。

### 4. 打包 DMG、送公證

```bash
./scripts/make-dmg.sh
```

公證通常要 1 到 5 分鐘，腳本會一直等到 Apple 回覆。成功的話最後會看到：

- `✓ 公證通過（<submission id>）`
- `✓ Gatekeeper 接受 DMG 與 App（Notarized Developer ID）`

產出的檔案是 `build/MultiSub-1.2.0.dmg` 和 `build/MultiSub-1.2.0.dmg.sha256`。

`NOTARIZE=0 ./scripts/make-dmg.sh` 會跳過公證，只適合自己測試排版。那個 DMG 不能發行，下一步的 `make-cask.sh` 也會拒絕它。

### 5. 發 GitHub Release

先打 tag，再建 release 並附上 DMG 和 `.sha256`。release 說明寫在一個 Markdown 檔裡，內容參考 [1.1.0 的說明](https://github.com/ncchen99/Multisub/releases/tag/v1.1.0)：列出這版的新功能和修正，再附上安裝方式。

```bash
git tag -a v1.2.0 -m "MultiSub 1.2.0"
git push origin v1.2.0
gh release create v1.2.0 -R ncchen99/Multisub --verify-tag --title "MultiSub 1.2.0" \
  --notes-file <release 說明.md> build/MultiSub-1.2.0.dmg build/MultiSub-1.2.0.dmg.sha256
```

tag 一定要是 `v` 加版本號。App 的更新檢查和 Homebrew 的 cask 都靠這個格式找到新版。

### 6. 更新 Homebrew tap

release 上傳完，DMG 的網址才存在，所以這一步要在第 5 步之後。

```bash
./scripts/make-cask.sh
cp build/homebrew/Casks/multisub.rb ~/Documents/homebrew-multisub/Casks/multisub.rb
cd ~/Documents/homebrew-multisub
git commit -am "multisub 1.2.0"
git push
cd -
```

`make-cask.sh` 會從 DMG 讀出版本號和 SHA256，自動填進 cask。

### 7. 確認裝得起來

```bash
brew update
brew audit --cask --online ncchen99/multisub/multisub
brew livecheck --cask ncchen99/multisub/multisub
brew developer off
```

`audit` 會先下載 DMG 檢查簽章，最後沒有列出任何問題就是通過。`livecheck` 應該顯示新的版本號。`brew audit` 會自動打開 Homebrew 的 developer mode，最後那行把它關掉。

如果出現「Refusing to load cask ... from untrusted tap」，先執行 `brew trust --cask ncchen99/multisub/multisub` 再重跑。使用者用完整名稱 `brew install --cask ncchen99/multisub/multisub` 安裝時，Homebrew 會自動信任這個 cask，不會遇到這個問題。

要實際安裝測試的話，記得 `/Applications/MultiSub.app` 如果是開發版，`brew install` 會因為已經有同名的 App 而停下。可以先把開發版移走，或在另一台 Mac 上測。

### 8. App Store 版

```bash
./scripts/archive-appstore.sh --upload
```

上傳完到 App Store Connect 選這個 build 送審。App Store 版不含自動更新，用的是 `MultiSub-AppStore.entitlements`，這些腳本會自己切換。

## 出問題時

| 狀況 | 處理方式 |
|---|---|
| `make-dmg.sh` 說找不到公證設定檔 | 照「一次性準備」第 3 步重新存一次帳密 |
| 公證未通過（Invalid） | 腳本會印出 Apple 的公證紀錄，通常是某個檔案沒簽到或沒開 Hardened Runtime。照紀錄修好後，從第 3 步重來 |
| `deploy.sh --release` 說不是 Developer ID 簽章 | 確認鑰匙圈裡有 Developer ID Application 憑證、`Local.xcconfig` 的 Team ID 正確 |
| Finder 排版失敗（-1743） | 照「一次性準備」第 4 步打開權限再重跑。不處理的話 DMG 還是會產出，只是視窗沒有背景 |
| `make-dmg.sh` 中途停下、沒有錯誤訊息 | 1.1.0 發版時遇過一次，單獨再跑一次 `./scripts/make-dmg.sh` 就成功了 |
| 發錯了想重發同一版 | `gh release delete v1.2.0 -R ncchen99/Multisub --cleanup-tag`，修好後從第 3 步重來。tap 已經更新的話，第 6 步要重做，因為 SHA256 會變 |
