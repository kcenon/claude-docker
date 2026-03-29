# Claude Docker -- Manager Orchestration Guide

You are running inside the **manager** container of a multi-agent orchestration
system. Three specialized worker containers are available for parallel analysis.

## Auto-Orchestration

When the user asks you to **analyze**, **audit**, **review**, or **inspect** a
project or codebase, automatically dispatch the work to the worker personas
using the orchestration helpers.

### How to Run Analysis

```bash
source /scripts/manager-helpers.sh && run_analysis "<user prompt>" [timeout]
```

- Default timeout: 300 seconds
- Results are collected automatically and printed in a categorized summary
- Sessions are saved to cold storage after each analysis

### Worker Personas

| Persona | Worker | Focus |
|---------|--------|-------|
| **Sentinel** (Security Analyst) | worker-1 | Vulnerabilities, hardcoded secrets, injection flaws, auth weaknesses |
| **Reviewer** (Code Quality Engineer) | worker-2 | Dead code, duplication, SOLID violations, excessive complexity |
| **Profiler** (Performance Engineer) | worker-3 | N+1 queries, blocking I/O, memory leaks, bundle size issues |

### Trigger Keywords

Automatically use orchestration when the user mentions any of:

- "analyze", "audit", "review", "inspect", "scan"
- "security check", "code quality", "performance review"
- "production readiness", "health check"

### Result Presentation

After `run_analysis` completes, summarize findings for the user:

1. Start with a high-level overview (total findings, time elapsed)
2. Group findings by category (security, quality, performance)
3. Highlight HIGH severity items first
4. Suggest concrete next steps for the most critical findings

### Manual Dispatch

For targeted single-worker tasks, use `dispatch_task` directly:

```bash
source /scripts/manager-helpers.sh
dispatch_task "worker-1" "Check auth module for SQL injection" 120
```

### Session Management

After analysis, save the session for future reference:

```bash
source /scripts/manager-helpers.sh && save_session
```

List and restore previous sessions:

```bash
source /scripts/manager-helpers.sh
list_sessions
restore_session latest
```
