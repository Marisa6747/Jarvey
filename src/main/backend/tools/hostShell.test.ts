import { describe, expect, it } from "vitest";
import { isCommandHardBlocked } from "./hostShell";

describe("isCommandHardBlocked", () => {
  it("blocks destructive erase commands", () => {
    expect(isCommandHardBlocked("rm -rf /")).toBe(true);
    expect(isCommandHardBlocked("diskutil eraseDisk APFS TEST disk3")).toBe(true);
  });

  it("allows ordinary inspection commands", () => {
    expect(isCommandHardBlocked("pwd")).toBe(false);
    expect(isCommandHardBlocked("ls -la ~/Desktop")).toBe(false);
  });
});
