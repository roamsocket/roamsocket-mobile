/**
 * Open a URL in the desktop's default browser without pulling in a new
 * dependency. Electron has `shell.openExternal`; the headless CLI shells out
 * to the OS opener directly.
 */
import { spawn } from 'node:child_process';

export async function openInBrowser(url: string): Promise<void> {
  // Electron main process: prefer `shell.openExternal` when available so this
  // works the same inside the packaged app (no extra permission prompts).
  try {
    const electron = await import('electron').catch(() => null);
    if (electron?.shell?.openExternal) {
      await electron.shell.openExternal(url);
      return;
    }
  } catch {
    // Not running inside Electron — fall through to the OS opener.
  }

  const platform = process.platform;
  const cmd = platform === 'darwin' ? 'open' : platform === 'win32' ? 'cmd' : 'xdg-open';
  const args = platform === 'win32' ? ['/c', 'start', '""', url] : [url];
  try {
    spawn(cmd, args, { stdio: 'ignore', detached: true }).unref();
  } catch {
    // Best effort — the caller still returns the URL so the UI can show it
    // as a fallback link if this failed.
  }
}
