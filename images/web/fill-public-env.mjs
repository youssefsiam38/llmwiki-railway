// Write the deployment's public values into LLM Wiki's built web app.
//
// Next.js inlines every NEXT_PUBLIC_* variable into the server and browser bundles at build time.
// This image is built once, with placeholders, and this script replaces them at start-up.
//
//   --index <app dir> <pristine dir>     build time: find every built file that carries a
//                                        placeholder, keep a pristine copy of it, list it
//   (no arguments)                       start-up: rewrite each listed file from its pristine copy
//
// Working from the pristine copy every time makes the result depend only on the current values, so
// a restart with a changed domain writes the new one instead of finding nothing left to replace.
// Files are read and written as latin1, which round-trips every byte, so a non-text file that
// happens to contain a placeholder is not corrupted.
import { copyFileSync, mkdirSync, readdirSync, readFileSync, statSync, writeFileSync } from "node:fs";
import { dirname, join, relative } from "node:path";

const PLACEHOLDERS = {
  NEXT_PUBLIC_SUPABASE_URL: "https://llmwiki-railway-placeholder-supabase-url.invalid",
  NEXT_PUBLIC_SUPABASE_ANON_KEY: "llmwiki-railway-placeholder-supabase-anon-key",
  NEXT_PUBLIC_API_URL: "https://llmwiki-railway-placeholder-api-url.invalid",
  NEXT_PUBLIC_MCP_URL: "https://llmwiki-railway-placeholder-mcp-url.invalid/mcp",
};
const MARKER = "llmwiki-railway-placeholder-";

// Every value lands inside a JavaScript string literal or JSON. Anything outside these shapes is
// refused rather than escaped, so no value can break out of the literal it is written into.
const SHAPES = {
  NEXT_PUBLIC_SUPABASE_URL: /^https?:\/\/[A-Za-z0-9.-]+(:[0-9]{1,5})?$/,
  NEXT_PUBLIC_SUPABASE_ANON_KEY: /^[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+$/,
  NEXT_PUBLIC_API_URL: /^https?:\/\/[A-Za-z0-9.-]+(:[0-9]{1,5})?$/,
  NEXT_PUBLIC_MCP_URL: /^https?:\/\/[A-Za-z0-9.-]+(:[0-9]{1,5})?\/mcp$/,
};

const die = (msg) => {
  process.stderr.write(`[llmwiki-web] FATAL: ${msg}\n`);
  process.exit(1);
};

function* walk(dir) {
  for (const entry of readdirSync(dir, { withFileTypes: true })) {
    const path = join(dir, entry.name);
    if (entry.isDirectory()) yield* walk(path);
    else if (entry.isFile()) yield path;
  }
}

function buildIndex(nextDir, pristineDir) {
  // The standalone server directory as upstream's image lays it out (server.js, .next/server, .next/static,
  // public). Dependencies never carry a placeholder and are skipped.
  const roots = [{ from: nextDir, to: "." }];
  const listed = [];
  for (const { from, to } of roots) {
    for (const file of walk(from)) {
      if (file.includes("/node_modules/") || file.includes(`${join(from, ".next", "cache")}/`)) continue;
      if (statSync(file).size > 20 * 1024 * 1024) continue;
      if (!readFileSync(file, "latin1").includes(MARKER)) continue;
      const runtime = join(to, relative(from, file));
      mkdirSync(dirname(join(pristineDir, runtime)), { recursive: true });
      copyFileSync(file, join(pristineDir, runtime));
      listed.push(runtime);
    }
  }
  if (!listed.length) die("no built file carries a placeholder; the build did not inline them");
  mkdirSync(pristineDir, { recursive: true });
  writeFileSync(join(pristineDir, ".index"), `${listed.sort().join("\n")}\n`);
  process.stdout.write(`fill-public-env: ${listed.length} built files carry placeholders\n`);
}

function fill(appDir, pristineDir) {
  const values = {};
  for (const [name, shape] of Object.entries(SHAPES)) {
    const value = (process.env[name] ?? "").trim();
    if (!shape.test(value)) die(`${name} is missing or not in the expected form`);
    values[name] = value;
  }
  const files = readFileSync(join(pristineDir, ".index"), "utf8").split("\n").filter(Boolean);
  let leftover = 0;
  for (const rel of files) {
    let text = readFileSync(join(pristineDir, rel), "latin1");
    for (const [name, placeholder] of Object.entries(PLACEHOLDERS)) {
      text = text.split(placeholder).join(values[name]);
    }
    if (text.includes(MARKER)) leftover += 1;
    writeFileSync(join(appDir, rel), text, "latin1");
  }
  // A marker that survived means a placeholder was transformed at build time (escaped, encoded,
  // split) into a form this script does not know. Serving that would point the browser at nothing.
  if (leftover) die(`${leftover} built files still carry a placeholder in a form that was not replaced`);
  process.stdout.write(`[llmwiki-web] public values written into ${files.length} built files\n`);
}

if (process.argv[2] === "--index") buildIndex(process.argv[3], process.argv[4]);
else fill(process.env.LLMWIKI_APP_DIR ?? "/app", process.env.LLMWIKI_PRISTINE_DIR ?? "/opt/llmwiki-railway/pristine");
