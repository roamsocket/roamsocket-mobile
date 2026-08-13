/**
 * Agent task checklist tool. The coding agent uses this to plan multi-step
 * work and report progress; the server mirrors the list to the app as
 * `task_list` frames so the phone can show a live checklist.
 */
import type { Tool, ToolResult } from './types.js';

export type AgentTaskStatus = 'pending' | 'in_progress' | 'completed' | 'cancelled';

export interface AgentTask {
  id: string;
  content: string;
  status: AgentTaskStatus;
}

const STATUSES = new Set<AgentTaskStatus>(['pending', 'in_progress', 'completed', 'cancelled']);

function asStatus(raw: unknown): AgentTaskStatus {
  const s = String(raw ?? 'pending').toLowerCase();
  if (STATUSES.has(s as AgentTaskStatus)) return s as AgentTaskStatus;
  return 'pending';
}

/** Normalize tool input into a clean task array. */
export function normalizeTasks(input: Record<string, unknown>): AgentTask[] {
  const raw = input.tasks;
  if (!Array.isArray(raw)) return [];
  const out: AgentTask[] = [];
  for (let i = 0; i < raw.length; i++) {
    const item = raw[i];
    if (!item || typeof item !== 'object') continue;
    const rec = item as Record<string, unknown>;
    const content = String(rec.content ?? rec.title ?? '').trim();
    if (!content) continue;
    const id = String(rec.id ?? `task-${i + 1}`).trim() || `task-${i + 1}`;
    out.push({ id, content, status: asStatus(rec.status) });
  }
  return out;
}

/**
 * Merge incoming tasks into the existing list by id.
 * When `merge` is false, replace the whole list.
 */
export function applyTaskUpdate(current: AgentTask[], input: Record<string, unknown>): AgentTask[] {
  const next = normalizeTasks(input);
  const merge = input.merge !== false && input.merge !== 'false';
  if (!merge) return next;

  const byId = new Map(current.map((t) => [t.id, t]));
  for (const t of next) {
    byId.set(t.id, t);
  }
  // Preserve order: existing ids first (updated in place), then new ids.
  const ordered: AgentTask[] = [];
  const seen = new Set<string>();
  for (const t of current) {
    const u = byId.get(t.id);
    if (u) {
      ordered.push(u);
      seen.add(t.id);
    }
  }
  for (const t of next) {
    if (!seen.has(t.id)) ordered.push(t);
  }
  return ordered;
}

export function formatTaskChecklist(tasks: AgentTask[]): string {
  if (tasks.length === 0) return 'Task list cleared.';
  const lines = tasks.map((t) => {
    const mark =
      t.status === 'completed'
        ? '[x]'
        : t.status === 'in_progress'
          ? '[~]'
          : t.status === 'cancelled'
            ? '[-]'
            : '[ ]';
    return `${mark} ${t.id}: ${t.content}`;
  });
  const done = tasks.filter((t) => t.status === 'completed').length;
  return `Tasks ${done}/${tasks.length} complete\n${lines.join('\n')}`;
}

/** Tool definition — execution is pure; the agent loop owns session state. */
export const updateTasksTool: Tool = {
  name: 'update_tasks',
  description:
    'Create or update your working task checklist for this coding session. ' +
    'Use this for multi-step work so the user can see progress. ' +
    'Prefer merge:true to update statuses by id; set merge:false to replace the whole list. ' +
    'Statuses: pending | in_progress | completed | cancelled. ' +
    'Mark one task in_progress at a time when possible, and mark completed as you finish.',
  inputSchema: {
    type: 'object',
    properties: {
      merge: {
        type: 'boolean',
        description:
          'If true (default), upsert tasks by id into the existing list. If false, replace the list.',
      },
      tasks: {
        type: 'array',
        description: 'Tasks to set or update.',
        items: {
          type: 'object',
          properties: {
            id: {
              type: 'string',
              description: 'Stable id for this task (reuse when updating status).',
            },
            content: {
              type: 'string',
              description: 'Short human-readable task description.',
            },
            status: {
              type: 'string',
              enum: ['pending', 'in_progress', 'completed', 'cancelled'],
              description: 'Task status.',
            },
          },
          required: ['content'],
        },
      },
    },
    required: ['tasks'],
  },
  summarize(input) {
    const tasks = normalizeTasks(input);
    if (tasks.length === 0) return 'tasks: clear';
    const done = tasks.filter((t) => t.status === 'completed').length;
    const active = tasks.find((t) => t.status === 'in_progress');
    if (active) return `tasks: ${done}/${tasks.length} · ${active.content}`;
    return `tasks: ${done}/${tasks.length}`;
  },
  async execute(input): Promise<ToolResult> {
    const tasks = normalizeTasks(input);
    if (tasks.length === 0 && input.merge === false) {
      return { ok: true, output: formatTaskChecklist([]) };
    }
    if (tasks.length === 0) {
      return {
        ok: false,
        output: 'No valid tasks provided. Each task needs a non-empty content string.',
      };
    }
    // Loop applies merge against session state; here we only format what was sent.
    return { ok: true, output: formatTaskChecklist(tasks) };
  },
};
