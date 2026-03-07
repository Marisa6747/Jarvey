import { exec } from "node:child_process";
import { promisify } from "node:util";
import type {
  Shell,
  ShellAction,
  ShellResult
} from "@openai/agents";

const execAsync = promisify(exec);

const blockedCommandMatchers = [
  { pattern: /\brm\s+-rf\s+\/(\s|$)/, reason: "Deleting the root filesystem is blocked." },
  { pattern: /\bmkfs(\.| )/i, reason: "Formatting disks is blocked." },
  { pattern: /\bdiskutil\s+erase/i, reason: "Erasing disks is blocked." },
  { pattern: /\bshutdown\b/i, reason: "Shutting down the machine is blocked." },
  { pattern: /\breboot\b/i, reason: "Rebooting the machine is blocked." },
  { pattern: /\bhalt\b/i, reason: "Halting the machine is blocked." },
  { pattern: /\blaunchctl\s+reboot\b/i, reason: "System reboot commands are blocked." }
];

function findBlockedReason(command: string): string | undefined {
  return blockedCommandMatchers.find((entry) => entry.pattern.test(command))?.reason;
}

export class HostShell implements Shell {
  constructor(private readonly cwd = process.env.HOME ?? process.cwd()) {}

  async run(action: ShellAction): Promise<ShellResult> {
    const output: ShellResult["output"] = [];

    for (const command of action.commands) {
      const blockedReason = findBlockedReason(command);
      if (blockedReason) {
        output.push({
          command,
          stdout: "",
          stderr: blockedReason,
          outcome: {
            type: "exit",
            exitCode: 126
          }
        });
        break;
      }

      try {
        const result = await execAsync(command, {
          cwd: this.cwd,
          shell: "/bin/zsh",
          timeout: action.timeoutMs,
          maxBuffer: action.maxOutputLength ?? 1024 * 1024
        });
        output.push({
          command,
          stdout: result.stdout,
          stderr: result.stderr,
          outcome: {
            type: "exit",
            exitCode: 0
          }
        });
      } catch (error) {
        const failure = error as {
          stdout?: string;
          stderr?: string;
          code?: number | null;
          signal?: string | null;
          killed?: boolean;
        };
        output.push({
          command,
          stdout: failure.stdout ?? "",
          stderr: failure.stderr ?? String(error),
          outcome:
            failure.killed || failure.signal === "SIGTERM"
              ? { type: "timeout" }
              : { type: "exit", exitCode: failure.code ?? 1 }
        });
        if (failure.killed || failure.signal === "SIGTERM") {
          break;
        }
      }
    }

    return {
      output,
      providerData: {
        cwd: this.cwd
      }
    };
  }
}

export function isCommandHardBlocked(command: string): boolean {
  return Boolean(findBlockedReason(command));
}
