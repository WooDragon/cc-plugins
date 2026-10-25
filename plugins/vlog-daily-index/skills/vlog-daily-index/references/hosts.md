# 宿主说明

本技能是同一套规则、两个宿主绑定：Codex（既有、已验证的工作流）与 Claude Code。九步工作流程的规则、判据与门槛对两个宿主完全一致；本文只记录角色如何绑定到宿主，以及唯一真正的行为差异。

## 角色绑定

| 角色 | 职责 | Codex 绑定 | Claude Code 绑定 |
|---|---|---|---|
| 视觉Agent | 逐帧读图，只记可见事实 | Luna | `vlog-daily-index:vlog-vision` |
| 语义Agent | 跨帧/跨文件/ASR/GPS 汇总（high） | GPT-6.1 Sol (high) | `vlog-daily-index:vlog-semantic` |
| 地理Agent | 专门的地点与主体身份核验（必须另派） | 专门 GPT-6.1 Sol (high) | `vlog-daily-index:vlog-geography` |
| ROOT | 最终实质审查与补采裁决 | 主控会话 | 主控会话 |

`ROOT`保持字面量：它是`--reviewer`的argparse choices与多处断言的锚点，不随宿主改名。

## 宿主差异

1. **并发名额来源**：Codex使用会话实际空闲的子Agent名额，改上限须重启Codex并新建聊天；Claude Code默认同时20个，可由`CLAUDE_CODE_MAX_CONCURRENT_SUBAGENTS`调整。两边`vision-queue --available-workers`都必须传**当前真实空闲数**，不得传配置目标值。
2. **ROOT的执行位置**：只有主会话能执行`decide-supplement`、`approve-final`、`review-frames`、`naming-review`。子Agent不得代跑这四个命令。
3. **Agent 写入边界**：Claude Code侧用agent frontmatter的`tools: Read, Write`做工具级白名单，路径级限制由用户/项目权限规则承担；Codex侧由派发prompt与包内`result_path`约束写入边界。两侧子Agent都只写包内`result_path`。
4. ROOT 在两端都取主会话当前模型；Codex 侧的 'ROOT_current_flagship' 是记录约定，不是独立进程。

## 安装与调用

Claude Code：

```bash
claude plugin install vlog-daily-index@cc-plugins
```

三个agent随插件提供，派发时用`subagent_type`调用`vlog-daily-index:vlog-vision`、`vlog-daily-index:vlog-semantic`、`vlog-daily-index:vlog-geography`。

首次 `init` 须显式传 `--host claude-code`；省略则 manifest 记录 `host: codex` 与 Codex 侧模型名，与实际执行的子 Agent 不一致。

Codex：

```bash
npx skills add WooDragon/cc-plugins -g
```

在技能选择中选取`vlog-daily-index`并确认安装目标为Codex；按上表模型名派发。`agents/openai.yaml`只提供展示元数据，不承载派发逻辑。

其余安装依赖（Python、FFmpeg、ASR服务）见[安装](setup.md)，验证范围见[发布与验证记录](release-verification.md)，并发细节见[并发约定](concurrency.md)。
