// Builds limita-cli and puts it where Tauri's `externalBin` expects it:
// src-tauri/binaries/limita-cli-<target triple>[.exe]. Tauri installs it next to the app.
import { execFileSync } from "node:child_process";
import { copyFileSync, mkdirSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const release = process.argv.includes("--release");
const workspace = join(dirname(fileURLToPath(import.meta.url)), "..", "..");
const host = execFileSync("rustc", ["-vV"], { encoding: "utf8" }).match(/^host: (.+)$/m)[1];
const triple = process.env.TAURI_ENV_TARGET_TRIPLE || host;
const exe = triple.includes("windows") ? ".exe" : "";

const args = ["build", "-p", "limita-cli"];
if (release) args.push("--release");
if (triple !== host) args.push("--target", triple);
execFileSync("cargo", args, { cwd: workspace, stdio: "inherit" });

const profile = release ? "release" : "debug";
const built = join(workspace, "target", ...(triple !== host ? [triple] : []), profile, `limita-cli${exe}`);
const binaries = join(workspace, "app", "src-tauri", "binaries");
mkdirSync(binaries, { recursive: true });
copyFileSync(built, join(binaries, `limita-cli-${triple}${exe}`));
