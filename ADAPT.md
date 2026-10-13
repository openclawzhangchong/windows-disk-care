# ADAPT.md — 给在新机器上第一次拉这个仓库的 AI

你的任务不是"运行脚本"，而是**让脚本认识这台机器**。代码是通用的，机器知识全在 `config/patterns.json` 里。
看到没见过的目录，就加一条 pattern，**不要改脚本本体**。

## 第 0 步：先确认环境（30 秒，必做）

```
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\lint-ascii.ps1 -Root .\scripts
```

如果报 FAIL：说明有人（很可能就是你）往 `.ps1` 里写了中文。Windows PowerShell 5.1 读无 BOM 的 `.ps1` 按 ANSI 解码，
中文字节会打断引号，报出跟中文毫无关系的 `UnexpectedToken` 错误。**把中文移到 `.md` 或 JSON 里**，别去改解析逻辑。

同类的第二个坑：`powershell -File x.ps1 -Cats A,B,C` 在 5.1 下**不会**按逗号拆成数组，整个 `"A,B,C"` 当一个字符串传进去。
本仓库已避开多值参数（改成 `-Do clean|archive|move` 单值 + JSON 计划文件），但你新写脚本时要记得。

## 第 1 步：体检

```
powershell -File .\scripts\scan.ps1 -Out .\out\scan.json
```

四个输出段，每段都有一个必须做的动作：

| 段 | 看什么 | 你要做什么 |
|---|---|---|
| 1 volumes | 有没有哪个盘和 C **不在同一块物理盘** | 只有异盘的剩余空间才算搬迁目的地。**C 和 D 常是同一块盘的两个分区**，此时搬去 D 一分钱不省 |
| 2 patterns | 每条的 `GB / OldGB / Verdict` | Verdict 是结论：`ACTIONABLE` 可动、`IN-USE` 有进程引用、`ALREADY-RELOCATED` 已经搬过（**别再搬**）、`report-only` 只报告 |
| 3 reparse points | 跨盘联接 / 遗留别名 / 死链 | 死链要查；`STALE Windows alias` 是系统自带别名目标丢失，**属既成事实，不要"顺手修复"删除**，删了会搞坏 shell 文件夹 |
| 4 UNRECOGNIZED | 库里没有、但 > 0.3 GB 的目录 + 它的前 3 种扩展名 | **这是你唯一需要判断的地方**，见第 2 步 |

## 第 2 步：把这台机器特有的目录加进库

对第 4 段每个目录，按扩展名和位置判断类别，然后往 `config/patterns.json` 的 `patterns` 数组追加一条：

```json
{ "id": "some-app-cache", "pathTemplate": "%LOCALAPPDATA%\\SomeApp\\Cache",
  "category": "rebuildable", "owner": "SomeApp", "note": "为什么这么判，写一句" }
```

类别判定表（**判错了代价不对称，宁可保守**）：

| category | 判据 | 删/搬的后果 |
|---|---|---|
| `junk` | `.tmp` `.log` 缓存索引，路径含 `Temp`/`Cache` | 删了没事，会自动重建 |
| `rebuildable` | 包管理器缓存：`npm` `pip` `uv` `Pub` `gradle` `nuget` `cargo` `go mod`；SDK 目录 | **能删但别乱删**：下次构建要重新下载，Android 构建可能几 GB。优先搬去异盘 |
| `evidence` | `*.log`、`CrashDumps`、`.dmp`、`.jsonl` | 用户可能正靠它查问题。**只归档不删除** |
| `userdata` | 聊天记录、文档、`workspace`、`sessions`、项目目录、`.vhdx` | **永不自动删**。搬迁也要人工批准 |
| `mixed` | 一个目录里既有 `.dll/.exe` 又有用户文件（典型：WPS/`kingsoft`） | 先钻进子目录分别定性，别整目录动 |
| `app-binary` | `Program Files`、`%LOCALAPPDATA%\Programs` | **不能用移动的方式搬**。只能卸载后重装选别的盘；或整个目录联接（不保证成功） |
| `user-deleted` | 回收站 | 用户自己删的，必须单独确认 |

`pathTemplate` 只认这几个 token：`%LOCALAPPDATA%` `%APPDATA%` `%USERPROFILE%` `%TEMP%` `%PROGRAMDATA%` `%SYSTEMDRIVE%`。
加完重跑 scan，那个目录应该从第 4 段消失、出现在第 2 段。

## 第 3 步：出计划

```
powershell -File .\scripts\plan.ps1 -ScanJson .\out\scan.json -Out .\out\plan.json -DestRoot 'F:\relocated'
```

`-DestRoot` 必须填第 1 步确认的**异盘**路径，否则脚本直接报错退出（同盘搬迁是伪操作）。

计划会把你机器上的目录分成 `clean / archive / move / skipped` 四组，并打印 `POTENTIAL` 上限。
**先把这四个数字报给用户，等他点头**，再往下走。

## 第 4 步：执行（永远三步，不许合并）

```
powershell -File .\scripts\apply.ps1 -Plan .\out\plan.json -Do clean            # 先看清单
powershell -File .\scripts\apply.ps1 -Plan .\out\plan.json -Do clean -Apply     # 再删
powershell -File .\scripts\apply.ps1 -Plan .\out\plan.json -Do archive -Apply   # 日志：先 7z 并测完整性，通过才删源文件
powershell -File .\scripts\apply.ps1 -Plan .\out\plan.json -Do move -Apply      # 复制→校验→改名保留→建联接
powershell -File .\scripts\verify.ps1 -Plan .\out\plan.json -ScanJson .\out\scan.json
powershell -File .\scripts\apply.ps1 -Plan .\out\plan.json -Reclaim -Apply      # 只有 verify 通过才回收
```

不加 `-Apply` 一律是 dry-run。**空间只有在删掉 `.cubackup` 之后才真的回来**，所以 `-Reclaim` 前必须看到 `VERDICT: ALL CHECKS PASSED`。

`-Do move` 对 `userdata` 类会直接 `REFUSE auto-move`——这是设计如此，不是 bug。真要搬就在图形界面里由用户自己操作，或明确批准后单独特判。

## 第 5 步：把这台机器的档案留下

在 `profiles/` 下按 `TEMPLATE.json` 存一份这台机器的档案：盘符归属、建了哪些联接、哪些目录被判定为 `mixed` 需要下次单独看、有什么异常系统状态（比如遗留别名目标丢失）。
下次再来时，先读档案，再跑 scan 对比——**没有档案，每一次都是重新体检**。

档案写完后把敏感内容去掉（用户名、计算机名、软件清单、项目目录名）再提交到公共仓库；私有仓库可保留原样。

## 不要做的事

- 不要清空回收站、不要动 `Downloads/Desktop/Documents/聊天记录`，除非用户明确说。
- 不要碰 `C:\Windows\Installer`（删了软件无法卸载或修复）、不要手工删 `WinSxS`、不要动 `pagefile.sys`。
- 不要卸载软件来"腾空间"——那是用户的选择，不是你的优化手段。
- 不要在远程桌面/无人值守的机器上结束任何远程控制软件的进程。
- 搬之前先查有没有卷影副本或还原点；**一个都没有时，删除就是不可逆的**，只能靠"复制到别处 → 校验 → 改名保留"保证可回退。
- 不要相信"跑出来 0 GB"。0 通常意味着参数没传进去、或者路径没解析对，而不是"这台机器很干净"。
