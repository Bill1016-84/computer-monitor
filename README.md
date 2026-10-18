# Computer Monitor

macOS 選單列硬體監控小工具：即時顯示 CPU、記憶體、GPU、網路速度和電池，旁邊還有一隻會隨 CPU 使用率加速奔跑的小動畫（刺蝟、檸檬，或你自己的動畫）。

![下拉面板（淺色／深色）](preview.png)

## 功能

- **選單列**：CPU、記憶體、GPU、網路上下行、電池，每一項都可以在「在選單列顯示」中開關；使用率高時數字會變橘色或紅色。
- **下拉面板**：每項指標畫成一顆晶片，資料粒子沿著電路流動，流速跟著使用率變化。下面還列出負載、Swap、磁碟、開機時間等詳細資訊。
- **跑步動畫**：CPU 越忙跑越快。內建 10 段動畫：
  - 刺蝟：經典奔跑、衝刺滑倒、跑累睡覺、滾球模式、追逐蘋果
  - 檸檬：搭乘紙飛機、撐傘下雨、吃東西、變裝變形、打瞌睡休息
- **自訂動畫**：把 GIF 或 PNG 丟進資料夾就能用（見下方）。
- 可設定更新頻率（1／2／5 秒）、登入時自動啟動。
- 很輕量：CPU 約 1%，記憶體約 15 MB；不連網路、不需要管理員權限。

需求：macOS 13 以上。

## 編譯與安裝

```sh
xcode-select --install     # 第一次才需要：安裝 Apple 編譯工具
./build.sh                 # 產生 build/ComputerMonitor.app
open build/ComputerMonitor.app
```

自己編譯的 App 不會出現「無法驗證開發者」的警告。要用「登入時自動啟動」，請先把 App 移到「應用程式」資料夾。

`build/ComputerMonitor.app/Contents/MacOS/ComputerMonitor --print` 可以在終端機印出一次目前的數值。

## 自訂動畫

在選單點「動畫樣式 → 打開自訂動畫資料夾…」，或直接打開：

```
~/Library/Application Support/ComputerMonitor/Animations/
```

把動畫放進去，再打開「動畫樣式」選單就會出現（名稱就是檔名）：

| 格式 | 檔名範例 | 格數 |
|---|---|---|
| GIF 動圖 | `貓咪.gif` | 自動讀取 |
| 橫向連續格 PNG | `貓咪@8.png` | `@` 後面的數字；每格同寬、由左到右 |
| 一格一張的資料夾 | `貓咪/1.png`、`2.png`… | 依檔名數字順序 |

- 背景請用透明；任何尺寸都可以，會自動等比例縮成選單列高度（寬高比 1:1～3:1 最適合）。
- 播放速度由 CPU 使用率決定，GIF 自帶的速度會被忽略；最多 240 格。

## 專案結構

```
Sources/
  main.swift          App、選單、選單列顯示
  GraphPanel.swift    下拉面板的晶片動畫
  Metrics.swift       讀取 CPU／記憶體／GPU／網路／磁碟／電池
  Hedgehog.swift      跑步動畫的載入與自訂動畫資料夾
Resources/
  Animations/         內建動畫（<名稱>@<格數>.png，高 36 px）
  AppIcon.icns, icon-1024.png
Tools/
  slice-hedgehog.py   把刺蝟原圖切成動畫條
  slice-lemon.py      把檸檬原圖（黑底）切成動畫條
  make-icon.sh/.swift 產生 App 圖示
Cute Pixel Hedgehog Animation Sheet.png    刺蝟原圖（ChatGPT 生成）
Cute Lemon Blob Animation Storyboard.png   檸檬原圖（ChatGPT 生成）
```

重新切內建動畫（需要 Python 的 pillow、numpy、scipy）：

```sh
python3 Tools/slice-hedgehog.py "Cute Pixel Hedgehog Animation Sheet.png" Resources/Animations preview-hedgehog.png
python3 Tools/slice-lemon.py "Cute Lemon Blob Animation Storyboard.png" Resources/Animations preview-lemon.png
```

## 分享給別人

```sh
ditto -c -k --keepParent build/ComputerMonitor.app ComputerMonitor.zip
```

目前的 App 只有臨時（ad-hoc）簽署、沒有經過 Apple 公證，對方第一次打開會被擋下：請到「系統設定 → 隱私權與安全性」按「強制打開」。在 Apple 晶片 Mac 上編譯的版本不能在 Intel Mac 上執行；Intel Mac 的使用者請自己用 `./build.sh` 編譯。
