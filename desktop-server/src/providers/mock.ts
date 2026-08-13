/**
 * Deterministic mock provider for tests and offline smoke runs. It reacts to
 * the latest user/tool message so the agent loop can be exercised end-to-end
 * without any API key or network access.
 *
 * Behavior:
 *   1. First turn → `update_tasks` checklist
 *   2. After tasks tool result → `write_file` NOTES.md
 *   3. After write → closing message and stop
 */
import type { ProviderAdapter, CompletionRequest, ProviderEvent } from './types.js';

export const mockAdapter: ProviderAdapter = {
  id: 'anthropic',
  async *stream(req: CompletionRequest): AsyncGenerator<ProviderEvent> {
    const wroteNotes = req.messages.some((m) => m.role === 'tool' && m.name === 'write_file');
    const setTasks = req.messages.some((m) => m.role === 'tool' && m.name === 'update_tasks');

    if (wroteNotes) {
      yield { kind: 'text', text: 'Done — created NOTES.md with a short note.' };
      yield { kind: 'done', stopReason: 'end_turn' };
      return;
    }

    if (setTasks) {
      yield { kind: 'text', text: "Next I'll add NOTES.md." };
      yield {
        kind: 'tool_call',
        call: {
          id: 'mock-call-2',
          name: 'write_file',
          input: { path: 'NOTES.md', content: '# Notes\n\nCreated by the mock agent.\n' },
        },
      };
      yield { kind: 'done', stopReason: 'tool_use' };
      return;
    }

    yield { kind: 'text', text: "I'll plan the work, then add a NOTES.md file." };
    yield {
      kind: 'tool_call',
      call: {
        id: 'mock-call-1',
        name: 'update_tasks',
        input: {
          merge: false,
          tasks: [
            { id: '1', content: 'Plan the change', status: 'completed' },
            { id: '2', content: 'Write NOTES.md', status: 'in_progress' },
          ],
        },
      },
    };
    yield { kind: 'done', stopReason: 'tool_use' };
  },
};
