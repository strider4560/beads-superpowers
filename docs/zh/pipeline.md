---
sidebar:
  order: 10
machine_translated: true
description: 五阶段流水线如何跨越两类会话，把一个想法推进到经过评审的 epic；各参与者各自持有怎样的权限；以及出现偏差时哪些门控会在失败时拒绝放行。
---

<!-- Role: the contract between beads-superpowers and great_cto - stages, session roles, tier vocabulary, gates, and the plan of record. Does NOT belong here: per-skill reference detail (skills.md), or the router-style walkthrough of the older single-session flow (workflow.md). -->

!!! warning "机器翻译"
    本页面由 AI 自动翻译，可能存在术语或语义偏差。如有疑问，请以[英文原文](pipeline.md)为准。

# 流水线

[示例工作流](workflow.md)描述的是本流水线所取代的单会话流程：想了解各个技能之间如何相互路由，读那一页；想了解如今覆盖其上的阶段与权限契约，读本页。

工作流经五个阶段，分属两类会话：规划会话以产出一张 bead 图收尾，实现会话读取这张图并据此构建。两者之间不靠散文交接。计划的权威记录是 bead 图加上 `.mex/` 知识库，因此实现会话从不去解析规划会话写下的文档。

流水线横跨两个仓库。beads-superpowers 负责流程机制——阶段契约、bead 与 mex 的数据结构，以及 `scripts/pipeline/` 下的脚本。[great_cto](https://github.com/strider4560/great_cto) 负责部署绑定——智能体名册、审查契约、智能体提示词，以及从能力档位到具体模型的映射表。beads-superpowers 在 `~/.agents/great_cto/` 解析该捆绑目录，缺少它就拒绝运行：

```bash
git clone https://github.com/strider4560/great_cto ~/Develop/great_cto && ~/Develop/great_cto/scripts/install.sh --host all
```

## 五个阶段

| 阶段 | 技能 | 输入到输出 |
|------|------|------------|
| 1. 头脑风暴 | `brainstorming`（本仓库） | 一个想法变成已批准的需求，以及 `.internal/specs/` 下的设计规格 |
| 2. 评审推敲 | `planning-with-reviews`（great_cto） | 已批准的规格交给选定的领域评审者以只读方式审阅，带着不可变的评审产物定稿返回 |
| 3. 固化 | `writing-plans`（本仓库） | 定稿的规格变成 Markdown 计划、一张 bead 图，以及支撑它的 mex 声明 |
| 4. 实现单个 epic | `implementing-epics`（great_cto） | 挑选 epic、分组任务、准备 worktree 与分支；每个任务组交给本仓库的任务引擎 |
| 5. Epic 评审 | `reviewing-epics`（great_cto） | 构建完成的 epic 交给强制评审者以及计划中声明的评审者，只读，分轮进行并设有轮次上限 |

每个阶段的收尾动作就是调用下一阶段的技能，因此这个顺序无需一个监管状态机也能成立。一处琐碎修复——一行代码、没有设计问题——可以跳过这些阶段，但跳不过下文的守卫规则：它们对每个会话和每个子代理都生效，与其自认为处在哪个阶段无关。

## 两类会话角色

**规划会话**在规划档位上一气呵成地跑完第 1 到第 3 阶段，会话强度为 `high`，以 land the plane 收尾。它派发的评审者运行在规划档位、强度 `xhigh`、只读工具；固化阶段的机械式并发派发运行在强度 `low`。

**实现会话**在实现编排档位上运行第 4 和第 5 阶段，每个 epic 一个全新会话。它把声明了相同实现智能体、且路径互不重叠的就绪任务分为一组，为每组配一个 worktree 和一个分支，并在实现档位上为每组派发一名实现者，按测试驱动开发推进。完成的任务组由单个 `senior-dev` 评审该组合并后的 diff，逐条对照组内每一项验收标准，运行在评审档位、强度 `high`，每组五轮封顶。bead 台账仍按任务粒度记录：编排者依据该组验证得到的证据，逐个关闭任务 bead。

当实现会话遇到真正的设计问题时，它创建一个 `needs-planning` bead 阻塞受影响的任务，并停下该任务。epic 继续推进不依赖它的其他任务。重新规划发生在下一次规划会话——它优先清空 `needs-planning` bead——而绝不在当前赛道上就地进行。

## 能力档位

本仓库的技能只使用以下四个档位名称，不使用其他说法：

- **规划档位**——规划会话及其评审者
- **实现编排档位**——运行某个 epic 的会话
- **实现档位**——任务实现者；计划可以为个别任务上调该档位
- **评审档位**——epic 评审者以及每组任务的评审

档位是派发期的成本约定，而不是强制边界：自代理权限重构（2026-08-21）起，没有任何门控读取会话的模型；会话或派发运行在哪个模型上由人来选择，档位映射表只是把这一选择记录下来。模型标识符和默认强度只出现在 great_cto 的档位映射表里。本仓库分发到的各类 harness 对模型的命名各不相同，有的根本不暴露模型名，因此有一道守卫会拒绝在与 harness 无关的内容里出现模型名。想知道某个档位对应哪个模型，请查档位映射表，而不是查技能文件。

## 哪些门控失败即拒绝

四道门控，全部由工具实现而非靠散文约束。没有一道要求智能体自我监管。

**硬依赖检查。** `install.sh` 在探测工具、改动任何东西之前先校验捆绑根目录。唯一的例外是 `--uninstall`：卸载 beads-superpowers 绝不应当反过来要求它运行时所依赖的东西。在流水线脚本里，捆绑根目录在门控自身的版本握手与完整性检查之后、其余一切之前解析。捆绑根目录缺失时，会打印上文那条安装命令并以非零码退出。会话启动钩子同样会报告捆绑根目录是否存在，判断依据仅为目录是否存在，因为该钩子只读文件。

**预检门控。** 阶段技能在进入阶段时调用 `scripts/pipeline/tier-gate.sh --stage planning|implementing|reviewing`（文件名是历史遗留）。门控校验的是安装本身：门控与其根目录之间的版本握手、完整性记录，以及满足版本下限的 great_cto 捆绑。它不读取会话的任何信息——不读模型、不读强度、不读会话标识——因此任何 harness 或模型 id 的写法都不可能卡死一个阶段。

同一脚本还承载流水线的定位模式：`tier-gate.sh --phase` 由智能体运行、只读、仅供参考——它读取 bead 图（在没有进行中的工作时，还读取 `.internal/` 下的规划产物），打印当前阶段以及一行 `next:` 建议。当你说「继续」或「进行到哪了」时，编排智能体会运行它并据其结果路由；你自己从不运行流水线脚本。只有 `phase:` 和 `next:` 两个行前缀属于契约。

**PreToolUse 兜底。** 在存在钩子的场景下，项目一旦处于启用状态，就有两族规则生效，没有询问或确认这类中间地带。规则 D：流水线自身的状态目录和已安装的门控文件面，任何调用者都不允许写入——能改写正在裁决自己的控制件，就等于自我授权。规则 S：子代理——由 harness 在每次子代理工具调用上盖章的 `agent_id` 机械识别，绝不按名字识别——不能改动 bead（只读命令和对自己任务 bead 的 `bd note` 仍然放行）、不能写 mex、不能编辑计划记录（`plans/`、`.internal/plans/`、`.internal/specs/`）；这些属于派发它的编排会话，拒绝消息会告诉子代理改为在报告中提出需求。编排会话本身不受规则 S 限制。钩子内部出错时选择拒绝而非放行，并且它不依赖智能体是否愿意调用门控脚本。

过去设在这里的会话模型档位墙——按会话运行的模型来裁决的规则——已在代理权限重构中移除：只要 harness 给出的模型 id 写法不在档位映射表里，整个会话就会被卡死，而 PreToolUse 本来就收不到模型字段。如今护栏只挂在可被机械观测的事实上：子代理身份。

**graph-lint。** `scripts/pipeline/graph-lint.mjs` 读取 `bd list --json`，校验每个任务的实现智能体和每个 epic 的评审者都存在于捆绑根目录的名册中、依赖图无环、档位取值存在于档位映射表、必需的正文小节齐备，以及 initiative 到 epic 再到 task 的结构完整。固化阶段不通过它就无法完成，实现会话在挑选 epic 之前会重新跑一遍。校验失败意味着去修 bead 然后重跑；绕过它手工改动会让这道门控形同虚设。

## Beads 与 mex 是计划的权威记录

没有交接文件。在第 3 阶段到第 4 阶段的边界上，没有任何导出、导入或重新解析。

**bead 图**承载「做什么」。固化阶段以原子方式创建它：先用 `bd create` 建 initiative，再用 `bd import -` 以 JSONL 导入 epic 和 task，最后用 `bd batch` 建立任务之间的 `blocks` 依赖。一个带 `initiative` 标签的 epic 型 bead 保存计划的目标与成功标准，并指向 mex 声明和定稿规格。实现 epic 是它的父子级子节点，因此在最后一个 epic 关闭之前，bd 会让 initiative 保持打开。任务 bead 挂在各自的 epic 下，正文原样承载验收标准，元数据承载 `implementation_agent`、`required_skills` 和 `tier`。强度不是任务字段：harness 支持按调用指定模型，却不支持按调用指定强度，因此强度改为在 great_cto 的智能体定义里按角色固定。

**mex 库**承载「为什么」。固化阶段为最终需求、设计、计划依据各记录一条 decision 条目，然后按既有的路由与篇幅约定，把一页 initiative 摘要蒸馏进 `.mex/context/`。bead 引用 mex 条目，mex 条目引用 bead ID，从任意一半都能找到另一半。由于 `.mex/` 会被提交并随仓库分发，固化步骤在每次写入前都会跑一遍密钥与个人信息扫描，并让声明保持蒸馏状态——只留指针和依据，绝不写入凭据、客户名称或逐字照抄的敏感需求。完整的散文规格和评审产物留在 `.internal/`，该目录被 gitignore 且仅在本次会话有效。

图的创建是可重入的，而不是事务性的。若中途失败，重跑固化步骤——`bd import` 是幂等的 upsert——直到 graph-lint 通过为止。绝不要手工删除一张建了一半的图。

因此实现会话开局只需三次读取：`bd ready` 取出本 epic 的任务，initiative 与 epic 的 bead 正文取出目标与标准，mex 检索取出推理过程。它不依赖规划会话的任何上下文。

## 跨仓库契约

great_cto 通过三条绝对路径调入本仓库。这些路径的写法、它们必须在哪个目录下运行，以及它们承诺的退出码，构成两个捆绑之间的接口，因此只能在两边协同发布时才改动。

```bash
# All three MUST be run with the working project's repo root as the cwd —
# session state, --state dumps, plan files and git state are cwd-relative.
bash "$HOME/.agents/beads-superpowers/scripts/pipeline/tier-gate.sh" --stage <stage>
node "$HOME/.agents/beads-superpowers/scripts/pipeline/graph-lint.mjs" --initiative <id> --state <dump>
"$HOME/.agents/beads-superpowers/skills/subagent-driven-development/scripts/review-package" <plan-path> <MERGE_BASE> HEAD
# Exit contract: 0/1/2 as documented per script. Any other exit — including
# 127 (missing file) — is fail-closed: stop and report. This row is also added
# to the exit tables in skills/brainstorming and skills/writing-plans.
```

`review-package` 的第一个参数是一个必须在磁盘上真实存在的计划文件；标识工作区的正是这个计划路径。`${CLAUDE_PLUGIN_ROOT}` 在 great_cto 的调用中是被拒绝的写法；上面那三条绝对路径是唯一被接受的写法。

### 流水线在哪些渠道受支持

只有两个渠道：`install.sh` 的脚本化安装层级（本地、tarball 或 git），以及 Claude Code 插件渠道。本项目分发的其余渠道——npx、七种尽力支持的 harness 插件安装、OpenCode 的 git 插件安装，以及任何插件渠道不执行本仓库钩子的 harness——都属于流水线不可用。那里的门控会失败即拒绝，而不是切换到降级模式运行，因此本该被检查的调用会停下来，而不是不经检查就放行。

### 版本配对与回滚

两个捆绑互相锁定成对：great_cto 3.0.x 对应 beads-superpowers 0.17.x，great_cto 3.1.0 对应 beads-superpowers 0.18.0。0.17.x 那一半的定义就是「锚点目录不存在」，因此一台主机处在哪一半是可以检查的，不必靠记忆：`$HOME/.agents/beads-superpowers` 在 0.18.0 上存在，在 0.17.x 上不存在。

回滚按以下顺序进行，而第一步正是最容易做错的一步：

1. 先运行 **0.18.0 自带的** `install.sh --uninstall`，然后才安装更旧的版本。移除某个产物的安装器必须是当初创建它的那一个，而 0.17.x 的安装器对锚点目录和完整性记录一无所知，会把两者都遗留下来。这一步会删除 `$HOME/.agents/beads-superpowers` 以及 `$HOME/.local/state/beads-superpowers/` 下的记录。
2. 检出 great_cto 的 `v3.0.0` 并重跑它的安装器。
3. 安装 beads-superpowers 0.17.0。

计划在 bead 上留下的 `paths` 与 `plan_path` 标记不需要撤销。它们是纯增量的元数据，0.17.x 的工具链会直接忽略，因此回滚只做向前修复。要重置流水线的会话状态，删除 `.internal/pipeline/` 即可。

### 声明任务会改动哪些文件

每个任务 bead 都携带 `metadata.paths`：一组相对仓库根目录的路径字符串，覆盖该任务会编辑或创建的文件。实现会话据此给任务分组，因此路径互相重叠的两个任务绝不会在同一个 worktree 里并行运行。两个仓库实现同一套比较规则，凡不符合规范形式的，graph-lint 一律拒绝：

条目相对仓库根目录；不带前导的 `./` 或 `/`；不含 `..`、不含中间的 `.` 段（`src/./a.ts`），也不含空段（`src//a.ts`）；只用正斜杠；不得有重复条目；比较按字节精确进行；当且仅当条目声明的是一个目录时才带结尾的 `/`（在条目已存在于磁盘上时可强制校验——对于尚未创建的路径，其写法按声明照单接受）。重叠：当两个声明中任一方是另一方的路径分段前缀时，二者重叠（`src/` 与 `src/a.ts` 重叠；`src/ab.ts` 与 `src/a.ts` 不重叠）。

### 门控拦下你时怎么办

有两类失败可以由你直接处置。两者都是拒绝而非警告，也都没有智能体侧的补救办法——这正是设计意图。

| 门控报告了什么 | 怎样才能解除 |
|----------------|--------------|
| 完整性记录缺失或不可读，或某个文件 `does not match its recorded hash` | 重跑 `install.sh`。记录由掌管该渠道的维护者写入——脚本化安装层级由 `install.sh` 写入，插件渠道由会话启动钩子写入——也只有该维护者能重写；在插件渠道上，这意味着开一个新会话，让该钩子重新为根目录背书。 |
| `is running against beads-superpowers root`，且给出的版本与门控自身的版本不一致 | 重跑 `install.sh`，或刷新插件，让门控与已安装的根目录处于同一版本。 |

本契约的既接受风险与残余项记录在私有位置——决策记录的修订件和 `.mex/private/`——而不在本页面上。
