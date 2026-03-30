#!/usr/bin/env node
// MCP Bridge Server for Claude Docker multi-account orchestration
// Exposes orchestration tools via Model Context Protocol (stdio transport)

import { Server } from '@modelcontextprotocol/sdk/server/index.js';
import { StdioServerTransport } from '@modelcontextprotocol/sdk/server/stdio.js';
import {
  CallToolRequestSchema,
  ListToolsRequestSchema,
} from '@modelcontextprotocol/sdk/types.js';
import { execFile } from 'node:child_process';
import { readFile } from 'node:fs/promises';
import { createClient } from 'redis';
import Anthropic from '@anthropic-ai/sdk';
import { resolve, join } from 'node:path';

// ---------------------------------------------------------------------------
// Configuration
// ---------------------------------------------------------------------------

const PROJECT_ROOT = process.env.DOCKER_COMPOSE_DIR || process.cwd();
const REDIS_HOST = process.env.REDIS_HOST || '127.0.0.1';
const REDIS_PORT = process.env.REDIS_PORT || '6379';
const REDIS_PASSWORD = process.env.REDIS_PASSWORD || '';
const ARCHIVE_DIR =
  process.env.ARCHIVE_DIR ||
  join(process.env.HOME || '', '.claude-state', 'analysis-archive');

// ---------------------------------------------------------------------------
// Redis — lazy connection with reconnection handling
// ---------------------------------------------------------------------------

let redisClient = null;

async function getRedis() {
  if (redisClient && redisClient.isOpen) return redisClient;

  const url = REDIS_PASSWORD
    ? `redis://:${REDIS_PASSWORD}@${REDIS_HOST}:${REDIS_PORT}`
    : `redis://${REDIS_HOST}:${REDIS_PORT}`;

  redisClient = createClient({ url });
  redisClient.on('error', () => {
    // Silently handle errors; reconnection is automatic
  });
  await redisClient.connect();
  return redisClient;
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

/** Run a command and return { stdout, stderr }. Rejects on non-zero exit. */
function run(cmd, args, { timeout = 60_000 } = {}) {
  return new Promise((resolve, reject) => {
    execFile(cmd, args, { timeout, maxBuffer: 10 * 1024 * 1024 }, (err, stdout, stderr) => {
      if (err) return reject(err);
      resolve({ stdout, stderr });
    });
  });
}

/** Docker exec into the manager container. */
async function dockerExecManager(script, timeout = 300_000) {
  const composeName = await getComposeProjectName();
  const container = `${composeName}-manager-1`;
  return run('docker', ['exec', '-T', container, 'bash', '-c', script], { timeout });
}

/** Resolve the docker compose project name. */
let _projectName = null;
async function getComposeProjectName() {
  if (_projectName) return _projectName;
  try {
    const { stdout } = await run(
      'docker', ['compose', '-f', resolve(PROJECT_ROOT, 'docker-compose.yml'), 'config', '--format', 'json'],
      { timeout: 10_000 },
    );
    const config = JSON.parse(stdout);
    _projectName = config.name || 'claude-docker';
  } catch {
    _projectName = 'claude-docker';
  }
  return _projectName;
}

/** Read and parse .env file (key=value pairs). */
async function readEnvFile() {
  try {
    const content = await readFile(resolve(PROJECT_ROOT, '.env'), 'utf8');
    const env = {};
    for (const line of content.split('\n')) {
      const trimmed = line.trim();
      if (!trimmed || trimmed.startsWith('#')) continue;
      const eqIdx = trimmed.indexOf('=');
      if (eqIdx === -1) continue;
      env[trimmed.slice(0, eqIdx)] = trimmed.slice(eqIdx + 1);
    }
    return env;
  } catch {
    return {};
  }
}

/** Read the archive index.json file. */
async function readArchiveIndex() {
  try {
    const content = await readFile(join(ARCHIVE_DIR, 'sessions', 'index.json'), 'utf8');
    return JSON.parse(content);
  } catch {
    // Fallback: try the root-level index
    try {
      const content = await readFile(join(ARCHIVE_DIR, 'index.json'), 'utf8');
      return JSON.parse(content);
    } catch {
      return { sessions: [] };
    }
  }
}

// ---------------------------------------------------------------------------
// Tool definitions
// ---------------------------------------------------------------------------

const TOOLS = [
  {
    name: 'delegate',
    description: 'Run a prompt on a specified account (API key or OAuth)',
    inputSchema: {
      type: 'object',
      properties: {
        account: { type: 'string', description: 'Account name (e.g. "manager", "worker-1", "a", "b")' },
        prompt: { type: 'string', description: 'Prompt to send' },
        model: { type: 'string', description: 'Model to use (default: claude-sonnet-4-20250514)' },
      },
      required: ['account', 'prompt'],
    },
  },
  {
    name: 'analyze',
    description: 'Run multi-persona parallel analysis (security, quality, performance)',
    inputSchema: {
      type: 'object',
      properties: {
        prompt: { type: 'string', description: 'Analysis prompt' },
        timeout: { type: 'number', description: 'Timeout in seconds (default: 300)' },
      },
      required: ['prompt'],
    },
  },
  {
    name: 'dispatch',
    description: 'Send a task to a specific worker',
    inputSchema: {
      type: 'object',
      properties: {
        worker: { type: 'string', description: 'Worker name (e.g. "worker-1")' },
        prompt: { type: 'string', description: 'Task prompt' },
        timeout: { type: 'number', description: 'Timeout in seconds (default: 300)' },
      },
      required: ['worker', 'prompt'],
    },
  },
  {
    name: 'accounts',
    description: 'List configured accounts and their status',
    inputSchema: { type: 'object', properties: {} },
  },
  {
    name: 'findings',
    description: 'Query analysis findings from Redis or archived sessions',
    inputSchema: {
      type: 'object',
      properties: {
        category: { type: 'string', description: 'Filter by category (security, quality, performance)' },
        sessionId: { type: 'string', description: 'Load from archived session instead of live Redis' },
      },
    },
  },
  {
    name: 'sessions',
    description: 'List archived analysis sessions',
    inputSchema: { type: 'object', properties: {} },
  },
  {
    name: 'status',
    description: 'Show worker status',
    inputSchema: {
      type: 'object',
      properties: {
        worker: { type: 'string', description: 'Specific worker name (omit for all)' },
      },
    },
  },
  {
    name: 'budget',
    description: 'Token usage information',
    inputSchema: { type: 'object', properties: {} },
  },
];

// ---------------------------------------------------------------------------
// Tool handlers
// ---------------------------------------------------------------------------

async function handleDelegate({ account, prompt, model }) {
  const envVars = await readEnvFile();

  // Determine which API key maps to this account
  const keyMap = {
    manager: 'CLAUDE_API_KEY_MANAGER',
    a: 'CLAUDE_API_KEY_A',
    b: 'CLAUDE_API_KEY_B',
    'worker-1': 'CLAUDE_API_KEY_1',
    'worker-2': 'CLAUDE_API_KEY_2',
    'worker-3': 'CLAUDE_API_KEY_3',
  };

  const envKey = keyMap[account];
  const apiKey = envKey ? envVars[envKey] : undefined;

  if (apiKey) {
    // API key account — call Anthropic SDK directly
    const client = new Anthropic({ apiKey });
    const response = await client.messages.create({
      model: model || 'claude-sonnet-4-20250514',
      max_tokens: 4096,
      messages: [{ role: 'user', content: prompt }],
    });
    const text = response.content
      .filter((b) => b.type === 'text')
      .map((b) => b.text)
      .join('\n');
    return text;
  }

  // OAuth account — use docker exec + claude -p
  const serviceMap = {
    manager: 'manager',
    a: 'claude-a',
    b: 'claude-b',
    'worker-1': 'worker-1',
    'worker-2': 'worker-2',
    'worker-3': 'worker-3',
  };
  const service = serviceMap[account] || account;
  const composeName = await getComposeProjectName();
  const container = `${composeName}-${service}-1`;

  // Use execFile with explicit args to avoid shell injection
  const { stdout } = await run('docker', ['exec', '-T', container, 'claude', '-p', prompt], {
    timeout: 120_000,
  });
  return stdout;
}

async function handleAnalyze({ prompt, timeout }) {
  const t = parseInt(timeout, 10) || 300;
  if (t < 1 || t > 3600) throw new Error('timeout must be 1-3600');
  // Escape single quotes in prompt for safe shell embedding
  const safePrompt = prompt.replace(/'/g, "'\\''");
  const script = `source /scripts/manager-helpers.sh && run_analysis '${safePrompt}' '${t}'`;
  const { stdout } = await dockerExecManager(script, (t + 30) * 1000);
  return stdout;
}

async function handleDispatch({ worker, prompt, timeout }) {
  const t = parseInt(timeout, 10) || 300;
  if (t < 1 || t > 3600) throw new Error('timeout must be 1-3600');
  const safeWorker = worker.replace(/'/g, "'\\''");
  const safePrompt = prompt.replace(/'/g, "'\\''");
  const script = `source /scripts/manager-helpers.sh && dispatch_task '${safeWorker}' '${safePrompt}' '${t}'`;
  const { stdout } = await dockerExecManager(script, (t + 30) * 1000);

  // Try to extract task ID from output
  const taskIdMatch = stdout.match(/task[_-]?id[:\s]+(\S+)/i);
  return JSON.stringify({
    taskId: taskIdMatch ? taskIdMatch[1] : 'unknown',
    status: 'dispatched',
    output: stdout,
  });
}

async function handleAccounts() {
  const envVars = await readEnvFile();
  const accounts = [];

  // Check API key accounts
  const apiKeyAccounts = [
    { env: 'CLAUDE_API_KEY_MANAGER', name: 'manager', service: 'manager' },
    { env: 'CLAUDE_API_KEY_A', name: 'a', service: 'claude-a' },
    { env: 'CLAUDE_API_KEY_B', name: 'b', service: 'claude-b' },
    { env: 'CLAUDE_API_KEY_1', name: 'worker-1', service: 'worker-1' },
    { env: 'CLAUDE_API_KEY_2', name: 'worker-2', service: 'worker-2' },
    { env: 'CLAUDE_API_KEY_3', name: 'worker-3', service: 'worker-3' },
  ];

  // Get running containers
  let runningContainers = '';
  try {
    const { stdout } = await run('docker', ['compose', '-f', resolve(PROJECT_ROOT, 'docker-compose.yml'), 'ps', '--format', 'json'], { timeout: 10_000 });
    runningContainers = stdout;
  } catch {
    // docker compose not available or not running
  }

  for (const { env, name, service } of apiKeyAccounts) {
    if (envVars[env]) {
      const running = runningContainers.includes(service);
      accounts.push({ name, type: 'configured', status: running ? 'running' : 'stopped' });
    }
  }

  // Check OAuth accounts (look for .credentials.json in state dirs)
  const stateBase = join(process.env.HOME || '', '.claude-state');
  const oauthDirs = [
    { dir: 'account-a', name: 'a', service: 'claude-a' },
    { dir: 'account-b', name: 'b', service: 'claude-b' },
    { dir: 'account-manager', name: 'manager', service: 'manager' },
    { dir: 'account-w1', name: 'worker-1', service: 'worker-1' },
    { dir: 'account-w2', name: 'worker-2', service: 'worker-2' },
    { dir: 'account-w3', name: 'worker-3', service: 'worker-3' },
  ];

  for (const { dir, name, service } of oauthDirs) {
    // Skip if already found as API key account
    if (accounts.some((a) => a.name === name)) continue;
    try {
      await readFile(join(stateBase, dir, '.credentials.json'), 'utf8');
      const running = runningContainers.includes(service);
      accounts.push({ name, type: 'oauth', status: running ? 'running' : 'stopped' });
    } catch {
      // No credentials file — skip
    }
  }

  return JSON.stringify(accounts, null, 2);
}

async function handleFindings({ category, sessionId } = {}) {
  // Load from archive if sessionId provided
  if (sessionId) {
    try {
      const sessionDir = join(ARCHIVE_DIR, 'sessions', sessionId);
      const resolved = resolve(sessionDir);
      if (!resolved.startsWith(resolve(ARCHIVE_DIR))) {
        throw new Error('Invalid session ID');
      }
      const content = await readFile(join(resolved, 'findings.json'), 'utf8');
      const findings = JSON.parse(content);
      if (category) {
        const filtered = findings.filter((f) => f.category === category);
        return JSON.stringify(filtered, null, 2);
      }
      return JSON.stringify(findings, null, 2);
    } catch (err) {
      return JSON.stringify({ error: `Failed to load session ${sessionId}: ${err.message}` });
    }
  }

  // Load from live Redis
  try {
    const redis = await getRedis();
    const key = category ? `findings:${category}` : 'findings:all';
    const items = await redis.lRange(key, 0, -1);
    const findings = items.map((item) => {
      try { return JSON.parse(item); } catch { return { raw: item }; }
    });
    return JSON.stringify(findings, null, 2);
  } catch (err) {
    return JSON.stringify({ error: `Redis query failed: ${err.message}` });
  }
}

async function handleSessions() {
  const index = await readArchiveIndex();
  const sessions = (index.sessions || []).map((s) => ({
    id: s.id,
    timestamp: s.endedAt || s.timestamp,
    findingsCount: s.findingsCount || 0,
    categories: s.categoryCounts ? Object.keys(s.categoryCounts) : [],
  }));
  return JSON.stringify(sessions, null, 2);
}

async function handleStatus({ worker } = {}) {
  try {
    const redis = await getRedis();
    const workers = worker ? [worker] : ['worker-1', 'worker-2', 'worker-3'];
    const statuses = [];

    for (const w of workers) {
      const raw = await redis.get(`worker:${w}:status`);
      if (raw) {
        try {
          const parsed = JSON.parse(raw);
          statuses.push({
            name: w,
            state: parsed.state || 'unknown',
            lastTask: parsed.lastTask || undefined,
            timestamp: parsed.timestamp || undefined,
          });
        } catch {
          statuses.push({ name: w, state: raw });
        }
      } else {
        statuses.push({ name: w, state: 'offline' });
      }
    }

    return JSON.stringify(statuses, null, 2);
  } catch (err) {
    return JSON.stringify({ error: `Redis query failed: ${err.message}` });
  }
}

function handleBudget() {
  return JSON.stringify({
    message: "Use 'scripts/claude-docker usage' for detailed tracking",
  });
}

// ---------------------------------------------------------------------------
// MCP Server setup
// ---------------------------------------------------------------------------

const server = new Server(
  { name: 'claude-docker-mcp-bridge', version: '1.0.0' },
  { capabilities: { tools: {} } },
);

server.setRequestHandler(ListToolsRequestSchema, async () => ({
  tools: TOOLS,
}));

server.setRequestHandler(CallToolRequestSchema, async (request) => {
  const { name, arguments: args } = request.params;

  try {
    let result;
    switch (name) {
      case 'delegate':
        result = await handleDelegate(args);
        break;
      case 'analyze':
        result = await handleAnalyze(args);
        break;
      case 'dispatch':
        result = await handleDispatch(args);
        break;
      case 'accounts':
        result = await handleAccounts();
        break;
      case 'findings':
        result = await handleFindings(args);
        break;
      case 'sessions':
        result = await handleSessions();
        break;
      case 'status':
        result = await handleStatus(args);
        break;
      case 'budget':
        result = handleBudget();
        break;
      default:
        return {
          content: [{ type: 'text', text: `Unknown tool: ${name}` }],
          isError: true,
        };
    }

    return {
      content: [{ type: 'text', text: typeof result === 'string' ? result : JSON.stringify(result) }],
    };
  } catch (err) {
    return {
      content: [{ type: 'text', text: `Error: ${err.message}` }],
      isError: true,
    };
  }
});

// ---------------------------------------------------------------------------
// Start
// ---------------------------------------------------------------------------

async function main() {
  const transport = new StdioServerTransport();
  await server.connect(transport);
}

main().catch((err) => {
  process.stderr.write(`MCP bridge server failed to start: ${err.message}\n`);
  process.exit(1);
});
