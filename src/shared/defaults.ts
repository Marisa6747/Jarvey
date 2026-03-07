import type { SettingsData } from "./types";

export const defaultSettings: SettingsData = {
  apiKey: "",
  hotkey: "Alt+Space",
  voice: "marin",
  debugMode: false,
  toolRegistry: {
    enableWebSearch: true,
    enableCodeInterpreter: true,
    enableImageGeneration: true,
    vectorStoreIds: [],
    mcpServers: []
  }
};
