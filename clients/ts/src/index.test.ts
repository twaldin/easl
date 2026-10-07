// bun test clients/ts — where a client with no EASL_SOCKET looks: the app's socket on macOS, easld's
// (its home: $EASL_HOME, else $XDG_STATE_HOME/easl, else ~/.local/state/easl) everywhere else.
import { expect, test } from "bun:test";
import { defaultSocket } from "./index";

test("the default socket is the app's on macOS and easld's elsewhere", () => {
  expect(defaultSocket("darwin", {}, "/Users/tim")).toBe("/Users/tim/Library/Application Support/Easl/easl.sock");
  expect(defaultSocket("darwin", { XDG_STATE_HOME: "/srv/state" }, "/Users/tim")).toBe("/Users/tim/Library/Application Support/Easl/easl.sock");
  expect(defaultSocket("linux", {}, "/home/tim")).toBe("/home/tim/.local/state/easl/easl.sock");
  expect(defaultSocket("linux", { XDG_STATE_HOME: "/srv/state" }, "/home/tim")).toBe("/srv/state/easl/easl.sock");
  expect(defaultSocket("linux", { EASL_HOME: "/srv/easl", XDG_STATE_HOME: "/srv/state" }, "/home/tim")).toBe("/srv/easl/easl.sock");
  expect(defaultSocket("linux", { EASL_HOME: "", XDG_STATE_HOME: "" }, "/home/tim")).toBe("/home/tim/.local/state/easl/easl.sock");
});
