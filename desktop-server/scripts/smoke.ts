/**
 * End-to-end smoke test with no network or API key. It:
 *   1. creates a local git repo to act as "origin",
 *   2. starts the server with the mock agent,
 *   3. pairs over HTTP, opens the WebSocket,
 *   4. creates a session (clones the local repo), sends a user message,
 *   5. asserts the mock agent wrote a file, produced a diff, and finished,
 *   6. creates a PR (pushes the work branch to the local origin).
 *
 * Run with: npm run smoke
 */
import { spawn, spawnSync } from 'node:child_process';
import { mkdtemp, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import path from 'node:path';
import { pathToFileURL } from 'node:url';
import { WebSocket } from 'ws';

const PORT = Number(process.env.PORT) || 4571;
const BASE = `http://localhost:${PORT}`;

function git(cwd: string, ...args: string[]): void {
  const r = spawnSync('git', args, { cwd, encoding: 'utf8' });
  if (r.status !== 0) throw new Error(`git ${args.join(' ')} failed: ${r.stderr}`);
}

async function makeOriginRepo(): Promise<string> {
  const dir = await mkdtemp(path.join(tmpdir(), 'apc-origin-'));
  git(dir, 'init', '-b', 'main');
  git(dir, 'config', 'user.email', 'test@example.com');
  git(dir, 'config', 'user.name', 'Test');
  await writeFile(path.join(dir, 'README.md'), '# Test repo\n');
  git(dir, 'add', '-A');
  git(dir, 'commit', '-m', 'initial');
  // Allow pushes to this non-bare repo's non-checked-out branches.
  git(dir, 'config', 'receive.denyCurrentBranch', 'ignore');
  return dir;
}

function waitForCode(child: ReturnType<typeof spawn>): Promise<string> {
  return new Promise((resolve, reject) => {
    let buf = '';
    const onData = (d: Buffer) => {
      buf += d.toString();
      const m = buf.match(/Pairing code: (\d{6})/);
      if (m) resolve(m[1]!);
    };
    child.stdout?.on('data', onData);
    child.stderr?.on('data', (d) => (buf += d.toString()));
    setTimeout(() => reject(new Error(`Server did not print pairing code.\n${buf}`)), 15000);
  });
}

async function pair(code: string): Promise<string> {
  const res = await fetch(`${BASE}/pair`, {
    method: 'POST',
    headers: { 'content-type': 'application/json' },
    body: JSON.stringify({ code, deviceName: 'smoke-test' }),
  });
  if (!res.ok) throw new Error(`pair failed: ${res.status} ${await res.text()}`);
  const body = (await res.json()) as { token: string };
  return body.token;
}

function assert(cond: unknown, msg: string): void {
  if (!cond) throw new Error(`ASSERT FAILED: ${msg}`);
}

async function main(): Promise<void> {
  const origin = await makeOriginRepo();
  // Convert the local path to a file:// URL so the server's clone helper
  // recognizes it on every platform (Windows absolute paths don't match the
  // "starts with /" or "://" check in remoteUrl()).
  const originURL = pathToFileURL(origin).toString();
  // Isolate the server from the developer's real ~/.claude so global settings
  // env vars / skills don't leak into the throwaway smoke repo.
  const smokeHome = await mkdtemp(path.join(tmpdir(), 'apc-smoke-home-'));

  // Cross-platform: Node's spawn() on Windows requires `shell: true` to
  // resolve `.cmd` shims like npx.cmd that ship in the npm bin dir.
  const npxBin = process.platform === 'win32' ? 'npx.cmd' : 'npx';
  const server = spawn(npxBin, ['tsx', 'src/index.ts'], {
    shell: process.platform === 'win32',
    cwd: process.cwd(),
    env: {
      ...process.env,
      PORT: String(PORT),
      APC_MOCK: '1',
      APC_ADVERTISE: '0',
      APC_AUTO_TUNNEL: '0',
      APC_CLI_SETTINGS: '0',
      HOME: smokeHome,
    },
  });

  try {
    const code = await waitForCode(server);
    const token = await pair(code);
    console.log('paired, token acquired');

    const ws = new WebSocket(`ws://localhost:${PORT}/session?token=${token}`);
    const seen: string[] = [];
    let diffForNotes = false;
    let prUrl = '';
    let goalAchieved = false;
    let goalActive = false;

    await new Promise<void>((resolve, reject) => {
      const timeout = setTimeout(
        () => reject(new Error(`timeout; saw: ${seen.join(', ')}`)),
        30000
      );

      ws.on('open', () => {
        ws.send(
          JSON.stringify({
            type: 'create_session',
            sessionId: 'smoke',
            repo: { fullName: originURL, workBranch: 'apc/smoke-test' },
            model: { provider: 'anthropic', model: 'mock', apiKey: 'none', effort: 'high' },
            permissionMode: 'acceptEdits',
          })
        );
      });

      ws.on('message', (data) => {
        const msg = JSON.parse(data.toString());
        seen.push(msg.type);
        if (msg.type === 'session_created') {
          // Exercise /goal: mock agent writes NOTES.md; heuristic evaluator marks met.
          ws.send(
            JSON.stringify({
              type: 'user_message',
              sessionId: 'smoke',
              text: '/goal NOTES.md exists',
            })
          );
        } else if (msg.type === 'goal_status') {
          if (msg.status === 'active') goalActive = true;
          if (msg.status === 'achieved') goalAchieved = true;
        } else if (msg.type === 'diff' && msg.path === 'NOTES.md') {
          diffForNotes = true;
        } else if (msg.type === 'session_done') {
          // Prefer the new git_publish path; create_pr remains a thin wrapper.
          ws.send(
            JSON.stringify({
              type: 'git_publish',
              sessionId: 'smoke',
              message: 'Add NOTES.md',
              commit: true,
              push: true,
              openPr: true,
            })
          );
        } else if (msg.type === 'pr_created') {
          prUrl = msg.url;
          clearTimeout(timeout);
          resolve();
        } else if (msg.type === 'error') {
          clearTimeout(timeout);
          reject(new Error(`server error: ${msg.message} (saw: ${seen.join(', ')})`));
        }
      });
      ws.on('error', reject);
    });

    ws.close();

    assert(seen.includes('session_created'), 'session_created received');
    assert(seen.includes('goal_status'), 'goal_status received (/goal)');
    assert(goalActive, 'goal_status active emitted when goal set');
    assert(goalAchieved, 'goal_status achieved after NOTES.md');
    assert(seen.includes('task_list'), 'task_list received (agent checklist)');
    assert(seen.includes('tool_call'), 'tool_call received');
    assert(seen.includes('tool_result'), 'tool_result received');
    assert(diffForNotes, 'diff for NOTES.md received');
    assert(seen.includes('session_done'), 'session_done received');
    assert(prUrl.length > 0, 'pr_created url received');

    // Reattach: open a second WebSocket with the same session id and verify
    // the server replays the full transcript + checklist + goal so a phone
    // returning to a live session can pick up where it left off.
    {
      const ws2 = new WebSocket(`ws://localhost:${PORT}/session?token=${token}`);
      const replayEvents: string[] = [];
      let transcriptReplay: {
        events: { type: string }[];
        truncated: boolean;
        isLive: boolean;
      } | null = null;
      let replayedUser = false;
      let replayedAssistant = false;
      let replayedToolCall = false;
      let replayedToolResult = false;
      let replayedDiff = false;

      await new Promise<void>((resolve, reject) => {
        const timeout = setTimeout(
          () => reject(new Error(`reattach timeout; saw: ${replayEvents.join(', ')}`)),
          15000
        );
        ws2.on('open', () => {
          // Re-open with the same session id and an empty firstMessage so the
          // server takes the reattach path instead of starting a new turn.
          ws2.send(
            JSON.stringify({
              type: 'create_session',
              sessionId: 'smoke',
              repo: { fullName: originURL, workBranch: 'apc/smoke-test' },
              model: { provider: 'anthropic', model: 'mock', apiKey: 'none', effort: 'high' },
              permissionMode: 'acceptEdits',
            })
          );
        });
        ws2.on('message', (data) => {
          const msg = JSON.parse(data.toString());
          replayEvents.push(msg.type);
          if (msg.type === 'transcript_replay') {
            transcriptReplay = {
              events: msg.events,
              truncated: msg.truncated,
              isLive: msg.isLive,
            };
            for (const ev of msg.events) {
              if (ev.type === 'user') replayedUser = true;
              else if (ev.type === 'assistant_delta') replayedAssistant = true;
              else if (ev.type === 'tool_call') replayedToolCall = true;
              else if (ev.type === 'tool_result') replayedToolResult = true;
              else if (ev.type === 'diff') replayedDiff = true;
            }
            // The agent is idle after the first session — `transcript_replay`
            // is the last event we expect until the phone sends a new turn.
            // Close the test once we've verified the replay arrived.
            clearTimeout(timeout);
            resolve();
          } else if (msg.type === 'error') {
            clearTimeout(timeout);
            reject(new Error(`reattach error: ${msg.message}`));
          }
        });
        ws2.on('error', reject);
      });
      ws2.close();

      assert(replayEvents.includes('session_created'), 'reattach: session_created re-emitted');
      assert(replayEvents.includes('task_list'), 'reattach: task_list replayed');
      assert(replayEvents.includes('goal_status'), 'reattach: goal_status replayed');
      assert(transcriptReplay !== null, 'reattach: transcript_replay received');
      assert(!transcriptReplay!.truncated, 'reattach: transcript not truncated for short sessions');
      assert(!transcriptReplay!.isLive, 'reattach: isLive false after session_done');
      assert(transcriptReplay!.events.length > 0, 'reattach: transcript has events');
      assert(replayedUser, 'reattach: user message replayed');
      assert(replayedAssistant, 'reattach: assistant_delta replayed');
      assert(replayedToolCall, 'reattach: tool_call replayed');
      assert(replayedToolResult, 'reattach: tool_result replayed');
      assert(replayedDiff, 'reattach: diff replayed');
      console.log(
        `  reattach: replayed ${transcriptReplay!.events.length} events (truncated=${transcriptReplay!.truncated}, isLive=${transcriptReplay!.isLive})`
      );
    }

    console.log('\nSMOKE TEST PASSED');
    console.log('events:', seen.join(' -> '));
    console.log('pr url:', prUrl);
  } finally {
    server.kill('SIGKILL');
  }
}

main().catch((err) => {
  console.error('\nSMOKE TEST FAILED:', err.message);
  process.exit(1);
});
