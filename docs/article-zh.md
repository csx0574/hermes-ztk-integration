# Agent 上下文 90% 是垃圾：一个 260KB 的工具把 Token 账单砍到十分之一

**作者**: AI深度游民
**发布时间**: 
**原文链接**: https://mp.weixin.qq.com/s/sVAOJPCEl1HY-L2gFZfTbw
**抓取时间**: 2026-06-26 08:47:52

---

![img](https://mmbiz.qpic.cn/sz_mmbiz_png/SiaGpPqCviac1oCZ0YZobwEDASeHicQOGTBNEYMiamKaP81cKiaGZeB7ZLfb0YQKxBMsUBYC7kkazJbAIxTuvK5FJ736HUCtRwZqicHLsPfwrjeW4/640?wx_fmt=png&from=appmsg) 你不需要更大的上下文窗口。你只需要把灌进去的垃圾清掉。 每个人都在讲 Context Engineering 很重要，但几乎没人告诉你——真正塞满上下文窗口的，不是你的 Prompt。 是 shell。 Agent 每跑一次 git diff HEAD~5 ，九万 token 砸进上下文窗口。一次正常的编码会话，实测 580 万 token 被白白烧掉 。 这不是理论数字。是跑了代理、看了缓存文件、被账单逼出来的真实数据。 

## ztk：一个周末写出来的上下文压缩机

 打开 github.com/codejunkie99/ztk [1] ，你会看到一个 260KB 的二进制文件。 没有运行时。没有 Python。没有包管理器。没有共享库。 纯 Zig stdlib。 把它插在 Agent 和 shell 之间，所有命令输出经过它再喂给模型。 一次真实编码会话（256 条命令）的数据： ![img](https://mmbiz.qpic.cn/sz_mmbiz_png/SiaGpPqCviac2fd157E5d92IzccBty3V5WZzUXlQQHd28qgcEo3ibhvjwbRTbFl5EhVyrdWpAAGI75icuV0FTUsBXBhianYUMLox7EGUaIe8Iv7Q/640?wx_fmt=png&from=appmsg) - •整体压缩率：94.3% - •13.8M token → 0.8M token - • 测试通过的输出 → 几乎归零 - •ls -la→ 几乎归零 - • 两次命令之间无关的git status→ 几乎归零 实测最差的会话也有 71% 压缩率。最好的 94%。 从未出现过反向效果 ——因为不认识的东西默认原样透传。 

## 它到底砍掉了什么？

 想想你的 Agent 上下文里实际在消耗 token 的东西： 命令输出 模型真正需要的信息 实际喂进去的 git diff 哪些文件变了，改了什么行 完整的 blob hash、index 号、上下文行 cargo test 哪些测试挂了，报什么错 200 行 test foo ... ok ls -la 目录里有什么文件 权限位、owner、group、时间戳 cat foo.json 文件内容 文件内容（不压缩——结构化数据不能动） 报错输出 完整的 stack trace 完整的 stack trace（报错永远不压缩） 核心哲学只有一条： 压缩时不能丢失模型做决策需要的信息。 "把输出变小"不是目标。"把输出变小但模型能做出的决策完全不变"才是目标。 

## 六级流水线

 ztk 不是跑一个正则就完事。它有一条六级流水线： 1. Detect — 靠 argv[0] 判断这是什么命令（不是靠输出内容——那是所有同类工具的死亡陷阱） 2. Guard — 三个短路规则：非零退出码的不压、报错信息放行、不到 80 字节的不碰 3. Tokenize — 用 SIMD 向量化拆行、去 ANSI 转义码（92KB diff 从 92000 次分支预测降到 ~5750 次向量化操作） 4. Filter — 每个命令独立的压缩策略。 git diff ：保留文件路径、hunk header、所有 +/- 行，砍掉 blob hash 和上下文噪音。 cargo test ：通过的测试折叠成计数，失败的保留原文。 ls ：提取值得注意的文件（可执行、symlink），其余折叠 5. Dedupe — 相邻重复行折叠。 connection refused 出现 200 次 → 一行 + 计数 6. Cap — 如果压缩后仍然超过预算，截断并打标记： [ztk: 12000 more tokens omitted from git_log output] 。模型知道自己没看全，可以主动要求细化 

## 两个关键设计决策

 一、永远不根据输出内容判断能不能压。根据产生输出的命令来判断。 cargo test 的输出就当测试输出来处理，不管它看起来像不像。 cat 的输出永远不碰，不管它多像日志文件。基于内容的判断是这条路所有前人的墓碑。 二、代理不能比它省下的 token 更慢。 一个 5MB 的 Node 二进制，启动 80ms——省下的 token 全花在延迟上了。ztk 启动不到 1ms。运行成本低于一个 token 的价格。 

## Session 记忆：mmap 缓存

 Agent 循环是高度重复的： ls → 编辑 → ls → 测试 → 编辑 → 测试。 如果 Agent 一分钟内跑了三次 git status 而什么都没变，后两次直接返回 (unchanged since 14:22:06) 。 实现：一个 mmap 映射的缓存文件，4096 个固定槽位，约 320KB。跨进程存活，重启保留。TTL 自动清理。 加上缓存后，压缩率从 67% 跳到了 90%， 因为 Agent 反复跑 git status 和 ls 的程度远超你想象。 

## 怎么接入

 Claude Code 用户：用 PreToolUse hook 拦截 bash 调用，改写为 ztk run 执行。 80 行的适配器：stdin 进 JSON，stdout 出改写后的 JSON。换 Agent（Cursor、Gemini CLI、Copilot）只需加一个适配文件。 

## 永远不要碰的东西

 - •报错：stack trace、panic、编译器报错 → 完整放行 - •退出码：永远保留 - •短输出（<80 字节）：不压 - •结构化数据：JSON、YAML、TOML → 不碰（模型要用 jq/yq 解析） - •不认识的东西：默认透传 - •cat：永远不压 宁可少压，不要改语义。 输出一旦被污染一次，用户就永远走了。 

## 一个周末 → 8 天 → 持续变小

 第 1-2 天：做了一个 daemon 架构的 LSP 式服务器。删了。代理必须是 one-shot 二进制，无进程管理。 第 3-4 天：一个巨大的状态机处理所有命令，80% 能用，剩下 20% 修不了。重写为每个命令族独立 filter。代码更多，bug 更少。 第 5-6 天：正则引擎。Zig stdlib 没有。PCRE 让二进制超 2MB。花一个下午写了 Thompson NFA（Ken Thompson 1968 年算法），400 行。线性时间，永不回溯爆炸。 第 7 天：缓存。40 行代码，压缩率从 67% 飙升到 90%。 第 8-10 天：统计面板和测试语料库。 你能换模型，但控制不了上下文窗口的增长速度。 你能控制的是放进去什么。 而此刻你的上下文里，绝大多数是你从未要求过的元数据。 仓库：github.com/codejunkie99/ztk 

#### 引用链接

 [1] github.com/codejunkie99/ztk: 

