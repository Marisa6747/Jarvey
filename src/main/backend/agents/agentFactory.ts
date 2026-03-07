import {
  Agent,
  MCPServerStdio,
  type Tool,
  applyPatchTool,
  codeInterpreterTool,
  computerTool,
  fileSearchTool,
  imageGenerationTool,
  shellTool,
  webSearchTool
} from "@openai/agents";
import type { BackendTaskEvent, ToolRegistryConfig } from "../../../shared/types";
import type { MemoryStore } from "../memory/memoryStore";
import { HostEditor } from "../tools/hostEditor";
import { HostShell } from "../tools/hostShell";
import { NativeComputerBridge } from "../tools/nativeComputerBridge";
import { NativeComputer } from "../tools/nativeComputer";
import { streamEventToBackendEvent } from "./eventMapper";
import { buildMemoryTools } from "./memoryTools";

export interface AgentFactoryContext {
  memoryStore: MemoryStore;
  toolRegistry: ToolRegistryConfig;
  workingDirectory: string;
  onEvent: (event: BackendTaskEvent) => void;
  taskId: string;
}

export interface BuiltAgents {
  operatorSupervisor: Agent;
  close: () => Promise<void>;
}

const sharedBridge = new NativeComputerBridge();

async function connectConfiguredMcpServers(config: ToolRegistryConfig) {
  const servers = config.mcpServers
    .filter((server) => server.enabled)
    .map(
      (server) =>
        new MCPServerStdio({
          name: server.label,
          fullCommand: server.fullCommand,
          cwd: server.cwd
        })
    );

  for (const server of servers) {
    await server.connect();
  }

  return servers;
}

export async function buildAgents(context: AgentFactoryContext): Promise<BuiltAgents> {
  const memoryTools = buildMemoryTools(context.memoryStore);
  const mcpServers = await connectConfiguredMcpServers(context.toolRegistry);
  const hostShell = new HostShell(context.workingDirectory);
  const hostEditor = new HostEditor(context.workingDirectory);

  const computerAgent = new Agent({
    name: "ComputerUseAgent",
    model: "gpt-5.4",
    handoffDescription:
      "Controls the macOS GUI using screenshots, pointer actions, keypresses, and typing. Use it for opening apps, interacting with windows, or any on-screen task.",
    instructions: `
You are the GUI specialist.
Use computer control for macOS tasks.
Narrate intent briefly in your reasoning, keep final responses concise, and avoid making assumptions about on-screen state without fresh screenshots.
Prefer direct on-screen interactions over keyboard-only navigation whenever possible.
Do not rely on customizable macOS global shortcuts such as CMD+SPACE or CMD+TAB to open or switch apps unless the user explicitly asks for that shortcut.
After any action that could change focus, the active app, or the visible window, request a fresh screenshot before typing more text or issuing more shortcuts.
If the computer tool reports missing Screen Recording or Accessibility permission, stop GUI work immediately, tell the user what permission is missing, and do not retry the same screenshot or input action in a loop.
Do not use shell commands, web search, or patch tools. Use only the computer tool and durable memory tools.
`,
    tools: [
      computerTool({
        name: "computer",
        computer: async () => new NativeComputer(sharedBridge),
        onSafetyCheck: async () => true
      })
    ]
  });

  const workbenchTools: Tool[] = [
    shellTool({
      shell: hostShell
    }),
    applyPatchTool({
      editor: hostEditor
    }),
    memoryTools.searchMemory,
    memoryTools.saveMemory,
    memoryTools.forgetMemory
  ];

  if (context.toolRegistry.enableWebSearch) {
    workbenchTools.push(webSearchTool());
  }
  if (context.toolRegistry.enableCodeInterpreter) {
    workbenchTools.push(codeInterpreterTool());
  }
  if (context.toolRegistry.enableImageGeneration) {
    workbenchTools.push(imageGenerationTool());
  }
  if (context.toolRegistry.vectorStoreIds.length) {
    workbenchTools.push(fileSearchTool(context.toolRegistry.vectorStoreIds));
  }

  const workbenchAgent = new Agent({
    name: "WorkbenchAgent",
    model: "gpt-5.4",
    handoffDescription:
      "Handles coding, shell commands, patching files, research, and any non-GUI work on the host machine.",
    instructions: `
You are the workbench specialist.
Use shell and patch tools carefully.
Every mutation still needs approval, so batch related edits logically instead of producing noisy tool spam.
Avoid destructive or irreversible host operations.
Use durable memory only for stable preferences or defaults.
`,
    tools: workbenchTools,
    mcpServers
  });

  const emitSpecialistEvent = async (
    nestedEvent: { event: Parameters<typeof streamEventToBackendEvent>[1] },
    specialistName: string
  ) => {
    const mapped = streamEventToBackendEvent(
      context.taskId,
      nestedEvent.event,
      specialistName
    );
    if (mapped) {
      context.onEvent(mapped);
    }
  };

  const computerSpecialist = computerAgent.asTool({
    toolName: "computer_specialist",
    toolDescription:
      "Delegate a subtask that must operate the GUI through screenshots, pointer movement, clicks, typing, scrolling, or keyboard shortcuts.",
    runOptions: { maxTurns: 100 },
    onStream: async (nestedEvent) => emitSpecialistEvent(nestedEvent, "computer_specialist")
  });

  const workbenchSpecialist = workbenchAgent.asTool({
    toolName: "workbench_specialist",
    toolDescription:
      "Delegate a subtask that needs shell access, patching files, hosted OpenAI tools, or configured MCP servers.",
    runOptions: { maxTurns: 100 },
    onStream: async (nestedEvent) => emitSpecialistEvent(nestedEvent, "workbench_specialist")
  });

  const operatorSupervisor = new Agent({
    name: "OperatorSupervisor",
    model: "gpt-5.4",
    handoffDescription:
      "Supervises specialist agents and combines GUI, shell, patching, research, and memory work into one coherent execution plan.",
    instructions: `
You are the supervisor for a fully capable desktop operator.
Break work into the smallest sensible chunks and choose the right specialist:
- Use computer_specialist for anything that must control the GUI.
- Use workbench_specialist for shell, coding, file edits, web research, code interpreter, image generation, or configured MCP tools.
- Use both specialists if the task spans GUI and workbench work.
Keep the final answer brief and outcome-oriented.
Do not claim work was completed unless a specialist or tool result confirms it.
`,
    tools: [
      computerSpecialist,
      workbenchSpecialist,
      memoryTools.searchMemory,
      memoryTools.saveMemory,
      memoryTools.forgetMemory
    ]
  });

  return {
    operatorSupervisor,
    close: async () => {
      await Promise.all(mcpServers.map((server) => server.close()));
    }
  };
}
