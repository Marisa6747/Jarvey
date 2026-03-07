import { describe, expect, it } from "vitest";
import {
  forgetMemoryToolParameters,
  parseForgetMemoryToolInput,
  parseSaveMemoryToolInput,
  parseSearchMemoryToolInput,
  parseStartBackendTaskToolInput,
  saveMemoryToolParameters,
  searchMemoryToolParameters,
  startBackendTaskToolParameters
} from "./toolSchemas";

describe("toolSchemas", () => {
  it("marks every declared property as required for strict OpenAI tool schemas", () => {
    const schemas = [
      searchMemoryToolParameters,
      saveMemoryToolParameters,
      forgetMemoryToolParameters,
      startBackendTaskToolParameters
    ];

    for (const schema of schemas) {
      expect(schema.additionalProperties).toBe(false);
      expect([...schema.required].sort()).toEqual(
        Object.keys(schema.properties).sort()
      );
    }
  });

  it("normalizes nullable search and save inputs before downstream use", () => {
    expect(
      parseSearchMemoryToolInput({
        query: "terminal theme",
        kinds: null,
        limit: null
      })
    ).toEqual({
      query: "terminal theme",
      kinds: undefined,
      limit: undefined
    });

    expect(
      parseSaveMemoryToolInput({
        kind: "preference",
        subject: "Terminal theme",
        content: "Use Solarized Dark",
        confidence: 0.9,
        source: "voice",
        tags: null
      })
    ).toEqual({
      kind: "preference",
      subject: "Terminal theme",
      content: "Use Solarized Dark",
      confidence: 0.9,
      source: "voice",
      tags: undefined
    });
  });

  it("normalizes nullable forget and backend task inputs", () => {
    expect(
      parseForgetMemoryToolInput({
        id: null,
        query: "nickname"
      })
    ).toEqual({
      id: undefined,
      query: "nickname"
    });

    expect(
      parseStartBackendTaskToolInput({
        request: "Open Notes",
        activeAppHint: null
      })
    ).toEqual({
      request: "Open Notes",
      activeAppHint: undefined
    });
  });
});
