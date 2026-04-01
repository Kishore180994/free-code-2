# free-code Architecture Deep Dive

A comprehensive technical walkthrough of the free-code (Claude Code) codebase -- how every subsystem works, how data flows from keystroke to API response, and how the pieces connect.

```
                          ┌─────────────────────────────────────────────────────┐
                          │                   free-code CLI                     │
                          │                                                     │
                          │  ┌───────────┐   ┌──────────────┐   ┌───────────┐  │
                          │  │ Commands  │   │  QueryEngine │   │   Tools   │  │
                          │  │ (104 cmds)│   │  (core loop) │   │ (48 tools)│  │
                          │  └─────┬─────┘   └──────┬───────┘   └─────┬─────┘  │
                          │        │                │                  │        │
                          │        ▼                ▼                  ▼        │
                          │  ┌─────────────────────────────────────────────┐    │
                          │  │              App State Store                │    │
                          │  │         (messages, tasks, config)           │    │
                          │  └──────────────────┬──────────────────────────┘    │
                          │                     │                               │
                          │  ┌──────────────────┼──────────────────────────┐    │
                          │  │                  │                          │    │
                          │  ▼                  ▼                          ▼    │
                          │  ┌──────┐    ┌────────────┐    ┌────────────────┐   │
                          │  │  UI  │    │  API Layer │    │  MCP Clients   │   │
                          │  │ (Ink)│    │ (Anthropic │    │ (stdio/SSE/WS) │   │
                          │  │      │    │  SDK)      │    │                │   │
                          │  └──────┘    └─────┬──────┘    └────────────────┘   │
                          │                    │                                │
                          └────────────────────┼────────────────────────────────┘
                                               │
                                               ▼
                                    ┌──────────────────────┐
                                    │   LLM Provider API   │
                                    │  (Anthropic/OpenRouter│
                                    │   /Ollama+LiteLLM)   │
                                    └──────────────────────┘
```

---

## Table of Contents

1. [Bootstrap & Startup Sequence](#1-bootstrap--startup-sequence)
2. [REPL & Main Loop](#2-repl--main-loop)
3. [Query Engine (The Brain)](#3-query-engine-the-brain)
4. [API Layer](#4-api-layer)
5. [Tool System](#5-tool-system)
6. [Command System](#6-command-system)
7. [MCP Integration](#7-mcp-model-context-protocol-integration)
8. [State Management](#8-state-management)
9. [UI Layer (Ink/React Terminal)](#9-ui-layer-inkreact-terminal)
10. [Authentication System](#10-authentication-system)
11. [Model System](#11-model-system)
12. [Plugin System](#12-plugin-system)
13. [Skill System](#13-skill-system)
14. [Hook System](#14-hook-system)
15. [Voice Mode](#15-voice-mode)
16. [Bridge Mode (IDE Integration)](#16-bridge-mode-ide-integration)
17. [Configuration System](#17-configuration-system)
18. [Build System & Feature Flags](#18-build-system--feature-flags)
19. [Session Architecture](#19-session-architecture)
20. [Data Flow Diagrams](#20-data-flow-diagrams)
21. [Key Dependencies](#21-key-dependencies)
22. [Performance Optimizations](#22-performance-optimizations)

---

## 1. Bootstrap & Startup Sequence

**Entry Point:** `src/entrypoints/cli.tsx`
**Main Orchestrator:** `src/main.tsx` (~585 lines)

The startup is a carefully sequenced pipeline designed to minimize time-to-first-prompt. Expensive operations (keychain reads, auth token refresh, MCP connections) run in parallel wherever possible.

### Boot Sequence

```
cli.tsx (entry point)
  │
  ├── --version? → Print version, exit (zero module loading)
  ├── --dump-system-prompt? → Print system prompt, exit
  ├── --daemon-worker? → Spawn background daemon
  ├── bridge/remote-control? → Enter Bridge mode
  │
  └── main()
       │
       ├── Phase 1: Parallel Prefetch (~65ms overlap)
       │   ├── startMdmRawRead()        ← macOS MDM policy prefetch
       │   └── startKeychainPrefetch()   ← Overlap keychain I/O with init
       │
       ├── Phase 2: Core Init
       │   ├── enableConfigs()           ← Load settings.json, CLAUDE.md
       │   ├── applyManagedEnvironment() ← Apply env overrides from settings
       │   └── initTelemetry()           ← (skipped for third-party providers)
       │
       ├── Phase 3: Auth & Model Resolution
       │   ├── resolveAuthMethod()       ← API key vs OAuth vs cloud creds
       │   ├── resolveModel()            ← ANTHROPIC_MODEL env → settings → default
       │   └── initGrowthBook()          ← Feature flags (skipped for third-party)
       │
       ├── Phase 4: Deferred Prefetches (async, non-blocking)
       │   ├── prefetchOfficialMcpUrls() ← MCP registry warmup
       │   ├── refreshOAuthTokens()      ← Token refresh if needed
       │   └── loadTips()                ← Usage tips for UI
       │
       ├── Phase 5: Plugin & MCP Loading
       │   ├── initBundledPlugins()      ← Compile-time bundled plugins
       │   ├── loadExternalPlugins()     ← ~/.claude/plugins/
       │   └── connectMCPServers()       ← Establish MCP connections
       │
       └── Phase 6: Launch REPL
            └── launchRepl()             ← Render Ink app, start interaction loop
```

### Startup Profiling

Every phase is instrumented with `profileCheckpoint()` calls, visible with `--debug`:

```
[  12ms] keychain-prefetch-start
[  15ms] configs-loaded
[  48ms] auth-resolved
[  65ms] keychain-prefetch-complete (overlapped)
[  72ms] growthbook-init
[ 120ms] mcp-connected
[ 135ms] repl-launched
```

### Fast Paths

The CLI has several "fast paths" that skip most initialization:

| Flag | Skips | Time |
|------|-------|------|
| `--version` | Everything | <10ms |
| `--dump-system-prompt` | Auth, MCP, UI | ~50ms |
| `-p "prompt"` | REPL, some UI | ~100ms + API time |
| `--bare` | Plugins, OAuth, keychain | ~80ms |

---

## 2. REPL & Main Loop

**Location:** `src/replLauncher.tsx`, `src/screens/REPL.tsx`

The REPL (Read-Eval-Print Loop) is a React component rendered by Ink into the terminal.

### REPL Architecture

```
┌─────────────────────────────────────────────────┐
│                    REPL.tsx                       │
│                                                   │
│  ┌─────────────┐  ┌──────────────────────────┐   │
│  │ Input Buffer │  │    Message History        │   │
│  │ (user typing)│  │ (rendered conversation)   │   │
│  └──────┬──────┘  └──────────────────────────┘   │
│         │                                         │
│         ▼                                         │
│  ┌──────────────┐                                │
│  │processUserInput                               │
│  │              │                                │
│  │ /command?  ──┼──→ Command.action()            │
│  │ free text? ──┼──→ QueryEngine.ask()           │
│  │ @agent?   ──┼──→ AgentTool dispatch           │
│  └──────────────┘                                │
│         │                                         │
│         ▼                                         │
│  ┌──────────────────────────────────────────┐    │
│  │        StreamEvent[] rendering            │    │
│  │  (progressive token display via Ink)      │    │
│  └──────────────────────────────────────────┘    │
└─────────────────────────────────────────────────┘
```

### Input Processing

User input goes through several layers:

1. **Keybinding layer** — `useGlobalKeybindings()` intercepts hotkeys (Ctrl+C, Ctrl+O, etc.)
2. **History layer** — `useArrowKeyHistory()` navigates previous inputs
3. **Routing layer** — Determines if input is a `/command`, `@mention`, or free-form query
4. **Dispatch** — Routes to appropriate handler

### Render Cycle

The terminal UI re-renders on:
- New streaming tokens from the API
- Tool execution progress updates
- User input changes
- State transitions (thinking → responding → idle)
- Notification events

---

## 3. Query Engine (The Brain)

**Location:** `src/QueryEngine.ts` (~1186 lines)

The QueryEngine is the central orchestrator. It assembles prompts, manages the conversation loop, executes tools, handles context compaction, and coordinates with the API layer.

### Core Type

```typescript
export type QueryEngineConfig = {
  cwd: string                        // Working directory
  tools: Tools                       // Available tool set
  commands: Command[]                // Registered slash commands
  mcpClients: MCPServerConnection[]  // Active MCP connections
  agents: AgentDefinition[]          // Agent presets
  canUseTool: CanUseToolFn           // Permission gate
  getAppState: () => AppState        // State reader
  setAppState: (fn) => void          // State updater
  readFileCache: FileStateCache      // File content cache
  customSystemPrompt?: string        // Override system prompt
  thinkingConfig?: ThinkingConfig    // Extended thinking settings
  maxTurns?: number                  // Auto-stop after N turns
  maxBudgetUsd?: number              // Cost limit
  // ... 20+ more config options
}
```

### The Query Loop

The `ask()` method is an **async generator** that yields `StreamEvent[]` arrays. This is the heart of the entire application:

```
ask(userMessage)
  │
  ├── 1. Assemble System Prompt
  │   ├── fetchSystemPromptParts()
  │   ├── Inject tool schemas
  │   ├── Inject CLAUDE.md content
  │   ├── Inject MCP resource context
  │   └── Inject skill context (if active)
  │
  ├── 2. Normalize Messages
  │   ├── normalizeMessagesForAPI()
  │   ├── Apply token budget constraints
  │   └── Trim if exceeding context window
  │
  ├── 3. API Call (streaming)
  │   ├── query() → stream deltas
  │   ├── Process content_block_delta events
  │   ├── Accumulate text + tool_use blocks
  │   └── yield StreamEvent[] (text chunks)
  │
  ├── 4. Tool Execution (if tool_use blocks present)
  │   ├── Extract tool calls from response
  │   ├── canUseTool() permission check
  │   │   ├── Auto-allow (always-allow rules)
  │   │   ├── Auto-deny (always-deny rules)
  │   │   └── Prompt user (interactive approval)
  │   ├── runTools() — execute in parallel
  │   ├── Serialize ToolResult into user message
  │   └── yield StreamEvent[] (tool progress)
  │
  ├── 5. Continuation Check
  │   ├── stop_reason === 'end_turn'? → Done
  │   ├── stop_reason === 'tool_use'? → Loop back to step 3
  │   ├── stop_reason === 'max_tokens'? → Auto-continue
  │   └── Max turns exceeded? → Stop
  │
  └── 6. Context Compaction (if needed)
      ├── Token count approaching limit?
      ├── Auto-compact: summarize older messages
      ├── Microcompact: cached boundary optimization
      └── Snip: aggressive history compression
```

### Context Compaction Strategies

When the conversation approaches the model's context limit, the QueryEngine employs several strategies:

| Strategy | Trigger | Behavior |
|----------|---------|----------|
| **Auto-compact** | Token warning threshold | Summarize older messages into a condensed form |
| **Microcompact** | Cached boundary detected | Optimize around prompt cache boundaries |
| **Snip** | HISTORY_SNIP flag | Aggressively remove old turns |
| **Tool result budget** | Individual tool result too large | Truncate large tool outputs |

### Extended Thinking

When enabled (ULTRATHINK or model supports it):

```
Standard:     [system] [messages] → [response]
Thinking:     [system] [messages] → [thinking tokens...] → [response]
                                     ↑ not billed as output
                                     ↑ provides reasoning chain
```

---

## 4. API Layer

**Location:** `src/services/api/` (22 modules)

### Module Map

```
src/services/api/
├── claude.ts (125KB)              ← Main API orchestrator
├── client.ts                       ← HTTP client factory
├── errors.ts                       ← Error classification & recovery
├── withRetry.ts                    ← Retry strategy (exponential backoff)
├── logging.ts                      ← Request/response metrics
├── bootstrap.ts                    ← Initial connectivity check
├── filesApi.ts                     ← File upload/download API
├── grove.ts                        ← Grove integration
├── metricsOptOut.ts                ← Usage metrics opt-out
├── promptCacheBreakDetection.ts    ← Cache invalidation heuristics
├── sessionIngress.ts               ← Session management API
├── tokenEstimation.ts              ← Token count estimation
└── ...
```

### Client Creation

```typescript
// src/services/api/client.ts

function createApiClient(model: string): Anthropic {
  // 1. Detect provider
  const provider = getAPIProvider()  // 'firstParty' | 'bedrock' | 'vertex' | ...

  // 2. Provider-specific client
  if (provider === 'bedrock') return new AnthropicBedrock(bedrockArgs)
  if (provider === 'vertex')  return new AnthropicVertex(vertexArgs)

  // 3. Standard Anthropic client
  const isThirdParty = process.env.ANTHROPIC_BASE_URL &&
    !process.env.ANTHROPIC_BASE_URL.includes('anthropic.com')

  return new Anthropic({
    apiKey: (isClaudeAISubscriber() && !isThirdParty) ? null : apiKey,
    authToken: (isClaudeAISubscriber() && !isThirdParty) ? oauthToken : undefined,
    // baseURL derived from ANTHROPIC_BASE_URL or default
  })
}
```

### Request Flow

```
createApiClient()
  │
  ├── Assemble headers
  │   ├── x-api-key (API key auth)
  │   ├── Authorization: Bearer (OAuth)
  │   ├── anthropic-version: 2023-06-01
  │   └── anthropic-beta: [feature betas]
  │
  ├── Build request body
  │   ├── model: string
  │   ├── messages: Message[]
  │   ├── system: SystemPrompt
  │   ├── tools: ToolSchema[]
  │   ├── max_tokens: number
  │   └── stream: true
  │
  ├── POST /v1/messages?beta=true
  │   (URL = ANTHROPIC_BASE_URL + /v1/messages)
  │
  ├── Stream SSE events
  │   ├── message_start
  │   ├── content_block_start
  │   ├── content_block_delta (text, tool_use, thinking)
  │   ├── content_block_stop
  │   └── message_stop
  │
  └── Error handling
      ├── 401 → Auth error (re-auth flow)
      ├── 429 → Rate limit (backoff + retry)
      ├── 500 → Server error (retry with backoff)
      └── Network → ConnectionRefused, timeout (retry)
```

### Error Recovery

```typescript
// src/services/api/withRetry.ts
// Implements exponential backoff with jitter

async function withRetry<T>(
  fn: () => Promise<T>,
  options: {
    maxRetries: number        // Default: 3
    baseDelayMs: number       // Default: 1000
    maxDelayMs: number        // Default: 30000
    retryableStatuses: number[] // [429, 500, 502, 503, 529]
  }
): Promise<T>
```

### Token Estimation

```typescript
// src/services/tokenEstimation.ts
// Calls /count_tokens endpoint for accurate counts
// PATCHED: Skips for third-party providers (OpenRouter, etc.)

const baseUrl = process.env.ANTHROPIC_BASE_URL || ''
if (baseUrl && !baseUrl.includes('anthropic.com')) {
  return null  // Skip — endpoint not supported
}
```

---

## 5. Tool System

**Location:** `src/Tool.ts`, `src/tools.ts`, `src/tools/*/`

The tool system is how the LLM interacts with the outside world. There are 48 tools organized into categories.

### Tool Registry

```
src/tools/
├── BashTool/           ← Shell command execution
├── FileReadTool/       ← Read file contents
├── FileWriteTool/      ← Create/overwrite files
├── FileEditTool/       ← Surgical text replacements
├── GlobTool/           ← File pattern matching
├── GrepTool/           ← Content search (ripgrep)
├── WebSearchTool/      ← Web search
├── WebFetchTool/       ← HTTP fetch
├── AgentTool/          ← Spawn sub-agents
├── SkillTool/          ← Invoke skills
├── MCPTool/            ← MCP server tool calls
├── NotebookEditTool/   ← Jupyter notebook editing
├── TodoWriteTool/      ← Task tracking
├── BriefTool/          ← Summary generation
├── LSPTool/            ← Language Server Protocol
├── Task{Create,Get,List,Update,Stop,Output}Tool/  ← Background tasks
├── EnterWorktreeTool/  ← Git worktree isolation
├── ExitWorktreeTool/   ← Leave worktree
├── EnterPlanModeTool/  ← Planning mode (read-only)
├── ExitPlanModeV2Tool/ ← Exit planning mode
├── SleepTool/          ← Background agent sleep
├── RemoteTriggerTool/  ← Remote agent triggers
├── ScheduleCronTool/   ← Cron job scheduling
├── SendMessageTool/    ← Inter-agent messaging
├── AskUserQuestionTool/ ← Prompt user for input
├── ConfigTool/         ← Runtime config changes
├── ToolSearchTool/     ← Search available tools
└── ...
```

### Tool Interface

```typescript
export type Tool = {
  name: string
  description: string
  inputSchema: {
    type: 'object'
    properties: Record<string, JSONSchema>
    required?: string[]
  }
  // Execution function
  execute: (input: ToolInput, context: ToolContext) => Promise<ToolResult>
  // Optional streaming executor
  streamingExecute?: (input, context) => AsyncGenerator<ToolProgressEvent>
}

export type ToolResult = {
  success: boolean
  output: string
  error?: string
  metadata?: Record<string, unknown>
}
```

### Tool Execution Pipeline

```
LLM response contains tool_use block
  │
  ├── 1. Parse tool name + input from content block
  │
  ├── 2. Permission Check
  │   ├── canUseTool(toolName, input) →
  │   │   ├── ALLOW (always-allow rules match)
  │   │   ├── DENY (always-deny rules match)
  │   │   ├── ASK (show approval dialog)
  │   │   └── CLASSIFY (BASH_CLASSIFIER: ML-assisted)
  │   │
  │   └── If denied → return error ToolResult
  │
  ├── 3. Execute Tool
  │   ├── Find tool handler by name
  │   ├── Validate input against inputSchema
  │   ├── Run execute() or streamingExecute()
  │   └── Capture output, errors, timing
  │
  ├── 4. Result Processing
  │   ├── applyToolResultBudget() → truncate large outputs
  │   ├── Serialize to tool_result content block
  │   └── Append to message history
  │
  └── 5. Continue Loop
      └── Send tool results back to LLM for next response
```

### Parallel Tool Execution

When multiple tools are called in a single response, they execute in parallel:

```typescript
// Simplified from runTools()
const toolCalls = extractToolUseBlocks(assistantMessage)
const results = await Promise.all(
  toolCalls.map(call => executeToolWithPermission(call))
)
// All results sent back in a single user message
```

### Permission System Deep Dive

The `useCanUseTool` hook (40KB) implements a sophisticated permission model:

```
Tool Call
  │
  ├── Check always-allow rules (settings.json)
  │   └── Match tool name + input patterns
  │
  ├── Check always-deny rules
  │   └── Match tool name + input patterns
  │
  ├── Check session approvals (approved this session)
  │
  ├── BASH_CLASSIFIER flag?
  │   └── ML model classifies bash command risk
  │       ├── Low risk → auto-allow
  │       ├── Medium risk → show warning
  │       └── High risk → require approval
  │
  └── Interactive prompt
      ├── "Allow once"
      ├── "Allow for session"
      ├── "Always allow (add to rules)"
      └── "Deny"
```

---

## 6. Command System

**Location:** `src/commands.ts`, `src/commands/*/`

### Command Registry (104 commands)

Commands are registered in `getCommands()` and invoked via `/command-name` in the REPL.

```
Core Commands
├── /init            ← Project setup wizard
├── /login           ← Authenticate (OAuth / API key)
├── /logout          ← Clear credentials
├── /status          ← Show session info, model, usage
├── /help            ← List available commands
├── /config          ← View/edit settings
├── /model           ← Switch models
├── /compact         ← Force context compaction
├── /clear           ← Clear conversation history
├── /cost            ← Show token usage and cost

Git Integration
├── /commit          ← Analyze changes and commit
├── /commit-push-pr  ← Commit + push + create PR
├── /review          ← Code review current changes

Agent & Task Management
├── /agents          ← List/manage agent presets
├── /skills          ← Browse available skills
├── /mcp             ← Manage MCP server connections
├── /tasks           ← View background tasks

IDE & Bridge
├── /ide             ← Open in VS Code / JetBrains
├── /bridge          ← Start IDE bridge mode
├── /remote-control  ← Remote machine control

Advanced
├── /ultrathink      ← Enable extended thinking
├── /ultraplan       ← Multi-agent planning (ULTRAPLAN flag)
├── /voice           ← Toggle voice mode (VOICE_MODE flag)
├── /teleport        ← Migrate session to another machine
└── /context         ← Visualize token usage
```

### Command Interface

```typescript
export type Command = {
  name: string
  alias?: string[]         // Alternative names
  description: string      // Shown in /help
  isHidden?: boolean       // Exclude from /help listing
  isEnabled?: () => boolean // Feature flag gate
  action: (args: string, context: CommandContext) => Promise<void>
}
```

---

## 7. MCP (Model Context Protocol) Integration

**Location:** `src/services/mcp/` (25 modules)

MCP allows free-code to connect to external tool servers (databases, APIs, custom tools) using a standardized protocol.

### Architecture

```
~/.claude/mcp.json (config)
  │
  ├── Server definitions
  │   ├── name, command, args, env
  │   ├── transport: "stdio" | "sse" | "ws"
  │   └── auth: OAuth config (optional)
  │
  ▼
MCPServerConnection (per server)
  │
  ├── 1. Spawn / Connect
  │   ├── stdio: child_process.spawn()
  │   ├── SSE: HTTP EventSource
  │   └── WebSocket: ws connection
  │
  ├── 2. Initialize (JSON-RPC)
  │   ├── Send: initialize { capabilities }
  │   └── Recv: serverInfo, capabilities
  │
  ├── 3. Discover
  │   ├── tools/list → register in Tool registry
  │   ├── resources/list → prefetch resources
  │   └── prompts/list → register prompt templates
  │
  └── 4. Runtime
      ├── Tool invocation via MCPTool
      ├── Resource reads via ReadMcpResourceTool
      ├── Elicitation handling (user input requests)
      └── Auth flows (OAuth popup/redirect)
```

### MCP Config Format

```json
// ~/.claude/mcp.json
{
  "mcpServers": {
    "my-database": {
      "command": "npx",
      "args": ["-y", "@modelcontextprotocol/server-postgres"],
      "env": {
        "DATABASE_URL": "postgres://..."
      }
    },
    "remote-api": {
      "url": "https://api.example.com/mcp",
      "transport": "sse",
      "auth": {
        "type": "oauth",
        "clientId": "...",
        "scopes": ["read", "write"]
      }
    }
  }
}
```

### Module Breakdown

| Module | Role |
|--------|------|
| `client.ts` | MCPServerConnection lifecycle management |
| `config.ts` | Parse mcp.json, merge enterprise configs |
| `auth.ts` | OAuth/auth flow orchestration |
| `xaa.ts` | Cross-account auth support |
| `claudeai.ts` | Fetch official MCP server configs |
| `elicitationHandler.ts` | Handle user-input-request from servers |
| `officialRegistry.ts` | Prefetch known MCP server URLs |
| `useManageMCPConnections.tsx` | React hook for connection lifecycle |

---

## 8. State Management

**Location:** `src/state/` (6 modules)

### Store Architecture

The app uses a Zustand-like reactive store pattern:

```typescript
// src/state/AppStateStore.ts

export type AppState = {
  // Conversation
  messages: Message[]
  pendingToolCalls: ToolCall[]

  // Tasks
  tasks: TaskState[]
  backgroundAgents: AgentState[]

  // Session
  sessionId: string
  mode: 'interactive' | 'print' | 'plan'
  speed: 'standard' | 'fast'

  // Permissions
  toolPermissionContext: ToolPermissionContext
  sessionApprovals: Map<string, boolean>

  // UI
  notifications: Notification[]
  statusLine: StatusLineState

  // Speculation
  speculations?: SpeculationState

  // ... 40+ more fields
}
```

### State Flow

```
User Action / API Event
  │
  ├── setAppState(prev => ({ ...prev, messages: [...prev.messages, newMsg] }))
  │
  ├── State change triggers React re-render (Ink)
  │
  └── Listeners notified via onChangeAppState()
      ├── Transcript recording
      ├── Usage tracking
      └── Background task coordination
```

### State Persistence

```
In-Memory (AppState)
  │
  ├── Transcript → ~/.claude/sessions/{sessionId}.jsonl
  ├── Settings  → ~/.claude/settings.json
  ├── Config    → ~/.claude/config/
  └── Messages  → Serialized for session resume
```

---

## 9. UI Layer (Ink/React Terminal)

**Location:** `src/ink/` (52 modules), `src/components/` (148 components)

### Technology Stack

| Library | Version | Role |
|---------|---------|------|
| React | 19.2.4 | Component framework |
| Ink | 6.8.0 | React → Terminal renderer |
| Reconciler | 0.33 | Custom React reconciler for terminal |

### Component Hierarchy

```
<App>                              ← Root wrapper, providers
  <REPL>                           ← Main interaction screen
    ├── <MessageHistory>            ← Scrollable message list
    │   ├── <UserMessage>           ← User input display
    │   ├── <AssistantTextMessage>  ← LLM text response
    │   ├── <ToolProgressLine>      ← Tool execution status
    │   │   ├── "⠋ Reading file..."
    │   │   ├── "✓ Read 42 lines from src/main.ts"
    │   │   └── "✗ Permission denied"
    │   ├── <AgentProgressLine>     ← Sub-agent status
    │   └── <ThinkingIndicator>     ← Extended thinking animation
    │
    ├── <StatusLine>                ← Bottom status bar
    │   ├── Model name
    │   ├── Token usage
    │   ├── Cost (if API key)
    │   └── Mode indicator
    │
    ├── <InputArea>                 ← Text input with history
    │   ├── Multi-line editing
    │   ├── Tab completion
    │   └── Slash command autocomplete
    │
    └── <NotificationArea>          ← Toasts, warnings
```

### Terminal Capabilities

```
src/ink/
├── termio/              ← Low-level terminal I/O
│   ├── Cursor.ts        ← ANSI cursor control (move, hide, show)
│   ├── Screen.ts        ← Screen buffer management
│   └── Input.ts         ← Raw keystroke reading
│
├── ansiToPng.ts (215KB) ← Convert ANSI output to PNG images
├── ansiToSvg.ts         ← Convert ANSI output to SVG
│
├── components/          ← Reusable terminal widgets
│   ├── Box.tsx          ← Flexbox layout for terminal
│   ├── Text.tsx         ← Styled text rendering
│   ├── Spinner.tsx      ← Loading animations
│   └── Select.tsx       ← Interactive selection menus
│
└── hooks/               ← Terminal-specific hooks
    ├── useStdout.ts     ← Stdout stream access
    ├── useStdin.ts      ← Stdin stream access
    └── useFocus.ts      ← Focus management
```

### Streaming Render Pipeline

```
SSE delta event (API)
  │
  ├── content_block_delta { type: "text_delta", text: "Hello" }
  │
  ├── Accumulate in message buffer
  │
  ├── yield StreamEvent.TextDelta("Hello")
  │
  ├── REPL receives event
  │
  ├── setAppState(prev => updateMessage(prev, delta))
  │
  ├── React reconciler diffs virtual tree
  │
  └── Ink writes diff to terminal stdout
      (only changed characters re-rendered)
```

---

## 10. Authentication System

**Location:** `src/utils/auth.ts` (~65KB, ~2000 lines)

### Auth Methods

```
┌───────────────────────────────────────────────────────────┐
│                    Auth Resolution                         │
│                                                           │
│  Priority (highest to lowest):                            │
│                                                           │
│  1. CLI flags (--api-key, --oauth-token)                  │
│  2. ANTHROPIC_API_KEY env var                             │
│  3. Third-party provider detection (ANTHROPIC_BASE_URL)   │
│  4. OAuth tokens (keychain / config file)                 │
│  5. API key from apiKeyHelper command                     │
│  6. Cloud provider creds (Bedrock/Vertex/Foundry)         │
│  7. No auth → prompt /login                               │
└───────────────────────────────────────────────────────────┘
```

### Key Functions

```typescript
// Determine auth mode
isAnthropicAuthEnabled()    // false for 3P providers → no OAuth
isClaudeAISubscriber()      // false for API key users
getAPIProvider()            // 'firstParty' | 'bedrock' | 'vertex' | ...

// Get credentials
getAnthropicApiKey()        // ANTHROPIC_API_KEY or keychain
getAnthropicApiKeyWithSource() // Returns { key, source } tuple
getClaudeAIOAuthTokens()    // OAuth access/refresh tokens

// Cloud providers
refreshAndGetAwsCredentials()      // Bedrock auth
refreshGcpCredentialsIfNeeded()    // Vertex auth
```

### Third-Party Provider Auth (Patched)

For non-Anthropic providers (OpenRouter, LiteLLM, etc.):

```typescript
// src/utils/auth.ts — PATCHED
const isThirdPartyProvider = process.env.ANTHROPIC_BASE_URL &&
  !process.env.ANTHROPIC_BASE_URL.includes('anthropic.com')

if (isThirdPartyProvider && apiKeyEnv) {
  return { key: apiKeyEnv, source: 'ANTHROPIC_API_KEY' }
  // Skip approval dialog, skip OAuth, use key directly
}
```

### Token Storage

| Platform | Storage | Security |
|----------|---------|----------|
| macOS | Keychain (`security` CLI) | Hardware-backed encryption |
| Linux | Secret Service (DBus) | Desktop keyring |
| Fallback | `~/.config/claude/auth.json` | File permissions only |

---

## 11. Model System

**Location:** `src/utils/model/` (18 modules)

### Model Resolution Chain

```
Model Selection Priority:
  │
  ├── 1. CLI flag: --model "model-name"
  ├── 2. Environment: ANTHROPIC_MODEL
  ├── 3. Settings: ~/.claude/settings.json → "model"
  ├── 4. Settings: ~/.claude/settings.json → env.ANTHROPIC_MODEL
  └── 5. Default: claude-sonnet-4-6 (hardcoded)
```

### Model Slot System

free-code uses multiple "model slots" for different purposes:

| Slot | Env Var | Purpose |
|------|---------|---------|
| Main | `ANTHROPIC_MODEL` | Primary conversation model |
| Opus | `ANTHROPIC_DEFAULT_OPUS_MODEL` | High-capability tasks |
| Sonnet | `ANTHROPIC_DEFAULT_SONNET_MODEL` | Balanced tasks |
| Haiku | `ANTHROPIC_DEFAULT_HAIKU_MODEL` | Fast/cheap tasks |
| Small/Fast | `ANTHROPIC_SMALL_FAST_MODEL` | Permission classification, quick ops |
| Subagent | `CLAUDE_CODE_SUBAGENT_MODEL` | Background agent spawning |

### Provider Detection

```typescript
// src/utils/model/providers.ts

export function getAPIProvider(): APIProvider {
  // Returns: 'firstParty' | 'bedrock' | 'vertex' | 'foundry' | ...

  if (process.env.ANTHROPIC_BEDROCK_BASE_URL) return 'bedrock'
  if (process.env.ANTHROPIC_VERTEX_PROJECT_ID) return 'vertex'
  if (process.env.ANTHROPIC_FOUNDRY_RESOURCE) return 'foundry'
  // ... more provider detection

  return 'firstParty'  // Default: direct Anthropic API
}

export function isFirstPartyAnthropicBaseUrl(): boolean {
  const baseUrl = process.env.ANTHROPIC_BASE_URL
  if (!baseUrl) return true  // Default is Anthropic
  const host = new URL(baseUrl).host
  return host === 'api.anthropic.com'
}
```

### Model Capabilities

```typescript
// src/utils/model/modelCapabilities.ts

export function getContextWindowForModel(model: string): number
export function getModelMaxOutputTokens(model: string): number
export function supportsExtendedThinking(model: string): boolean
export function supportsVision(model: string): boolean
export function supportsCaching(model: string): boolean
```

---

## 12. Plugin System

**Location:** `src/plugins/` (4 modules + `bundled/`)

### Plugin Architecture

```
Plugin Sources
├── Bundled (compiled into binary)
│   └── src/plugins/bundled/
│
├── User Plugins
│   └── ~/.claude/plugins/
│
└── Project Plugins
    └── .claude/plugins/

Plugin Structure
├── PLUGIN.md            ← Metadata (name, version, description)
├── package.json         ← Dependencies
├── index.ts             ← Main export
├── tools/               ← Custom tool implementations
├── commands/            ← Custom slash commands
├── hooks/               ← Lifecycle hooks
│   └── hooks.json       ← Hook configuration
├── skills/              ← Bundled skills
└── agents/              ← Agent definitions
```

### Plugin Lifecycle

```
1. Discovery
   ├── Scan bundled/ directory
   ├── Scan ~/.claude/plugins/
   └── Scan .claude/plugins/ (project-level)

2. Validation
   ├── Parse PLUGIN.md frontmatter
   ├── Verify package.json
   └── Check compatibility

3. Loading
   ├── Import index.ts
   ├── Register tools → global Tool registry
   ├── Register commands → Command registry
   └── Register hooks → Hook system

4. Runtime
   ├── Tools available to LLM via tool_use
   ├── Commands available via /command
   └── Hooks fire on lifecycle events
```

---

## 13. Skill System

**Location:** `src/skills/` (3 modules + `bundled/`)

Skills are markdown-based knowledge injections that provide context to the LLM.

### Skill Format

```markdown
<!-- SKILL.md -->
---
name: my-skill
description: How to use the FooBar API
filePattern: "**/*.foo"
bashPattern: "foo-cli.*"
priority: 10
---

# FooBar API Guide

When working with FooBar files, always...
```

### Skill Matching

```
User invokes a tool (Read, Edit, Bash, etc.)
  │
  ├── PreToolUse hook fires
  │
  ├── Match tool target against skill patterns
  │   ├── File tools: match file_path against filePattern (glob)
  │   └── Bash tool: match command against bashPattern (regex)
  │
  ├── Rank matches by priority (descending)
  │
  ├── Cap at MAX_SKILLS (3) within byte budget (18KB)
  │
  ├── Dedup (each skill injected once per session)
  │
  └── Inject SKILL.md content as additionalContext
```

### Invocation Methods

1. **Automatic** — Pattern matching on tool use (above)
2. **Explicit** — `/skill-name` slash command
3. **LLM-initiated** — SkillTool invocation

---

## 14. Hook System

**Location:** `src/hooks/` (87 modules)

React hooks power most of the interactive behavior. These are terminal-UI hooks, not to be confused with plugin hooks (lifecycle events).

### Hook Categories

```
Permission Hooks
├── useCanUseTool.tsx (40KB)     ← Tool permission gating
├── toolPermission/              ← Permission rule evaluation
│   ├── alwaysAllow.ts
│   ├── alwaysDeny.ts
│   └── classifier.ts (BASH_CLASSIFIER)

Input Hooks
├── useArrowKeyHistory.ts        ← Navigate input history
├── useGlobalKeybindings.ts      ← Ctrl+C, Ctrl+O, etc.
├── useInputBuffer.ts            ← Circular buffer for typing

IDE Hooks
├── useIDEIntegration.ts         ← VS Code / JetBrains bridge
├── useDiffInIDE.ts              ← Open diffs in editor

State Hooks
├── useAppState.ts               ← Access AppState store
├── useSettingsChange.ts         ← React to settings changes
├── useDiagnostics.ts            ← /context command data

Notification Hooks
├── useClaudeCodeHintRecommendation.ts  ← Usage tips
├── useChromeExtensionNotification.ts   ← Browser extension
├── useCompactionReminder.ts            ← Context limit warnings

Background Hooks
├── useBackgroundTaskNavigation.ts  ← Task switching
└── useConcurrentSessions.ts        ← Multi-session coordination
```

### Plugin Hooks (Lifecycle Events)

Separate from React hooks, plugin hooks fire on specific events:

```json
// hooks.json
{
  "PreToolUse": [...],      // Before tool execution
  "PostToolUse": [...],     // After tool execution
  "SessionStart": [...],    // On session start/resume/compact
  "UserPromptSubmit": [...] // When user submits input
}
```

---

## 15. Voice Mode

**Location:** `src/voice/` (feature-flagged: `VOICE_MODE`)

### Architecture

```
Microphone Input
  │
  ├── Voice Activity Detection (VAD)
  │   └── Detect speech start/end
  │
  ├── Audio Capture
  │   └── Push-to-talk or continuous mode
  │
  ├── Speech-to-Text
  │   └── Transcription API (Whisper or platform STT)
  │
  ├── Text → QueryEngine
  │   └── Same pipeline as typed input
  │
  ├── Response Generation
  │   └── LLM response (standard flow)
  │
  └── Text-to-Speech (optional)
      └── Read response aloud
```

### Activation

```bash
# Enable at build time
bun run build --feature=VOICE_MODE

# Toggle at runtime
/voice  # slash command
```

---

## 16. Bridge Mode (IDE Integration)

**Location:** `src/bridge/` (33 modules, 200KB+)

Bridge mode connects free-code to IDEs for bidirectional communication.

### Architecture

```
┌────────────────────┐         ┌──────────────────────┐
│    VS Code /       │  WebSocket/  │    free-code       │
│    JetBrains       │◄─────────────►│    CLI             │
│                    │   (bridge)     │                    │
│  ┌──────────┐      │              │  ┌──────────────┐  │
│  │ Extension│      │              │  │ bridgeMain.ts│  │
│  │          │      │              │  │ (115KB)      │  │
│  └──────────┘      │              │  └──────────────┘  │
│                    │              │                    │
│  Features:         │              │  Features:         │
│  - Show diffs      │              │  - Execute tools   │
│  - Apply edits     │              │  - Stream responses│
│  - File navigation │              │  - Context sync    │
│  - Inline chat     │              │  - Session sharing │
└────────────────────┘              └──────────────────────┘
```

### Key Modules

| Module | Size | Purpose |
|--------|------|---------|
| `bridgeMain.ts` | 115KB | Main bridge orchestrator |
| `replBridge.ts` | 100KB | REPL-side bridge logic |
| `bridgeApi.ts` | - | IDE API abstraction |
| `bridgeMessaging.ts` | - | Message protocol |
| `createSession.ts` | - | Session pairing |

---

## 17. Configuration System

**Location:** `src/utils/settings/`, `src/utils/config.ts`

### Configuration Hierarchy

```
Priority (highest → lowest):

1. CLI arguments
   └── --model, --api-key, --max-turns, etc.

2. Environment variables
   └── ANTHROPIC_MODEL, ANTHROPIC_API_KEY, etc.

3. ~/.claude/settings.json → "env" section
   └── Overrides shell env vars at process level

4. ~/.claude/settings.json → top-level settings
   └── model, permissions, etc.

5. .claude/settings.json (project-level)
   └── Project-specific overrides

6. Remote/managed settings (GrowthBook)
   └── Feature flags, A/B tests

7. Hardcoded defaults
   └── Fallback values in source code
```

### settings.json Schema

```json
{
  // Model configuration
  "model": "qwen/qwen3-coder:free",

  // Environment variable overrides
  "env": {
    "ANTHROPIC_MODEL": "qwen/qwen3-coder:free",
    "ANTHROPIC_BASE_URL": "https://openrouter.ai/api"
  },

  // Permission rules
  "permissions": {
    "allow": [
      "Read(*)",
      "Glob(*)",
      "Grep(*)"
    ],
    "deny": [
      "Bash(rm -rf *)"
    ]
  },

  // API key helper (external command)
  "apiKeyHelper": "op read 'op://vault/anthropic/api-key'",

  // Custom API key approval
  "customApiKeyResponses": {
    "approved": ["normalized-key-hash"]
  },

  // MCP enable flag
  "ENABLE_EXPERIMENTAL_MCP_CLI": "true"
}
```

### CLAUDE.md (Project Configuration)

```markdown
<!-- CLAUDE.md in project root -->

# Project Instructions

When working in this codebase:
- Use TypeScript strict mode
- Follow the existing naming conventions
- Run tests with `bun test` before committing

## Architecture Notes
This is a monorepo using Turborepo...
```

The CLAUDE.md content is injected into the system prompt for every query, giving the LLM project-specific context.

### Config Loading

```typescript
// Simplified flow
function loadConfig() {
  const globalSettings = readJSON('~/.claude/settings.json')
  const projectSettings = readJSON('.claude/settings.json')
  const claudeMd = readFile('CLAUDE.md') || readFile('.claude/CLAUDE.md')

  // Merge with precedence
  return merge(defaults, globalSettings, projectSettings, envOverrides, cliArgs)
}
```

---

## 18. Build System & Feature Flags

**Location:** `scripts/build.ts`

### Build Process

```
bun run build
  │
  ├── 1. Parse CLI flags
  │   ├── --feature=FLAG_NAME (enable specific flags)
  │   ├── --dev (dev version stamp)
  │   └── --feature-set=dev-full (all flags)
  │
  ├── 2. Generate Feature Bitmask
  │   └── compile-time defines for feature() gates
  │
  ├── 3. Bun Bundler
  │   ├── Entry: src/entrypoints/cli.tsx
  │   ├── Target: bun
  │   ├── Minify: true (production)
  │   ├── Define: { MACRO_FEATURE_X: "true" | "false" }
  │   └── Dead code elimination for disabled features
  │
  ├── 4. Compile
  │   └── bun build --compile → single binary
  │
  └── 5. Output
      ├── ./cli (production)
      ├── ./cli-dev (development)
      └── ./dist/cli (alternative path)
```

### Feature Flags (45+)

| Flag | Category | Description |
|------|----------|-------------|
| `VOICE_MODE` | Input | Push-to-talk voice input |
| `ULTRAPLAN` | Agent | Remote multi-agent planning |
| `ULTRATHINK` | Model | Extended thinking mode |
| `BRIDGE_MODE` | IDE | IDE remote control bridge |
| `AGENT_TRIGGERS` | Agent | Cron/trigger background automation |
| `TOKEN_BUDGET` | Usage | Token budget tracking and warnings |
| `BASH_CLASSIFIER` | Security | ML-assisted bash permission |
| `EXTRACT_MEMORIES` | Memory | Post-query memory extraction |
| `HISTORY_PICKER` | UI | Interactive prompt history |
| `HISTORY_SNIP` | Context | Aggressive history compression |
| `MESSAGE_ACTIONS` | UI | Message action entrypoints |
| `QUICK_SEARCH` | UI | Prompt quick-search |
| `SHOT_STATS` | Debug | Shot-distribution statistics |
| `COMPACTION_REMINDERS` | Context | Smart compaction warnings |
| `CACHED_MICROCOMPACT` | Context | Cached microcompact optimization |
| `BUILTIN_EXPLORE_PLAN_AGENTS` | Agent | Built-in agent presets |
| `VERIFICATION_AGENT` | Agent | Task validation agent |
| `AGENT_MEMORY_SNAPSHOT` | Agent | Save/restore agent state |
| `AWAY_SUMMARY` | Agent | Background summarization |
| `KAIROS` | Agent | Assistant mode |
| ... | ... | ... (25+ more) |

### Feature Gate Pattern

```typescript
// In source code, features are gated like:
if (feature('VOICE_MODE')) {
  // This entire block is dead-code-eliminated
  // when VOICE_MODE is not in the feature set
  initVoiceMode()
}

// The bundler replaces feature() calls with literal true/false
// at compile time, then tree-shaking removes dead branches
```

---

## 19. Session Architecture

**Location:** `src/services/session/`, state persistence across the app

### Session Lifecycle

```
1. Create
   ├── Generate unique session ID
   ├── Initialize AppState
   ├── Start transcript recording
   └── Record session metadata (model, cwd, timestamp)

2. Active
   ├── Messages appended to transcript
   ├── Tool executions logged
   ├── Token usage tracked
   └── Background tasks managed

3. Suspend / Resume
   ├── Serialize conversation state
   ├── Save checkpoint to disk
   └── Resume from checkpoint (--resume flag)

4. End
   ├── Final usage summary
   ├── Archive transcript
   └── Clean up temp files
```

### Session Storage Layout

```
~/.claude/
├── sessions/
│   ├── {session-id}.jsonl         ← Message transcript (append-only)
│   ├── {session-id}.meta.json     ← Session metadata
│   └── {session-id}.checkpoint    ← Resume checkpoint
│
├── config/
│   ├── auth.json                  ← OAuth tokens (fallback)
│   └── cache/                     ← Various caches
│
├── settings.json                  ← User configuration
├── mcp.json                       ← MCP server configs
│
└── projects/
    └── {project-hash}/
        ├── {session-id}.jsonl     ← Project-scoped transcripts
        └── CLAUDE.md              ← Project instructions (auto-generated)
```

### Concurrent Sessions

Multiple free-code instances can run simultaneously:

```typescript
// src/utils/concurrentSessions.ts
// File-based locking prevents conflicts
// Each session has unique ID
// Shared config is read-only during session
```

---

## 20. Data Flow Diagrams

### Complete Query Lifecycle

```
┌──────────┐    ┌────────────────────────────────────────────────┐
│   User   │    │                  free-code                      │
│  types   │    │                                                  │
│  "fix    │    │  ┌─────────┐  ┌──────────┐  ┌──────────────┐  │
│   the    ├───►│  │  Input  ├──►│ Command  │  │  Permission  │  │
│   bug"   │    │  │  Buffer │  │  Router  │  │  System      │  │
│          │    │  └─────────┘  └────┬─────┘  └──────┬───────┘  │
└──────────┘    │                    │                │           │
                │               ┌────▼────┐          │           │
                │               │  Query  │◄─────────┘           │
                │               │  Engine │                      │
                │               └────┬────┘                      │
                │                    │                            │
                │    ┌───────────────┼───────────────┐           │
                │    │               │               │           │
                │    ▼               ▼               ▼           │
                │ ┌──────┐    ┌──────────┐    ┌──────────┐      │
                │ │System│    │ Message  │    │  Tool    │      │
                │ │Prompt│    │ History  │    │ Schemas  │      │
                │ └──┬───┘    └────┬─────┘    └────┬─────┘      │
                │    │             │               │             │
                │    └─────────────┼───────────────┘             │
                │                  │                              │
                │           ┌──────▼──────┐                      │
                │           │  API Layer  │                      │
                │           │  (stream)   │                      │
                │           └──────┬──────┘                      │
                │                  │                              │
                └──────────────────┼──────────────────────────────┘
                                   │
                          ┌────────▼────────┐
                          │   LLM Provider  │
                          │  ┌────────────┐ │
                          │  │ Stream SSE │ │
                          │  │ events     │ │
                          │  └─────┬──────┘ │
                          └────────┼────────┘
                                   │
                ┌──────────────────┼──────────────────────────────┐
                │                  │                              │
                │           ┌──────▼──────┐                      │
                │           │   Stream    │                      │
                │           │   Events    │                      │
                │           └──────┬──────┘                      │
                │                  │                              │
                │    ┌─────────────┼─────────────┐               │
                │    │             │             │               │
                │    ▼             ▼             ▼               │
                │ ┌──────┐  ┌──────────┐  ┌──────────┐         │
                │ │ Text │  │ Tool Use │  │ Thinking │         │
                │ │Deltas│  │  Blocks  │  │  Blocks  │         │
                │ └──┬───┘  └────┬─────┘  └────┬─────┘         │
                │    │           │              │               │
                │    │     ┌─────▼─────┐        │               │
                │    │     │   Tool    │        │               │
                │    │     │ Execution │        │               │
                │    │     └─────┬─────┘        │               │
                │    │           │              │               │
                │    └─────┬─────┘──────────────┘               │
                │          │                                     │
                │    ┌─────▼─────┐                              │
                │    │  Ink UI   │                              │
                │    │  Render   │──────────────────►  Terminal  │
                │    └───────────┘                              │
                └──────────────────────────────────────────────┘
```

### Tool Execution Detail

```
tool_use content block
  │
  ├─── Extract: { name: "Bash", input: { command: "ls -la" } }
  │
  ├─── Permission Check
  │    ├── Check always-allow rules → ALLOW
  │    ├── Check always-deny rules  → DENY + error result
  │    ├── Check session cache      → ALLOW (previously approved)
  │    ├── BASH_CLASSIFIER?         → ML risk classification
  │    └── Interactive prompt       → User decides
  │
  ├─── Execute (if allowed)
  │    ├── BashTool.execute({ command: "ls -la" })
  │    │   ├── Spawn child process
  │    │   ├── Capture stdout + stderr
  │    │   ├── Apply timeout (120s default)
  │    │   └── Return { output: "...", exitCode: 0 }
  │    │
  │    └── Wrap in ToolResult
  │         ├── success: true
  │         ├── output: "total 42\ndrwxr-xr-x..."
  │         └── Truncate if exceeds budget
  │
  └─── Serialize to tool_result content block
       └── Append to messages → send back to LLM
```

---

## 21. Key Dependencies

```
Runtime
├── @anthropic-ai/sdk ^0.80.0          ← Anthropic API client
├── @anthropic-ai/claude-agent-sdk ^0.2.87 ← Agent SDK
├── @modelcontextprotocol/sdk ^1.29.0  ← MCP protocol
├── @anthropic-ai/bedrock-sdk ^0.26.4  ← AWS Bedrock
├── @anthropic-ai/vertex-sdk ^0.14.4   ← Google Vertex AI
├── react ^19.2.4                      ← UI framework
├── ink ^6.8.0                         ← Terminal React renderer
├── commander ^14.0.0                  ← CLI argument parsing
├── zod ^4.3.6                         ← Schema validation
├── axios                              ← HTTP client (non-SDK calls)
├── highlight.js ^11.11.1             ← Syntax highlighting
├── sharp ^0.34.5                      ← Image processing
├── fuse.js                            ← Fuzzy search (skills, commands)
└── ws                                 ← WebSocket client

Build
├── bun ^1.3.11                        ← Runtime + bundler + compiler
├── typescript                         ← Type checking
└── biome                              ← Linting + formatting
```

---

## 22. Performance Optimizations

### Startup Optimizations

| Optimization | Savings | Implementation |
|---|---|---|
| Parallel keychain + MDM | ~65ms | `startKeychainPrefetch()` overlaps I/O |
| Lazy module imports | ~100ms | Dynamic `import()` for optional features |
| Fast-path exits | ~120ms | `--version` exits before any imports |
| Deferred prefetches | Non-blocking | MCP, tips, auth refresh run async |
| Feature dead-code elimination | ~30MB binary size | Compile-time `feature()` gates |

### Runtime Optimizations

| Optimization | Purpose | Implementation |
|---|---|---|
| Streaming rendering | Instant feedback | Delta events processed incrementally |
| Prompt caching | Reduce API costs | Cache break detection + optimization |
| Tool parallelization | Faster multi-tool | `Promise.all()` for independent tools |
| Context compaction | Stay within limits | Auto/micro/snip compaction strategies |
| Result budgeting | Prevent token waste | Truncate oversized tool outputs |
| File content caching | Reduce disk I/O | `FileStateCache` for recently read files |
| FPS tracking | Smooth terminal | Monitor and throttle render cycles |

### Memory Optimizations

| Optimization | Purpose |
|---|---|
| Circular input buffer | Fixed-size history without growing memory |
| Message streaming | Process tokens without buffering full response |
| Selective tool loading | Only import tools that are actually used |
| Session transcript append-only | Don't keep full history in memory |

---

## Appendix: Module Count Summary

| Directory | Files | Purpose |
|---|---|---|
| `src/services/api/` | 22 | API client, errors, retry, metrics |
| `src/services/mcp/` | 25 | MCP protocol integration |
| `src/services/analytics/` | 12 | Telemetry, GrowthBook, events |
| `src/tools/` | 48 | Tool implementations |
| `src/commands/` | 104 | Slash command implementations |
| `src/components/` | 148 | React/Ink UI components |
| `src/hooks/` | 87 | React hooks (permissions, input, state) |
| `src/ink/` | 52 | Terminal rendering primitives |
| `src/utils/` | ~80 | Utilities (auth, model, config, etc.) |
| `src/bridge/` | 33 | IDE bridge integration |
| `src/state/` | 6 | State management |
| `src/plugins/` | 4+ | Plugin system |
| `src/skills/` | 3+ | Skill system |
| **Total** | **~600+** | |
