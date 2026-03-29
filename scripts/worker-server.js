#!/usr/bin/env node
'use strict';

// --- Dependencies -----------------------------------------------------------
const http = require('http');
const crypto = require('crypto');                              // SRS-8.6.1
const { spawn } = require('child_process');                  // SRS-8.2.5
const { createClient } = require('redis');                   // SRS-8.2.11

// --- Configuration ----------------------------------------------------------
const WORKER_PORT = parseInt(process.env.WORKER_PORT, 10) || 9000; // SRS-8.2.1
const REDIS_HOST  = process.env.REDIS_HOST || 'redis';
const REDIS_PORT  = process.env.REDIS_PORT || '6379';
const REDIS_PASS  = process.env.REDIS_PASSWORD || '';           // SRS-8.6.2
const REDIS_URL   = REDIS_PASS
  ? `redis://:${REDIS_PASS}@${REDIS_HOST}:${REDIS_PORT}`
  : `redis://${REDIS_HOST}:${REDIS_PORT}`;
const WORKER_NAME = process.env.WORKER_NAME || `worker-${process.pid}`;
const WORKER_PERSONA = process.env.WORKER_PERSONA || '';      // SRS-8.7.1
const WORKER_AUTH_TOKEN = process.env.WORKER_AUTH_TOKEN || ''; // SRS-8.6.1
const MAX_BUFFER  = 10 * 1024 * 1024;                       // 10 MB
const REDIS_RETRY_LIMIT    = 3;                              // SRS-8.2.15
const REDIS_RETRY_DELAY_MS = 2000;

// --- State ------------------------------------------------------------------
let redis = null;
let currentTaskId = null;

/**
 * Connect to Redis with retry logic.
 * Retries up to REDIS_RETRY_LIMIT times with REDIS_RETRY_DELAY_MS intervals.
 * @returns {Promise<import('redis').RedisClientType>}
 */
async function connectRedis() {                              // SRS-8.2.15
  for (let attempt = 1; attempt <= REDIS_RETRY_LIMIT; attempt++) {
    try {
      const client = createClient({ url: REDIS_URL });
      client.on('error', (err) => console.error(`[redis] ${err.message}`));
      await client.connect();
      console.log(`[redis] Connected to ${REDIS_URL} (attempt ${attempt})`);
      return client;
    } catch (err) {
      console.error(`[redis] Attempt ${attempt}/${REDIS_RETRY_LIMIT} failed: ${err.message}`);
      if (attempt < REDIS_RETRY_LIMIT) {
        await new Promise((r) => setTimeout(r, REDIS_RETRY_DELAY_MS));
      }
    }
  }
  throw new Error(`Failed to connect to Redis after ${REDIS_RETRY_LIMIT} attempts`);
}

// --- Shared context helpers -------------------------------------------------

/**
 * Read project-level shared context from Redis.
 * @returns {Promise<Record<string, string>>}
 */
async function readSharedContext() {                          // SRS-8.2.3
  const ctx = await redis.hGetAll('context:shared');
  return ctx || {};
}

/**
 * Read accumulated findings from all previous workers.
 * @returns {Promise<string[]>}
 */
async function readPriorFindings() {                         // SRS-8.2.4
  const findings = await redis.lRange('findings:all', 0, -1);
  return findings || [];
}

// --- Prompt builder ---------------------------------------------------------

/**
 * Build an enriched prompt combining shared context, prior findings, and the
 * task-specific prompt. The structured template ensures Claude receives full
 * project awareness before executing the task.
 *
 * @param {Record<string, string>} context - Shared context key-value pairs
 * @param {string[]} priorFindings         - Prior findings from other workers
 * @param {string} taskPrompt              - Task-specific prompt from manager
 * @returns {string}
 */
function buildEnrichedPrompt(context, priorFindings, taskPrompt) {
  const sections = [];

  // [Role] section — injected from WORKER_PERSONA env var (SRS-8.7.1)
  if (WORKER_PERSONA) {
    sections.push('[Role]');
    sections.push(WORKER_PERSONA);
    sections.push('');
  }

  // [Project Context] section
  const ctxEntries = Object.entries(context);
  if (ctxEntries.length > 0) {
    sections.push('[Project Context]');
    for (const [key, value] of ctxEntries) {
      sections.push(`${key}: ${value}`);
    }
    sections.push('');
  }

  // [Prior Findings] section
  if (priorFindings.length > 0) {
    sections.push('[Prior Findings]');
    for (const finding of priorFindings) {
      sections.push(`- ${finding}`);
    }
    sections.push('');
  }

  // [Your Task] section
  sections.push('[Your Task]');
  sections.push(taskPrompt);
  sections.push('');

  // [Output Format] section
  sections.push('[Output Format]');
  sections.push(
    'Respond with a JSON code block containing: ' +
    '{ "summary": "...", "findings": [...], "status": "done"|"error" }'
  );

  return sections.join('\n');
}

// --- Claude execution -------------------------------------------------------

/**
 * Execute `claude -p` via async spawn with stdin pipe. Using stdin pipe
 * instead of shell argument interpolation prevents command injection.
 * Async execution ensures the Node.js event loop remains free for heartbeats
 * and health checks during long-running Claude tasks.
 *
 * @param {string} enrichedPrompt - Full prompt to send via stdin
 * @param {number} timeoutMs      - Execution timeout in milliseconds
 * @returns {Promise<{ stdout: string, stderr: string, status: number|null, timedOut: boolean }>}
 */
function executeClaude(enrichedPrompt, timeoutMs) {          // SRS-8.2.5
  return new Promise((resolve) => {
    const chunks = [];
    const errChunks = [];
    let timedOut = false;

    const child = spawn('claude', ['-p'], {
      cwd: '/workspace',
      stdio: ['pipe', 'pipe', 'pipe'],
    });

    child.stdout.on('data', (data) => chunks.push(data));
    child.stderr.on('data', (data) => errChunks.push(data));

    const timer = setTimeout(() => {
      timedOut = true;
      child.kill('SIGTERM');
    }, timeoutMs);

    child.on('close', (code) => {
      clearTimeout(timer);
      const stdout = Buffer.concat(chunks).toString('utf-8').slice(0, MAX_BUFFER);
      const stderr = Buffer.concat(errChunks).toString('utf-8').slice(0, MAX_BUFFER);
      resolve({ stdout, stderr, status: code, timedOut });
    });

    // Write prompt to stdin and close
    child.stdin.on('error', () => {});  // EPIPE handled via close event
    child.stdin.write(enrichedPrompt);
    child.stdin.end();
  });
}

// --- Output parser ----------------------------------------------------------

/**
 * Parse structured JSON findings from Claude's raw output.
 * Looks for the last ```json ... ``` code fence. If no JSON block is found,
 * returns empty findings with status "partial" (SRS-8.2.13).
 *
 * @param {string} rawOutput - Raw stdout from claude -p
 * @returns {{ summary: string, findings: any[], status: string }}
 */
function parseFindings(rawOutput) {                          // SRS-8.2.6, SRS-8.2.13
  // Find the last ```json ... ``` block
  const jsonBlockRegex = /```json\s*([\s\S]*?)```/g;
  let lastMatch = null;
  let match;
  while ((match = jsonBlockRegex.exec(rawOutput)) !== null) {
    lastMatch = match;
  }

  if (!lastMatch) {
    // No JSON block found — return partial result (SRS-8.2.13)
    return {
      summary: rawOutput.slice(0, 500),
      findings: [],
      status: 'partial',
    };
  }

  try {
    const parsed = JSON.parse(lastMatch[1].trim());
    // SRS-8.2.12: Validate findings schema (category + summary required)
    const validatedFindings = (parsed.findings || []).filter(f =>
      typeof f === 'object' && f !== null &&
      typeof f.category === 'string' &&
      typeof f.summary === 'string'
    );
    return {
      summary: parsed.summary || '',
      findings: validatedFindings,
      status: parsed.status || 'done',
    };
  } catch {
    return {
      summary: rawOutput.slice(0, 500),
      findings: [],
      status: 'partial',
    };
  }
}

// --- Redis result writer ----------------------------------------------------

/**
 * Write task results back to Redis:
 *  - SET result:{taskId} as a hash with TTL 3600s (SRS-8.2.16)
 *  - RPUSH each finding to findings:{category} and findings:all (SRS-8.2.7)
 *
 * @param {string} taskId
 * @param {object} result - Parsed result from parseFindings()
 * @param {string} rawOutput
 */
async function writeResults(taskId, result, rawOutput, startedAt, startMs) { // SRS-8.2.7, SRS-8.2.16
  const resultKey = `result:${taskId}`;
  const resultData = {
    taskId,
    status: result.status,
    summary: result.summary,
    findings: JSON.stringify(result.findings),
    rawOutput: rawOutput.slice(0, 50000),                    // cap stored output
    completedAt: new Date().toISOString(),
    worker: WORKER_NAME,
    // SRS-8.5.7: Optional timing fields for cold storage metrics
    ...(startedAt && { startedAt }),
    ...(startMs && { durationMs: String(Date.now() - startMs) }),
  };

  // Write result hash with TTL 3600s (SRS-8.2.16)
  await redis.hSet(resultKey, resultData);
  await redis.expire(resultKey, 3600);

  // Accumulate findings (SRS-8.2.7)
  for (const finding of result.findings) {
    const findingStr = typeof finding === 'string' ? finding : JSON.stringify(finding);
    const category = (typeof finding === 'object' && finding.category) || 'general';
    await redis.rPush(`findings:${category}`, findingStr);
    await redis.rPush('findings:all', findingStr);
  }
}

// --- Worker heartbeat -------------------------------------------------------

let heartbeatInterval = null;

/**
 * Maintain worker status and heartbeat keys in Redis.
 *  - worker:{name}:status  — TTL 60s (SRS-8.2.8)
 *  - worker:{name}:heartbeat — TTL 30s (SRS-8.2.9)
 */
function startHeartbeat() {                                  // SRS-8.2.8, SRS-8.2.9
  const statusKey    = `worker:${WORKER_NAME}:status`;
  const heartbeatKey = `worker:${WORKER_NAME}:heartbeat`;

  const beat = async () => {
    try {
      await redis.set(statusKey, JSON.stringify({
        state: currentTaskId ? 'busy' : 'idle',
        lastTask: currentTaskId,
        timestamp: new Date().toISOString(),
      }), { EX: 60 });                                      // TTL 60s
      await redis.set(heartbeatKey, Date.now().toString(), { EX: 30 }); // TTL 30s
    } catch (err) {
      console.error(`[heartbeat] ${err.message}`);
    }
  };

  beat();                                                    // initial beat
  heartbeatInterval = setInterval(beat, 15000);              // every 15s
}

/**
 * Update worker status to reflect an active task.
 * @param {string} taskId
 */
async function setWorkerBusy(taskId) {
  try {
    const statusKey = `worker:${WORKER_NAME}:status`;
    await redis.set(statusKey, JSON.stringify({
      state: 'busy',
      lastTask: taskId,
      timestamp: new Date().toISOString(),
    }), { EX: 60 });
  } catch (err) {
    console.error(`[status] ${err.message}`);
  }
}

// --- HTTP server ------------------------------------------------------------

/**
 * POST /task handler — orchestrates the full pipeline:
 *   read context → build prompt → execute claude → parse → write results
 *
 * Accepts JSON body: { taskId: string, prompt: string, timeout?: number }
 */
async function handleTask(req, res) {                        // SRS-8.2.1, SRS-8.2.2
  // Parse request body with size limit
  const MAX_BODY = 1024 * 1024;                              // 1 MB
  let body = '';
  for await (const chunk of req) {
    body += chunk;
    if (body.length > MAX_BODY) {
      res.writeHead(413, { 'Content-Type': 'application/json' });
      res.end(JSON.stringify({ error: 'Request body too large' }));
      return;
    }
  }

  let taskId, prompt, timeout;
  try {
    const parsed = JSON.parse(body);
    taskId  = parsed.taskId;
    prompt  = parsed.prompt;
    timeout = parsed.timeout || 300;                         // default 300s
  } catch {
    res.writeHead(400, { 'Content-Type': 'application/json' });
    res.end(JSON.stringify({ error: 'Invalid JSON body' }));
    return;
  }

  if (!taskId || !prompt) {
    res.writeHead(400, { 'Content-Type': 'application/json' });
    res.end(JSON.stringify({ error: 'Missing taskId or prompt' }));
    return;
  }

  console.log(`[task] ${taskId} — starting (timeout: ${timeout}s)`);
  currentTaskId = taskId;
  await setWorkerBusy(taskId);
  const taskStartedAt = new Date().toISOString();
  const taskStartMs = Date.now();

  try {
    // Step 1: Read shared context from Redis (SRS-8.2.3, SRS-8.2.4)
    const [context, priorFindings] = await Promise.all([
      readSharedContext(),
      readPriorFindings(),
    ]);

    // Step 2: Build enriched prompt
    const enrichedPrompt = buildEnrichedPrompt(context, priorFindings, prompt);

    // Step 3: Execute claude -p via async stdin pipe (SRS-8.2.5)
    const timeoutMs = timeout * 1000;
    const claudeResult = await executeClaude(enrichedPrompt, timeoutMs);

    if (claudeResult.timedOut) {
      console.error(`[task] ${taskId} — timed out after ${timeout}s`);
      const errorResult = { summary: 'Task timed out', findings: [], status: 'error' };
      await writeResults(taskId, errorResult, '');
      res.writeHead(504, { 'Content-Type': 'application/json' });
      res.end(JSON.stringify({ status: 'error', taskId, error: 'timeout' }));
      return;
    }

    // Step 4: Parse findings from output (SRS-8.2.6, SRS-8.2.13)
    const result = parseFindings(claudeResult.stdout);

    // Step 5: Write results to Redis (SRS-8.2.7, SRS-8.2.16)
    await writeResults(taskId, result, claudeResult.stdout, taskStartedAt, taskStartMs);

    // Step 6: Respond to manager (SRS-8.2.10)
    console.log(`[task] ${taskId} — completed (status: ${result.status})`);
    res.writeHead(200, { 'Content-Type': 'application/json' });
    res.end(JSON.stringify({
      status: result.status,
      taskId,
      output: claudeResult.stdout.slice(0, 10000),
      findings: result.findings,
    }));

  } catch (err) {
    console.error(`[task] ${taskId} — error: ${err.message}`);
    res.writeHead(500, { 'Content-Type': 'application/json' });
    res.end(JSON.stringify({ status: 'error', taskId, error: err.message }));
  } finally {
    currentTaskId = null;
  }
}

/**
 * GET /health handler — simple health check endpoint.
 */
function handleHealth(req, res) {
  const healthy = redis !== null && redis.isOpen;
  res.writeHead(healthy ? 200 : 503, { 'Content-Type': 'application/json' });
  res.end(JSON.stringify({
    status: healthy ? 'ok' : 'unhealthy',
    worker: WORKER_NAME,
    redis: healthy ? 'connected' : 'disconnected',
  }));
}

/**
 * Validate Bearer token on authenticated endpoints.            SRS-8.6.1
 * Returns true if the request is authorized, false otherwise.
 * If WORKER_AUTH_TOKEN is not set, allows all requests (backward compatibility).
 */
function validateAuth(req, res) {
  if (!WORKER_AUTH_TOKEN) return true;

  const authHeader = req.headers['authorization'] || '';
  const token = authHeader.startsWith('Bearer ') ? authHeader.slice(7) : '';

  // Timing-safe comparison to prevent timing attacks (SRS-8.6.1)
  const tokenBuf = Buffer.from(token);
  const expectedBuf = Buffer.from(WORKER_AUTH_TOKEN);
  const valid = tokenBuf.length === expectedBuf.length &&
                crypto.timingSafeEqual(tokenBuf, expectedBuf);

  if (!valid) {
    res.writeHead(401, { 'Content-Type': 'application/json' });
    res.end(JSON.stringify({ error: 'Unauthorized' }));
    return false;
  }
  return true;
}

/**
 * HTTP request router.
 */
const server = http.createServer((req, res) => {
  if (req.method === 'POST' && req.url === '/task') {
    if (!validateAuth(req, res)) return;
    handleTask(req, res).catch((err) => {
      console.error(`[task] Unhandled error: ${err.message}`);
      if (!res.headersSent) {
        res.writeHead(500, { 'Content-Type': 'application/json' });
        res.end(JSON.stringify({ status: 'error', error: 'Internal server error' }));
      }
    });
  } else if (req.method === 'GET' && req.url === '/health') {
    handleHealth(req, res);
  } else {
    res.writeHead(404, { 'Content-Type': 'application/json' });
    res.end(JSON.stringify({ error: 'Not found' }));
  }
});

// --- Startup ----------------------------------------------------------------

async function main() {
  try {
    if (!WORKER_AUTH_TOKEN) {
      console.warn('[worker] WARNING: WORKER_AUTH_TOKEN not set — task endpoint is unauthenticated');
    }

    redis = await connectRedis();                            // SRS-8.2.15
    startHeartbeat();                                        // SRS-8.2.8, SRS-8.2.9

    server.listen(WORKER_PORT, () => {
      console.log(`[worker] ${WORKER_NAME} listening on :${WORKER_PORT}`);
    });
  } catch (err) {
    console.error(`[fatal] ${err.message}`);
    process.exit(1);
  }
}

// --- Graceful shutdown ------------------------------------------------------

function shutdown(signal) {
  console.log(`[worker] Received ${signal}, shutting down...`);
  clearInterval(heartbeatInterval);

  server.close(async () => {
    if (redis && redis.isOpen) {
      // Clear status keys before disconnecting
      try {
        await redis.del(`worker:${WORKER_NAME}:status`);
        await redis.del(`worker:${WORKER_NAME}:heartbeat`);
      } catch { /* ignore during shutdown */ }
      await redis.quit();
    }
    console.log('[worker] Shutdown complete.');
    process.exit(0);
  });

  // Force exit if graceful shutdown takes too long
  setTimeout(() => process.exit(1), 5000);
}

process.on('SIGTERM', () => shutdown('SIGTERM'));
process.on('SIGINT',  () => shutdown('SIGINT'));

main();
