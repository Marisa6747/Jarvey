import { tool } from "@openai/agents";
import {
  RealtimeAgent,
  RealtimeSession,
  OpenAIRealtimeWebSocket,
  type RealtimeClientMessage,
  type RealtimeItem,
  type RealtimeSessionEventTypes
} from "@openai/agents/realtime";
import type {
  SettingsData,
  TranscriptEntry
} from "../shared/types";
import {
  forgetMemoryToolParameters,
  parseForgetMemoryToolInput,
  parseSaveMemoryToolInput,
  parseSearchMemoryToolInput,
  parseStartBackendTaskToolInput,
  saveMemoryToolParameters,
  searchMemoryToolParameters,
  startBackendTaskToolParameters
} from "../shared/toolSchemas";

type RealtimeApprovalRequest = RealtimeSessionEventTypes["tool_approval_requested"][2];

type VoiceApprovalRequest = {
  id: string;
  title: string;
  detail?: string;
  request: RealtimeApprovalRequest;
};

type VoicePhase =
  | "idle"
  | "connecting"
  | "listening"
  | "thinking"
  | "speaking"
  | "acting"
  | "approvals"
  | "error";

type Command =
  | { type: "connect"; muted?: boolean }
  | { type: "close" }
  | { type: "interrupt" }
  | { type: "setMuted"; muted: boolean }
  | { type: "approveApproval"; alwaysApprove?: boolean }
  | { type: "rejectApproval"; message?: string; alwaysReject?: boolean };

type SettingsPatch = {
  apiKey?: string;
};

type MemoryRecord = {
  id: string;
  kind: string;
  subject: string;
  content: string;
};

type MemoryPolicyResult = {
  decision: "allow" | "approval_required" | "block";
  reason: string;
  normalizedTags: string[];
};

type BackendTaskResult = {
  taskId: string;
  summary: string;
  outputText: string;
  agent: string;
  completedAt: string;
};

type MemorySaveResponse = {
  status: "saved" | "saved_after_approval" | "blocked";
  reason: string;
  memory?: MemoryRecord;
};

declare global {
  interface Window {
    webkit?: {
      messageHandlers?: {
        jarveyVoice?: {
          postMessage: (payload: unknown) => void;
        };
      };
    };
    jarveyVoiceBridge?: {
      receive: (command: Command) => Promise<unknown>;
    };
  }
}

const SIDECAR_BASE =
  (globalThis as { __JARVEY_SIDECAR_BASE__?: string }).__JARVEY_SIDECAR_BASE__ ??
  "http://127.0.0.1:4818";

const SAMPLE_RATE = 24000;

let session: RealtimeSession | null = null;
let connectPromise: Promise<void> | null = null;
let activeApproval: VoiceApprovalRequest["request"] | null = null;
let phase: VoicePhase = "idle";
let currentAgent = "ConversationAgent";
let connected = false;
let muted = false;
let transcriptHistory: TranscriptEntry[] = [];
let level = 0;
const timestampCache = new Map<string, string>();
let levelSmoothed = 0;

// Audio I/O state
let micStream: MediaStream | null = null;
let inputAudioContext: AudioContext | null = null;
let inputProcessor: ScriptProcessorNode | null = null;
let inputAnalyser: AnalyserNode | null = null;
let inputAnalyserData: Uint8Array<ArrayBuffer> | null = null;
let levelIntervalId: number | null = null;
let playbackContext: AudioContext | null = null;
let playbackNextTime = 0;
let speechDetectedSinceUnmute = false;

async function withTimeout<T>(
  promise: Promise<T>,
  timeoutMs: number,
  message: string
): Promise<T> {
  return await Promise.race([
    promise,
    new Promise<T>((_resolve, reject) => {
      window.setTimeout(() => {
        reject(new Error(message));
      }, timeoutMs);
    })
  ]);
}

function extractErrorMessage(error: unknown): string {
  if (error instanceof Error) {
    return error.message;
  }
  if (typeof error === "object" && error !== null) {
    const obj = error as Record<string, unknown>;
    // API error: { type: "error", error: { type, message, code, param } }
    if (typeof obj.error === "object" && obj.error !== null) {
      const inner = obj.error as Record<string, unknown>;
      if (typeof inner.message === "string") {
        return inner.message;
      }
      // Double-nested: transport wraps API events
      if (typeof inner.error === "object" && inner.error !== null) {
        const deep = inner.error as Record<string, unknown>;
        if (typeof deep.message === "string") {
          return deep.message;
        }
      }
    }
    if (typeof obj.message === "string") {
      return obj.message;
    }
  }
  if (typeof error === "string") {
    return error;
  }
  try {
    return JSON.stringify(error).slice(0, 300);
  } catch {
    return "Realtime session failed.";
  }
}

function postMessage(type: string, payload?: Record<string, unknown>) {
  window.webkit?.messageHandlers?.jarveyVoice?.postMessage({
    type,
    ...(payload ?? {})
  });
}

function postState() {
  postMessage("state", {
    connected,
    muted,
    phase,
    currentAgent,
    level
  });
}

function setPhase(nextPhase: VoicePhase) {
  phase = nextPhase;
  postState();
}

function setConnected(nextConnected: boolean) {
  connected = nextConnected;
  postState();
}

function setMuted(nextMuted: boolean) {
  muted = nextMuted;
  if (muted) {
    setLevel(0);
  } else {
    speechDetectedSinceUnmute = false;
  }
  postState();
}

function setAgent(nextAgent: string) {
  currentAgent = nextAgent;
  postState();
}

function setLevel(nextLevel: number) {
  const normalized = Math.max(0, Math.min(1, Number.isFinite(nextLevel) ? nextLevel : 0));
  if (Math.abs(normalized - level) < 0.015) {
    return;
  }
  level = normalized;
  postState();
}

function phaseFloor(currentPhase: VoicePhase): number {
  switch (currentPhase) {
    case "connecting":
      return 0.16;
    case "thinking":
      return 0.22;
    case "speaking":
      return 0.46;
    case "acting":
      return 0.3;
    case "approvals":
      return 0.12;
    default:
      return 0;
  }
}

async function requestJson<T>(
  path: string,
  init?: RequestInit
): Promise<T> {
  const response = await fetch(`${SIDECAR_BASE}${path}`, {
    ...init,
    headers: {
      "Content-Type": "application/json",
      ...(init?.headers ?? {})
    }
  });

  if (!response.ok) {
    const text = await response.text();
    throw new Error(text || `Request failed for ${path} (${response.status})`);
  }

  return (await response.json()) as T;
}

function itemText(item: RealtimeItem): string {
  if (item.type !== "message") {
    return "";
  }

  return item.content
    .map((contentPart) => {
      if ("text" in contentPart && typeof contentPart.text === "string") {
        return contentPart.text;
      }
      if ("transcript" in contentPart && contentPart.transcript) {
        return contentPart.transcript;
      }
      return "";
    })
    .join(" ")
    .trim();
}

function buildTranscriptHistory(history: RealtimeItem[]): TranscriptEntry[] {
  return history
    .filter((item): item is Extract<RealtimeItem, { type: "message" }> => item.type === "message")
    .map((item) => {
      const timestamp = timestampCache.get(item.itemId) ?? new Date().toISOString();
      timestampCache.set(item.itemId, timestamp);
      const role: TranscriptEntry["role"] =
        item.role === "assistant"
          ? "assistant"
          : item.role === "user"
            ? "user"
            : "system";
      return {
        id: item.itemId,
        role,
        text: itemText(item),
        timestamp
      };
    })
    .filter((entry) => entry.text.length > 0);
}

function approvalSummary(
  approval: VoiceApprovalRequest["request"]
): { title: string; detail?: string } {
  if (approval.type === "function_approval") {
    const rawItem = approval.approvalItem.rawItem;
    return {
      title: `Approve ${approval.tool?.name ?? "tool"}`,
      detail: "arguments" in rawItem ? rawItem.arguments : undefined
    };
  }

  return {
    title: "Approve MCP tool call",
    detail: approval.approvalItem.arguments
  };
}

function emitTranscript(entries: TranscriptEntry[]) {
  transcriptHistory = entries;
  postMessage("transcript", {
    entries
  });
}

function emitRealtimeApproval(approval: VoiceApprovalRequest | null) {
  postMessage("realtimeApproval", {
    approval: approval
      ? {
          id: approval.id,
          title: approval.title,
          detail: approval.detail
        }
      : null
  });
}

async function fetchSettings(): Promise<SettingsData> {
  return await requestJson<SettingsData>("/settings");
}

// ---------------------------------------------------------------------------
// Audio helpers - manual I/O for WebSocket transport
// ---------------------------------------------------------------------------

function float32ToPcm16(float32: Float32Array): ArrayBuffer {
  const pcm16 = new Int16Array(float32.length);
  for (let i = 0; i < float32.length; i++) {
    const sample = Math.max(-1, Math.min(1, float32[i]));
    pcm16[i] = sample < 0 ? sample * 0x8000 : sample * 0x7fff;
  }
  return pcm16.buffer;
}

function float32Rms(float32: Float32Array): number {
  let sum = 0;
  for (let i = 0; i < float32.length; i++) {
    const sample = float32[i];
    sum += sample * sample;
  }
  return Math.sqrt(sum / float32.length);
}

function pcm16ToFloat32(pcm16: ArrayBuffer): Float32Array {
  const int16 = new Int16Array(pcm16);
  const float32 = new Float32Array(int16.length);
  for (let i = 0; i < int16.length; i++) {
    float32[i] = int16[i] / (int16[i] < 0 ? 0x8000 : 0x7fff);
  }
  return float32;
}

function playAudioChunk(float32: Float32Array) {
  if (!playbackContext) {
    return;
  }

  const buffer = playbackContext.createBuffer(1, float32.length, SAMPLE_RATE);
  buffer.getChannelData(0).set(float32);
  const source = playbackContext.createBufferSource();
  source.buffer = buffer;
  source.connect(playbackContext.destination);

  const now = playbackContext.currentTime;
  if (playbackNextTime < now) {
    playbackNextTime = now;
  }
  source.start(playbackNextTime);
  playbackNextTime += buffer.duration;
}

async function startAudioIO() {
  playbackContext = new AudioContext({ sampleRate: SAMPLE_RATE });
  playbackNextTime = 0;

  if (session) {
    session.transport.on("audio", (event: { data: ArrayBuffer }) => {
      const float32 = pcm16ToFloat32(event.data);
      playAudioChunk(float32);
    });
  }

  micStream = await withTimeout(
    navigator.mediaDevices.getUserMedia({
      audio: {
        sampleRate: SAMPLE_RATE,
        channelCount: 1,
        echoCancellation: true,
        noiseSuppression: true,
        autoGainControl: true
      }
    }),
    5_000,
    "Timed out waiting for microphone access."
  );

  inputAudioContext = new AudioContext({ sampleRate: SAMPLE_RATE });
  const source = inputAudioContext.createMediaStreamSource(micStream);

  inputAnalyser = inputAudioContext.createAnalyser();
  inputAnalyser.fftSize = 256;
  source.connect(inputAnalyser);
  inputAnalyserData = new Uint8Array(new ArrayBuffer(inputAnalyser.frequencyBinCount));

  inputProcessor = inputAudioContext.createScriptProcessor(4096, 1, 1);
  source.connect(inputProcessor);
  inputProcessor.connect(inputAudioContext.destination);
  inputProcessor.onaudioprocess = (event) => {
    if (!session || muted || phase === "speaking") {
      return;
    }

    const float32 = event.inputBuffer.getChannelData(0);
    const rms = float32Rms(float32);
    if (rms > 0.018) {
      speechDetectedSinceUnmute = true;
      if (phase === "idle") {
        setPhase("listening");
      }
    }

    const pcmBuffer = float32ToPcm16(float32);
    session.sendAudio(pcmBuffer);
  };

  levelIntervalId = window.setInterval(() => {
    if (!inputAnalyser || !inputAnalyserData || muted) {
      setLevel(phaseFloor(phase));
      return;
    }

    inputAnalyser.getByteTimeDomainData(inputAnalyserData);
    let sum = 0;
    for (const value of inputAnalyserData) {
      const centered = (value - 128) / 128;
      sum += centered * centered;
    }
    const rms = Math.sqrt(sum / inputAnalyserData.length);
    levelSmoothed = Math.max(rms * 3.6, levelSmoothed * 0.78);
    const composite = Math.max(levelSmoothed, phaseFloor(phase));
    setLevel(composite);
  }, 80);
}

async function stopAudioIO() {
  if (levelIntervalId !== null) {
    window.clearInterval(levelIntervalId);
    levelIntervalId = null;
  }

  if (inputProcessor) {
    inputProcessor.onaudioprocess = null;
    inputProcessor.disconnect();
    inputProcessor = null;
  }

  inputAnalyser = null;
  inputAnalyserData = null;

  if (micStream) {
    for (const track of micStream.getTracks()) {
      track.stop();
    }
    micStream = null;
  }

  if (inputAudioContext) {
    await inputAudioContext.close().catch(() => undefined);
    inputAudioContext = null;
  }

  if (playbackContext) {
    await playbackContext.close().catch(() => undefined);
    playbackContext = null;
  }

  playbackNextTime = 0;
  levelSmoothed = 0;
  speechDetectedSinceUnmute = false;
  setLevel(0);
}

// ---------------------------------------------------------------------------
// Session event wiring
// ---------------------------------------------------------------------------

function attachSession(nextSession: RealtimeSession) {
  nextSession.on("history_updated", (history) => {
    emitTranscript(buildTranscriptHistory(history));
  });

  nextSession.on("agent_start", (_context, agent) => {
    setAgent(agent.name);
    speechDetectedSinceUnmute = false;
    setPhase("thinking");
  });

  nextSession.on("agent_end", (_context, agent) => {
    setAgent(agent.name);
    if (phase !== "speaking" && phase !== "acting") {
      setPhase("idle");
    }
  });

  nextSession.on("agent_handoff", (_context, _fromAgent, toAgent) => {
    setAgent(toAgent.name);
    setPhase("thinking");
  });

  nextSession.on("agent_tool_start", (_context, _agent, toolDef) => {
    setPhase(toolDef.name === "start_backend_task" ? "acting" : "thinking");
  });

  nextSession.on("agent_tool_end", (_context, _agent, toolDef) => {
    setPhase(toolDef.name === "start_backend_task" ? "speaking" : "listening");
  });

  nextSession.on("audio_start", () => {
    setPhase("speaking");
  });

  nextSession.on("audio_stopped", () => {
    setPhase("idle");
  });

  nextSession.on("audio_interrupted", () => {
    setPhase("listening");
    playbackNextTime = 0;
  });

  nextSession.on("tool_approval_requested", (_context, _agent, approvalRequest) => {
    activeApproval = approvalRequest;
    const summary = approvalSummary(approvalRequest);
    const approval: VoiceApprovalRequest = {
      id:
        approvalRequest.approvalItem.rawItem.id ??
        ("callId" in approvalRequest.approvalItem.rawItem
          ? approvalRequest.approvalItem.rawItem.callId
          : undefined) ??
        crypto.randomUUID(),
      title: summary.title,
      detail: summary.detail,
      request: approvalRequest
    };
    emitRealtimeApproval(approval);
    setPhase("approvals");
  });

  nextSession.on("error", ({ error }) => {
    const message = extractErrorMessage(error);
    postMessage("error", { message });
  });
}

// ---------------------------------------------------------------------------
// Connect / disconnect
// ---------------------------------------------------------------------------

async function connect(initialMuted = false) {
  if (session) {
    return;
  }

  if (connectPromise) {
    return await connectPromise;
  }

  connectPromise = (async () => {
    const currentSettings = await fetchSettings();
    if (!currentSettings.apiKey) {
      throw new Error("OpenAI API key is not configured.");
    }

    setPhase("connecting");

    const searchMemoryTool = tool({
      name: "search_memory",
      description:
        "Search durable memories such as preferences, environment facts, aliases, safe macros, and workflow defaults.",
      parameters: searchMemoryToolParameters,
      execute: async (input) => {
        const normalizedInput = parseSearchMemoryToolInput(input);
        const memories = await requestJson<MemoryRecord[]>("/memory/search", {
          method: "POST",
          body: JSON.stringify(normalizedInput)
        });
        return {
          count: memories.length,
          memories
        };
      }
    });

    const saveMemoryTool = tool({
      name: "save_memory",
      description:
        "Save stable preferences, aliases, environment facts, workflow defaults, or safe macros into durable memory. Never store secrets or raw captured content.",
      parameters: saveMemoryToolParameters,
      needsApproval: async (_runContext, input) => {
        const normalizedInput = parseSaveMemoryToolInput(input);
        const policy = await requestJson<MemoryPolicyResult>("/memory/classify", {
          method: "POST",
          body: JSON.stringify(normalizedInput)
        });
        return policy.decision === "approval_required";
      },
      execute: async (input) => {
        const normalizedInput = parseSaveMemoryToolInput(input);
        const result = await requestJson<MemorySaveResponse>("/memory/save", {
          method: "POST",
          body: JSON.stringify(normalizedInput)
        });
        if (result.memory) {
          postMessage("memoryChanged");
        }
        return result;
      }
    });

    const forgetMemoryTool = tool({
      name: "forget_memory",
      description:
        "Delete a durable memory when the user explicitly asks you to forget or correct something.",
      parameters: forgetMemoryToolParameters,
      needsApproval: true,
      execute: async (input) => {
        const normalizedInput = parseForgetMemoryToolInput(input);
        const deleted = await requestJson<MemoryRecord[]>("/memory/forget", {
          method: "POST",
          body: JSON.stringify(normalizedInput)
        });
        postMessage("memoryChanged");
        return {
          deletedCount: deleted.length,
          deleted
        };
      }
    });

    const startBackendTaskTool = tool({
      name: "start_backend_task",
      description:
        "Invoke the backend supervisor when the user wants the computer to do real work such as GUI automation, coding, patching files, or combined tasks.",
      parameters: startBackendTaskToolParameters,
      execute: async (input) => {
        const { request, activeAppHint } = parseStartBackendTaskToolInput(input);
        setPhase("acting");
        const recentMemories = await requestJson<MemoryRecord[]>("/memory/recent?limit=6");
        const taskId = crypto.randomUUID();
        postMessage("taskState", {
          taskId
        });
        const result = await requestJson<BackendTaskResult>("/backend/tasks/run", {
          method: "POST",
          body: JSON.stringify({
            requestId: taskId,
            userRequest: request,
            transcriptHistory,
            activeAppHint,
            memoryContext: recentMemories
              .slice(0, 6)
              .map((memory) => `[${memory.kind}] ${memory.subject}: ${memory.content}`)
              .join("\n")
          })
        });
        postMessage("taskState", {
          taskId: null
        });
        setPhase("speaking");
        return {
          taskId: result.taskId,
          summary: result.summary,
          agent: result.agent
        };
      }
    });

    const conversationAgent = new RealtimeAgent({
      name: "ConversationAgent",
      voice: currentSettings.voice,
      handoffDescription:
        "Handles natural voice conversation, memory capture, and front-door user requests before a machine task begins.",
      instructions: `
You are Jarvey, a voice-first macOS assistant running on the user's Mac.
Speak clearly and briefly.

You have FULL access to the user's computer through the start_backend_task tool. This tool launches a backend operator agent that can:
- Control the mouse and keyboard (click, type, scroll, drag)
- Take screenshots and see what's on screen
- Open and use ANY application (Safari, Finder, Terminal, VS Code, etc.)
- Run shell commands and scripts
- Edit files, write code, manage folders
- Automate multi-step workflows across apps

When the user asks you to DO something on their computer (open an app, search the web, write a file, move windows, edit a document, run code, etc.), call start_backend_task immediately. Do NOT say you can't do it. You CAN do it through the backend operator.

Use memory tools when the user shares stable preferences or defaults.
Do not claim you personally clicked or typed - say the backend operator handled it.
`,
      handoffs: [],
      tools: [searchMemoryTool, saveMemoryTool, forgetMemoryTool, startBackendTaskTool]
    });

    const actionIntakeAgent = new RealtimeAgent({
      name: "ActionIntakeAgent",
      voice: currentSettings.voice,
      handoffDescription:
        "Clarifies the task, then launches backend execution for real machine work and reports outcomes back to the user.",
      instructions: `
You are the action intake specialist for Jarvey, a macOS assistant with full computer control.
You have the start_backend_task tool which launches a backend operator that can control the mouse, keyboard, take screenshots, run shell commands, open apps, edit files, and automate any workflow.
Clarify only what is needed to execute the task well.
Once the request is concrete enough, call start_backend_task with a clear description of what to do.
Use memory tools for stable user defaults that should persist.
Keep spoken summaries short and practical.
`,
      tools: [searchMemoryTool, saveMemoryTool, startBackendTaskTool]
    });

    conversationAgent.handoffs = [actionIntakeAgent];

    const clientSecret = await requestJson<{ value: string }>("/realtime/client-secret", {
      method: "POST",
      body: JSON.stringify({} as SettingsPatch)
    });
    if (!clientSecret.value) {
      throw new Error("Realtime client secret is missing.");
    }

    const transport = new OpenAIRealtimeWebSocket({
      useInsecureApiKey: true
    });

    const nextSession = new RealtimeSession(conversationAgent, {
      transport,
      model: "gpt-realtime",
      config: {
        outputModalities: ["audio"],
        audio: {
          input: {
            format: {
              type: "audio/pcm",
              rate: SAMPLE_RATE
            }
          },
          output: {
            format: {
              type: "audio/pcm",
              rate: SAMPLE_RATE
            },
            voice: currentSettings.voice
          }
        }
      }
    });

    attachSession(nextSession);
    session = nextSession;
    await startAudioIO();
    await nextSession.connect({
      apiKey: clientSecret.value,
      model: "gpt-realtime"
    });

    setConnected(true);
    setMuted(initialMuted);
    setPhase(initialMuted ? "idle" : "listening");
  })()
    .catch(async (error) => {
      const message = extractErrorMessage(error);
      postMessage("error", { message });
      await close();
      throw error;
    })
    .finally(() => {
      connectPromise = null;
    });

  return await connectPromise;
}

async function close() {
  await stopAudioIO();
  session?.close();
  session = null;
  activeApproval = null;
  speechDetectedSinceUnmute = false;
  emitRealtimeApproval(null);
  setConnected(false);
  setMuted(true);
  setPhase("idle");
}

function interrupt() {
  session?.interrupt();
  playbackNextTime = 0;
  setPhase("listening");
}

function setSessionMuted(nextMuted: boolean): boolean {
  const wasListening = connected && phase === "listening" && !muted;
  const shouldCommitTurn = nextMuted && wasListening && speechDetectedSinceUnmute;
  setMuted(nextMuted);
  if (!connected) {
    setPhase("idle");
    return muted;
  }
  if (shouldCommitTurn && session) {
    const commitEvent: RealtimeClientMessage = {
      type: "input_audio_buffer.commit"
    };
    session.transport.sendEvent(commitEvent);
    setPhase("thinking");
  } else if (nextMuted && wasListening) {
    setPhase("idle");
  } else if (!nextMuted && (phase === "idle" || phase === "connecting")) {
    setPhase("listening");
  } else if (nextMuted && phase === "listening") {
    setPhase("idle");
  }
  return muted;
}

async function approveApproval(alwaysApprove = false) {
  if (!session || !activeApproval) {
    return;
  }

  await session.approve(activeApproval.approvalItem, { alwaysApprove });
  activeApproval = null;
  emitRealtimeApproval(null);
  setPhase("thinking");
}

async function rejectApproval(message?: string, alwaysReject = false) {
  if (!session || !activeApproval) {
    return;
  }

  await session.reject(activeApproval.approvalItem, {
    alwaysReject,
    message
  });
  activeApproval = null;
  emitRealtimeApproval(null);
  setPhase("thinking");
}

window.jarveyVoiceBridge = {
  async receive(command: Command) {
    switch (command.type) {
      case "connect":
        await connect(command.muted ?? false);
        return null;
      case "close":
        await close();
        return null;
      case "interrupt":
        interrupt();
        return null;
      case "setMuted":
        return setSessionMuted(command.muted);
      case "approveApproval":
        await approveApproval(command.alwaysApprove ?? false);
        return null;
      case "rejectApproval":
        await rejectApproval(command.message, command.alwaysReject ?? false);
        return null;
      default:
        return null;
    }
  }
};

window.addEventListener("beforeunload", () => {
  void close();
});

postMessage("ready");
postState();
