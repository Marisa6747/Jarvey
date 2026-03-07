import fs from "node:fs";
import path from "node:path";
import { resolveApplicationSupportRoot } from "../../shared/appIdentity";
import { defaultSettings } from "../../shared/defaults";
import type { SettingsData, SettingsUpdate, ToolRegistryConfig } from "../../shared/types";

export class FileSettingsStore {
  private readonly settingsPath: string;

  constructor(private readonly rootDirectory = resolveApplicationSupportRoot()) {
    this.settingsPath = path.join(this.rootDirectory, "config", "settings.json");
    fs.mkdirSync(path.dirname(this.settingsPath), { recursive: true });
    if (!fs.existsSync(this.settingsPath)) {
      fs.writeFileSync(this.settingsPath, JSON.stringify(defaultSettings, null, 2));
    }

    const apiKey = this.get().apiKey || process.env.OPENAI_API_KEY || "";
    if (apiKey) {
      process.env.OPENAI_API_KEY = apiKey;
    }
  }

  get dataDirectory(): string {
    return this.rootDirectory;
  }

  get(): SettingsData {
    const raw = this.readFile();
    return {
      ...defaultSettings,
      ...raw,
      toolRegistry: {
        ...defaultSettings.toolRegistry,
        ...(raw.toolRegistry ?? {})
      }
    };
  }

  update(update: SettingsUpdate): SettingsData {
    const current = this.get();
    const mergedToolRegistry: ToolRegistryConfig = {
      ...current.toolRegistry,
      ...(update.toolRegistry ?? {})
    };
    const next: SettingsData = {
      ...current,
      ...update,
      toolRegistry: mergedToolRegistry
    };

    fs.writeFileSync(this.settingsPath, JSON.stringify(next, null, 2));
    if (next.apiKey) {
      process.env.OPENAI_API_KEY = next.apiKey;
    }
    return next;
  }

  private readFile(): Partial<SettingsData> {
    try {
      const raw = fs.readFileSync(this.settingsPath, "utf8");
      return JSON.parse(raw) as Partial<SettingsData>;
    } catch {
      return {};
    }
  }
}
