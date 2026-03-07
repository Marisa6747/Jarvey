import { z } from "zod";
import {
  memoryKinds,
  type MemoryForgetInput,
  type MemorySaveInput,
  type MemorySearchInput
} from "./types";

const memoryKindSchema = z.enum(memoryKinds);

const nullableStringSchema = z.string().nullable();
const nullableStringArraySchema = z.array(z.string()).nullable();

const strictObject = <T extends Record<string, unknown>>(properties: T) => ({
  type: "object",
  properties,
  required: Object.keys(properties),
  additionalProperties: false
} as const);

export const searchMemoryToolParameters = strictObject({
  query: {
    type: "string",
    minLength: 1
  },
  kinds: {
    type: ["array", "null"],
    items: {
      type: "string",
      enum: [...memoryKinds]
    }
  },
  limit: {
    type: ["integer", "null"],
    minimum: 1,
    maximum: 25
  }
});

const searchMemoryToolInputSchema = z.object({
  query: z.string().min(1),
  kinds: z.array(memoryKindSchema).nullable(),
  limit: z.number().int().min(1).max(25).nullable()
});

export function parseSearchMemoryToolInput(input: unknown): MemorySearchInput {
  const parsed = searchMemoryToolInputSchema.parse(input);
  return {
    query: parsed.query,
    kinds: parsed.kinds ?? undefined,
    limit: parsed.limit ?? undefined
  };
}

export const saveMemoryToolParameters = strictObject({
  kind: {
    type: "string",
    enum: [...memoryKinds]
  },
  subject: {
    type: "string",
    minLength: 3
  },
  content: {
    type: "string",
    minLength: 3
  },
  confidence: {
    type: "number",
    minimum: 0,
    maximum: 1
  },
  source: {
    type: "string",
    minLength: 2
  },
  tags: {
    type: ["array", "null"],
    items: {
      type: "string"
    }
  }
});

const saveMemoryToolInputSchema = z.object({
  kind: memoryKindSchema,
  subject: z.string().min(3),
  content: z.string().min(3),
  confidence: z.number().min(0).max(1),
  source: z.string().min(2),
  tags: nullableStringArraySchema
});

export function parseSaveMemoryToolInput(input: unknown): MemorySaveInput {
  const parsed = saveMemoryToolInputSchema.parse(input);
  return {
    ...parsed,
    tags: parsed.tags ?? undefined
  };
}

export const forgetMemoryToolParameters = strictObject({
  id: {
    type: ["string", "null"]
  },
  query: {
    type: ["string", "null"]
  }
});

const forgetMemoryToolInputSchema = z.object({
  id: nullableStringSchema,
  query: nullableStringSchema
});

export function parseForgetMemoryToolInput(input: unknown): MemoryForgetInput {
  const parsed = forgetMemoryToolInputSchema.parse(input);
  return {
    id: parsed.id ?? undefined,
    query: parsed.query ?? undefined
  };
}

export const startBackendTaskToolParameters = strictObject({
  request: {
    type: "string",
    minLength: 3
  },
  activeAppHint: {
    type: ["string", "null"]
  }
});

const startBackendTaskToolInputSchema = z.object({
  request: z.string().min(3),
  activeAppHint: nullableStringSchema
});

export function parseStartBackendTaskToolInput(input: unknown): {
  request: string;
  activeAppHint?: string;
} {
  const parsed = startBackendTaskToolInputSchema.parse(input);
  return {
    request: parsed.request,
    activeAppHint: parsed.activeAppHint ?? undefined
  };
}
