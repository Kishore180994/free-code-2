# free-code-2

**Use Claude Code (or free-code) with any AI model -- for free.**

A guide and patch set for running [Claude Code](https://github.com/anthropics/claude-code) or [free-code](https://github.com/paoloanzn/free-code) with free and open-source models through [OpenRouter](https://openrouter.ai), [Ollama](https://ollama.com), or [Google Colab](https://colab.research.google.com). No Anthropic API key required.

---

## Credits & Alternatives

- **[Anthropic Claude Code](https://github.com/anthropics/claude-code)** -- The official open-source CLI. This setup works directly with it.
- **[paoloanzn/free-code](https://github.com/paoloanzn/free-code)** -- The original free-code fork that strips telemetry, removes security-prompt guardrails, and unlocks all experimental features. This repo is based on their work.
- **[Gitlawb/openclaude](https://github.com/Gitlawb/openclaude)** -- Another excellent project for connecting Claude Code to any LLM. More mature multi-provider support. **Check this out if you want a polished, maintained solution.**

---

## Which Base Should You Use?

| Base | Telemetry | Guardrails | Experimental Features | Best For |
|---|---|---|---|---|
| **[Claude Code](https://github.com/anthropics/claude-code)** (official) | Yes | Yes | Limited | Users who want the official experience with free models |
| **[free-code](https://github.com/paoloanzn/free-code)** (paoloanzn) | Stripped | Removed | All 45+ unlocked | Users who want full control, zero callbacks home |

Both work with the setup described below. The patches in this repo are applied on top of free-code, but the environment variable configuration (Options A, B, C) works with official Claude Code as well -- just set the env vars and go.

---

## Important: Free vs. Paid Models

> **Free models work, but the experience is significantly worse than paid models.**

| | Free Models | Paid Models (Recommended) |
|---|---|---|
| **Response speed** | **Very slow (30 seconds to 15+ minutes per response)** | Fast (2-10 seconds per response) |
| **Rate limits** | Strict (10-20 req/min, often queued behind other users) | Generous or unlimited |
| **Reliability** | Models go offline without notice | Stable, SLA-backed |
| **Quality** | Good for simple tasks, struggles with complex multi-file refactoring | Excellent across all tasks |
| **Tool calling** | Inconsistent -- may produce malformed tool calls | Reliable, designed for agentic use |
| **Context handling** | Some models can't handle the ~55K system prompt | Large context windows, optimized |

### If you can afford it, use a paid model

Even a tiny budget eliminates the biggest pain points:

| Paid Option | Cost | What You Get |
|---|---|---|
| **OpenRouter with $5 credit** | ~$0.10-0.50 per coding session | Same models, no rate limits, 10-100x faster. **Best value.** |
| **Near-free models** (e.g., `z-ai/glm-4.7-flash`) | $0.06/M tokens (~$0.01 per session) | Practically free, no rate limits, fast responses |
| **Anthropic API key** | ~$0.50-2.00 per coding session | Best quality. Claude is the model Claude Code was built for. |

**The rest of this guide is for users who want a completely free setup.**

---

## Quick Start

### Prerequisites

- [Bun](https://bun.sh) >= 1.3.11 (runtime & bundler)
- macOS or Linux (Windows via WSL)
- A free [OpenRouter](https://openrouter.ai) account (or Anthropic API key, or Ollama)

```bash
# Install Bun if you don't have it
curl -fsSL https://bun.sh/install | bash
```

### Install & Build

```bash
# Clone this repo
git clone https://github.com/Kishore180994/free-code-2.git
cd free-code-2

# Install dependencies
bun install

# Build with all experimental features enabled
bun run build:dev:full    # produces ./cli-dev

# Add to your PATH
mkdir -p ~/.local/bin
cp cli-dev ~/.local/bin/free-code
chmod +x ~/.local/bin/free-code

# Verify
free-code --version
```

> **Alternative:** Use the one-liner install from the original [free-code](https://github.com/paoloanzn/free-code):
> ```bash
> curl -fsSL https://raw.githubusercontent.com/paoloanzn/free-code/main/install.sh | bash
> ```
> Then apply the env var configuration from the options below.

### Build Variants

| Command | Output | Features | Notes |
|---|---|---|---|
| `bun run build` | `./cli` | `VOICE_MODE` only | Production-like binary |
| `bun run build:dev` | `./cli-dev` | `VOICE_MODE` only | Dev version stamp |
| `bun run build:dev:full` | `./cli-dev` | All 45+ experimental flags | **Recommended.** The full unlock build. |

### Run

```bash
# Interactive mode (default)
free-code

# One-shot mode
free-code -p "what files are in this directory?"

# With a specific model
free-code --model qwen/qwen3-coder:free
```

### Using with Official Claude Code (no build needed)

If you prefer the official CLI, just install it and set the env vars:

```bash
npm install -g @anthropic-ai/claude-code
# Then configure the environment variables from Option A/B/C below
claude
```

The env var configuration works with both official Claude Code and this fork.

---

## Setup Options

### Option A: OpenRouter (Cloud Free Models) -- Recommended

[OpenRouter](https://openrouter.ai) provides an Anthropic-compatible API proxy with access to dozens of free models. No credit card required.

#### Step 1: Get an OpenRouter API Key

1. Go to [openrouter.ai](https://openrouter.ai) and create a free account
2. Navigate to [openrouter.ai/keys](https://openrouter.ai/keys)
3. Create a new API key (starts with `sk-or-v1-...`)

#### Step 2: Configure Environment

Add to your `~/.zshrc` (or `~/.bashrc`):

```bash
# --- free-code with OpenRouter (free models) ---
export OPENROUTER_API_KEY="sk-or-v1-YOUR_KEY_HERE"
export ANTHROPIC_BASE_URL="https://openrouter.ai/api"
export ANTHROPIC_API_KEY="$OPENROUTER_API_KEY"

# Main model -- code generation and complex tasks (free)
export ANTHROPIC_MODEL="qwen/qwen3-coder:free"
export ANTHROPIC_DEFAULT_OPUS_MODEL="qwen/qwen3-coder:free"
export ANTHROPIC_DEFAULT_SONNET_MODEL="qwen/qwen3-coder:free"

# Fast model -- quick classifications, subagents, lightweight tasks (near-free: $0.06/M tokens)
export ANTHROPIC_DEFAULT_HAIKU_MODEL="z-ai/glm-4.7-flash"
export ANTHROPIC_SMALL_FAST_MODEL="z-ai/glm-4.7-flash"
export CLAUDE_CODE_SUBAGENT_MODEL="z-ai/glm-4.7-flash"
```

> **Why two models?** free-code uses multiple model "slots" internally. Heavy slots handle code generation. Light slots handle quick tasks like classification. Using a fast, cheap model for light slots avoids wasting your free-tier rate limits on trivial requests.

Then: `source ~/.zshrc`

#### Step 3: Configure Settings

Edit `~/.claude/settings.json`:

```json
{
  "env": {
    "ANTHROPIC_MODEL": "qwen/qwen3-coder:free",
    "CLAUDE_CODE_SUBAGENT_MODEL": "z-ai/glm-4.7-flash",
    "ANTHROPIC_DEFAULT_OPUS_MODEL": "qwen/qwen3-coder:free",
    "ANTHROPIC_DEFAULT_SONNET_MODEL": "qwen/qwen3-coder:free",
    "ANTHROPIC_DEFAULT_HAIKU_MODEL": "z-ai/glm-4.7-flash",
    "ANTHROPIC_SMALL_FAST_MODEL": "z-ai/glm-4.7-flash"
  },
  "model": "qwen/qwen3-coder:free"
}
```

#### Step 4: Build & Run

**Using official Claude Code:**
```bash
npm install -g @anthropic-ai/claude-code
claude
```

**Using free-code:**
```bash
git clone https://github.com/paoloanzn/free-code.git
cd free-code
bun install && bun run build:dev:full
ln -sf "$(pwd)/cli-dev" ~/.local/bin/free-code
free-code
```

On first launch, it will ask **"Do you want to use this API key?"** -- select **Yes**.

#### Switching Models

Use `/model` inside the CLI to switch on the fly:
```
/model nvidia/nemotron-3-super-120b-a12b:free
/model qwen/qwen3-coder:free
/model z-ai/glm-4.7-flash
```

#### Recommended Free Models (OpenRouter)

| Model | Context | Best For | Notes |
|---|---|---|---|
| `qwen/qwen3-coder:free` | 262K | Coding tasks | **Recommended default.** Code-optimized. |
| `nvidia/nemotron-3-super-120b-a12b:free` | 262K | General reasoning | 120B MoE. Good fallback. |
| `qwen/qwen3.6-plus-preview:free` | 1M+ | Complex reasoning | Thinking model -- slow but capable. |
| `openai/gpt-oss-120b:free` | 131K | General tasks | OpenAI's open-source 120B. |
| `stepfun/step-3.5-flash:free` | 256K | Quick tasks | Fast responses. |
| `z-ai/glm-4.5-air:free` | 131K | General tasks | Free tier of GLM family. |

> **Context warning:** The system prompt + tools consume ~55K tokens. Models with <65K context will fail. Use 128K+ models.

#### Best-Value Paid Models (Near-Free)

| Model | Context | Cost per 1M tokens | Notes |
|---|---|---|---|
| `z-ai/glm-4.7-flash` | 202K | $0.06 in / $0.40 out | **Best value.** Fast, no rate limits. |
| `z-ai/glm-4-32b` | 128K | $0.10 / $0.10 | Cheapest completion cost. |
| `qwen/qwen3-coder` | 262K | ~$0.16 / $0.16 | Same as :free version, no rate limits. |

> **$5 of OpenRouter credit lasts weeks of heavy coding.**

---

### Option B: Ollama (Local Models, Fully Offline)

**Best for:** Mac Mini M2/M4 with 32GB+ RAM, or desktop with dedicated GPU. Fully private, zero API costs, unlimited usage.

#### Architecture

```
free-code  →  LiteLLM (localhost:4000)  →  Ollama (localhost:11434)
           (Anthropic API)            (OpenAI API)
```

#### Setup

```bash
# 1. Install
brew install ollama
pip install litellm[proxy]

# 2. Pull a model
ollama serve &
ollama pull qwen3:14b    # 16GB RAM minimum

# 3. Create LiteLLM config
cat > ~/litellm_config.yaml << 'EOF'
model_list:
  - model_name: "qwen3:14b"
    litellm_params:
      model: "ollama/qwen3:14b"
      api_base: "http://localhost:11434"
EOF

# 4. Start proxy
litellm --config ~/litellm_config.yaml --port 4000 &

# 5. Configure env (add to ~/.zshrc)
export ANTHROPIC_BASE_URL="http://localhost:4000"
export ANTHROPIC_API_KEY="sk-local-dummy"
export ANTHROPIC_MODEL="qwen3:14b"
# ... set all model slots to "qwen3:14b"

# 6. Run
free-code
```

#### Hardware Requirements

| Model Size | RAM | Recommended Hardware | Speed |
|---|---|---|---|
| 7-8B | 8 GB | Apple M1 | Usable, 10-30 tok/s |
| 14B | 16 GB | Apple M1 Pro | Moderate, 5-15 tok/s |
| **32B** | **32 GB** | **Mac Mini M4** | **Good quality + speed. Sweet spot.** |
| 70B+ | 64 GB+ | Apple M2 Ultra | Best quality, slower |

---

### Option C: Google Colab (Free GPU in the Cloud)

**Best for:** Testing larger models for free when you have limited local hardware. **Not recommended for daily use** due to session management overhead.

#### Architecture

```
free-code (your Mac)  →  Cloudflare Tunnel  →  LiteLLM (Colab)  →  Ollama (Colab, T4 GPU)
```

#### Colab Notebook Cells

**Cell 1:** Install Ollama
```python
!sudo apt-get install -y zstd && curl -fsSL https://ollama.com/install.sh | sh
```

**Cell 2:** Start Ollama
```python
import subprocess, time, os
os.environ["PATH"] += ":/usr/local/bin"
subprocess.Popen(["/usr/local/bin/ollama", "serve"])
time.sleep(3)
print("Ollama server started!")
```

**Cell 3:** Pull model (make sure you selected T4 GPU runtime first)
```python
!ollama pull qwen3:14b
```

**Cell 4:** Install LiteLLM
```python
!pip install litellm[proxy] -q
```

**Cell 5:** Write config
```python
%%writefile litellm_config.yaml
model_list:
  - model_name: "qwen/qwen3-coder:free"
    litellm_params:
      model: "ollama/qwen3:14b"
      api_base: "http://localhost:11434"
```

**Cell 6:** Start proxy + tunnel (this cell keeps running)
```python
import subprocess, time
subprocess.Popen(["litellm", "--config", "litellm_config.yaml", "--port", "4000"])
time.sleep(5)

!wget -q https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64 -O cloudflared
!chmod +x cloudflared
!./cloudflared tunnel --url http://localhost:4000
# Copy the URL: https://xxxx.trycloudflare.com
```

Then on your Mac:
```bash
export ANTHROPIC_BASE_URL="https://xxxx.trycloudflare.com"  # from Colab
```

#### Colab Limitations

| Issue | Details |
|---|---|
| **Session timeout** | Disconnects after ~90 min idle or ~12 hours max |
| **New URL each session** | Must update `ANTHROPIC_BASE_URL` every time |
| **GPU not guaranteed** | Free tier may give you CPU-only during peak hours |
| **Re-downloads model each session** | ~9GB download for 14B model every restart |
| **Network latency** | 200-500ms overhead per request |

> **Verdict:** Good for testing. Impractical for daily work. Use OpenRouter (Option A) instead.

---

## Source Code Patches (free-code only)

If using free-code (not official Claude Code), these patches bypass Anthropic-specific endpoints:

| File | Change |
|---|---|
| `src/services/api/client.ts` | Force `x-api-key` auth for third-party providers |
| `src/utils/auth.ts` | Accept API key without approval dialog |
| `src/services/tokenEstimation.ts` | Skip `/count_tokens` endpoint |
| `src/services/analytics/growthbook.ts` | Skip analytics init |
| `src/services/analytics/firstPartyEventLoggingExporter.ts` | Disable telemetry |
| `src/services/api/metricsOptOut.ts` | Skip metrics check |
| `src/services/mcp/officialRegistry.ts` | Skip MCP registry |
| `src/utils/telemetry/bigqueryExporter.ts` | Disable metrics export |

All patches use the same guard:
```typescript
const isThirdPartyProvider = process.env.ANTHROPIC_BASE_URL &&
  !process.env.ANTHROPIC_BASE_URL.includes('anthropic.com')
```

---

## TL;DR -- Which Option?

| Your Situation | Best Option | Why |
|---|---|---|
| **Can spend $5** | **OpenRouter + credit** | Same models, no rate limits, 10-100x faster |
| **Want completely free, have internet** | **Option A: OpenRouter free** | Easiest setup. Slow but works. |
| **Have Mac Mini M4 (32GB+)** | **Option B: Ollama** | Best free experience. Fast, offline, unlimited. |
| **Limited hardware (8GB RAM)** | **Option A: OpenRouter** | Can't run good local models. Cloud is better. |
| **Want to test larger models free** | **Option C: Colab** | Free T4 GPU. Impractical for daily use. |
| **Budget doesn't matter** | **Anthropic API** | Claude is the best model for Claude Code. |
---

## Recommended Plugins & Skills

Claude Code supports plugins that add specialized capabilities. Here are the plugins we use for the best experience:

### Official Plugins (claude-plugins-official)

Install with: `claude plugins install <name>@claude-plugins-official`

| Plugin | What It Does |
|---|---|
| `superpowers` | Parallel agents, brainstorming, plan execution, code review, TDD |
| `code-review` | Automated code quality review |
| `commit-commands` | Git commit, push, PR workflows |
| `pr-review-toolkit` | PR test analysis, comment review, code simplification |
| `frontend-design` | Frontend design assistance |
| `figma` | Figma design integration |
| `playwright` | Browser automation and testing |
| `typescript-lsp` | TypeScript language server integration |
| `pyright-lsp` | Python type checking |
| `swift-lsp` | Swift language server |
| `github` | GitHub integration |
| `Notion` | Notion page/database integration |
| `firebase` | Firebase project management |
| `supabase` | Supabase integration |
| `vercel` | Vercel deployment and AI SDK |
| `claude-code-setup` | Claude Code configuration assistance |
| `claude-md-management` | CLAUDE.md file management |
| `plugin-dev` | Plugin development tools |
| `skill-creator` | Create custom skills |
| `agent-sdk-dev` | Agent SDK development |
| `hookify` | Create hooks from conversation patterns |
| `security-guidance` | Security best practices |
| `ralph-loop` | Recurring task loops |
| `playground` | Interactive playground |
| `huggingface-skills` | HuggingFace model training, datasets, Gradio |

### Third-Party Plugins

| Plugin | Source | What It Does |
|---|---|---|
| `claude-api` | `anthropic-agent-skills` | Claude API / Anthropic SDK assistance |
| `document-skills` | `anthropic-agent-skills` | PDF, DOCX, XLSX, PPTX generation |
| `example-skills` | `anthropic-agent-skills` | Canvas design, web artifacts, MCP builder |
| `superpowers` | `superpowers-dev` | Enhanced agent capabilities (parallel, worktrees) |
| `obsidian` | `obsidian-skills` | Obsidian vault management |

### Installing Third-Party Marketplaces

```bash
# Add the Anthropic skills marketplace
claude plugins marketplace add anthropic-agent-skills --source git --url https://github.com/anthropics/skills.git

# Add Superpowers
claude plugins marketplace add superpowers-dev --source git --url https://github.com/obra/superpowers.git

# Add Obsidian skills
claude plugins marketplace add obsidian-skills --source git --url https://github.com/kepano/obsidian-skills.git
```

Then enable plugins:
```bash
claude plugins install superpowers@superpowers-dev
claude plugins install claude-api@anthropic-agent-skills
# etc.
```

> **Note:** Plugin availability and commands may vary between Claude Code versions. Some plugins require specific MCP servers or API access to function fully.


---

## License

The original Claude Code source is the property of Anthropic. This fork is based on [paoloanzn/free-code](https://github.com/paoloanzn/free-code). Use at your own discretion.
