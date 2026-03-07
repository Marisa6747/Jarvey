import fs from "node:fs";
import os from "node:os";
import path from "node:path";

export const APP_NAME = "Jarvey";

export function resolveApplicationSupportRoot(): string {
  const baseDirectory = path.join(os.homedir(), "Library", "Application Support");
  return path.join(baseDirectory, APP_NAME);
}

export function resolveAppLogsDirectory(): string {
  const logsDirectory = path.join(resolveApplicationSupportRoot(), "logs");
  fs.mkdirSync(logsDirectory, { recursive: true });
  return logsDirectory;
}
