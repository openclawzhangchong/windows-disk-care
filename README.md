# windows-disk-care — 通用版 C 盘整理工具箱

任何一台 Windows 都能用。**机器特定的知识全部写在 `config/patterns.json` 里，代码里不出现任何应用名。**

配套阅读：
- **`ADAPT.md`** — 新机器、新 AI 第一次拉这个仓库时该怎么做（先读它）
- [`c-pan-zhengli2027`](https://github.com/openclawzhangchong/c-pan-zhengli2027) — 只在**一台特定机器**上跑通的实例版，含真实扫描留档和完整过程数字。那个仓库的脚本里写死了具体目录名，**不要拿到别的机器上直接跑**，只当" worked example / 结果长什么样"来看

## 为什么分两个仓库

上一版是在一台 100 GB、只剩 14.4 GB 的机器上做出来的，脚本里混着那台机器特有的目录（某个 AI 客户端的工具链、某个数据库快照目录、某个音乐缓存）。
换到你家或办公室的电脑，那些名字一个都不存在——扫描会漏掉真正的大头，还可能把无关目录当成垃圾。

所以这里重构成两层：

```
代码层（通用，别改）     scripts/*.ps1
知识层（每台机器不同）   config/patterns.json   +  profiles/<机器>.json
```

新增一个软件的认识方式 = 往 JSON 加一条，而不是写新脚本。

## 快速上手

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\lint-ascii.ps1 -Root .\scripts   # 0. 防中文坑
powershell -File .\scripts\scan.ps1   -Out .\out\scan.json                                     # 1. 体检（只读）
powershell -File .\scripts\plan.ps1   -ScanJson .\out\scan.json -Out .\out\plan.json -DestRoot 'E:\relocated'
powershell -File .\scripts\apply.ps1  -Plan .\out\plan.json -Do clean                          # 2. dry-run 看清单
powershell -File .\scripts\apply.ps1  -Plan .\out\plan.json -Do clean -Apply                   # 3. 用户点头后执行
powershell -File .\scripts\verify.ps1 -Plan .\out\plan.json -ScanJson .\out\scan.json         # 4. 搬迁后的哈希核验
```

## 脚本

| 脚本 | 作用 | 写盘 |
|---|---|---|
| `scan.ps1` | 盘符归属与同盘陷阱、按库匹配每个已知目录的体积/年龄/占用判定、联接分类（跨盘搬迁 / 系统别名 / 死链 / 同盘软链）、**UNRECOGNIZED 大目录 + 扩展名线索** | 只读 |
| `plan.ps1` | 把扫描结论变成可执行计划，分成 `clean / archive / move / skipped`；同盘目的地直接报错退出 | 只写 plan.json |
| `apply.ps1` | 执行计划：`-Do clean` 删垃圾、`-Do archive` 日志压缩归档（完整性测试过了才删源）、`-Do move` 复制→校验→改名保留→建联接、`-Reclaim` 回收 | 默认 dry-run |
| `verify.ps1` | 逐条联接做 SHA256 双向比对 + **用户数据回归监视**（哪些目录必须没变小） | 只读 |
| `lint-ascii.ps1` | 检查 `.ps1` 里是否混入非 ASCII 字节（PS 5.1 会因此语法崩溃） | 只读 |

## 三道护栏（设计的一部分，不是可选开关）

1. **绝对路径白名单**：删除只允许发生在计划里明列的根目录下，越界一律拒绝。
2. **文件年龄过滤**：默认只动 7 天以前的文件，正在用的自然跳过并计数。
3. **搬迁永不删除**：复制到目标盘 → 比对文件数与字节数 → 原目录改名成 `<name>.cubackup`（不删）→ 建目录联接 → `verify.ps1` 哈希通过 → 才允许 `-Reclaim` 真正回收。

配套判定原则（详见 `ADAPT.md`）：

- 有进程正从某个目录里**执行**时，它就不是缓存而是运行目录 —— 例如包管理器缓存里跑着 MCP 服务的先例。
- `userdata` 类目录**永远拒绝自动搬迁**，聊天记录、文档、会话历史、虚拟机磁盘都属此类。
- 输出 `0 GB` 时先怀疑参数没传进去，而不是相信"这台机器很干净"。

## 状态

本仓库在**一台真实 Windows 11 机器上完整跑通 dry-run 链路**（scan 认出 33 条库内 pattern、正确区分已搬迁/占用/可动，plan 拦下用户数据自动搬迁，verify 通过回归监视）。真实数字与过程见配套实例仓库。
