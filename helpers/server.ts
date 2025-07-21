#!/usr/bin/env -S deno run --allow-net --allow-read
/**
 * Test Server for GRQ Validation Dashboard
 *
 * Starts a local HTTP server that serves static files
 * from the `docs` folder for testing.
 *
 * Usage:
 *   deno run --allow-net --allow-read tests/start-test-server.js [port]
 * Default port is 8000 if not specified.
 */

import { join } from "https://deno.land/std@0.208.0/path/mod.ts";

const DEFAULT_PORT = 8000;
const DOCS_DIR = "docs";
const port = parseInt(Deno.args[0] ?? "") || DEFAULT_PORT;
const DEBUG = true;

const MIME_TYPES: Record<string, string> = {
  ".html": "text/html",
  ".css": "text/css",
  ".js": "application/javascript",
  ".json": "application/json",
  ".png": "image/png",
  ".jpg": "image/jpeg",
  ".jpeg": "image/jpeg",
  ".gif": "image/gif",
  ".svg": "image/svg+xml",
  ".ico": "image/x-icon",
  ".csv": "text/csv",
  ".tsv": "text/tab-separated-values",
  ".txt": "text/plain",
  ".xml": "application/xml",
  ".pdf": "application/pdf",
};

function getMimeType(filename: string) {
  const ext = filename.substring(filename.lastIndexOf(".")).toLowerCase();
  return MIME_TYPES[ext] ?? "application/octet-stream";
}

function getFilePath(url: string) {
  let path = decodeURIComponent(url.substring(1));

  if (DEBUG) {
    console.log(`🔍 Requested URL: "${url}"`);
    console.log(`📂 Decoded path: "${path}"`);
  }

  if (path === "" || path === "/") path = "index.html";
  else if (path === "docs" || path === "docs/") path = "index.html";
  else if (path === "index.html") path = "index.html";
  else if (path.startsWith("docs/")) {
    path = path.substring(5) || "index.html";
  }

  const fullPath = join(DOCS_DIR, path);

  if (DEBUG) console.log(`🎯 Final file path: "${fullPath}"`);

  return fullPath;
}

async function handleRequest(request: Request): Promise<Response> {
  const url = new URL(request.url);
  const filePath = getFilePath(url.pathname);

  if (DEBUG) {
    console.log(
      `\n📥 ${new Date().toISOString()} - ${request.method} ${url.pathname}`,
    );
  }

  try {
    const fileInfo = await Deno.stat(filePath);

    if (fileInfo.isFile) {
      const fileContent = await Deno.readFile(filePath);
      const mimeType = getMimeType(filePath);

      if (DEBUG) console.log(`✅ 200 - Served: ${filePath} (${mimeType})`);

      return new Response(fileContent, {
        status: 200,
        headers: {
          "Content-Type": mimeType,
          "Cache-Control": "no-cache, no-store, must-revalidate",
          "Pragma": "no-cache",
          "Expires": "0",
        },
      });
    }

    if (DEBUG) console.log(`❌ 404 - Not a file: ${filePath}`);
    return new Response("Not Found", { status: 404 });
  } catch (error) {
    if (error instanceof Deno.errors.NotFound) {
      if (DEBUG) {
        console.log(`❌ 404 - File not found: ${filePath}`);
        console.log(`   Error: ${error.message}`);
      }
      return new Response("File Not Found", { status: 404 });
    }

    if (DEBUG) {
      console.log(`❌ 500 - Server error: ${filePath}`);
      console.log(`   Error: ${(error as Error).message}`);
    }
    return new Response("Internal Server Error", { status: 500 });
  }
}

console.log(`🚀 Starting test server on http://localhost:${port}`);
console.log(`📁 Serving files from: ${DOCS_DIR}`);
console.log(`🌐 Available URLs:`);
console.log(`   • http://localhost:${port}/ (main dashboard)`);
console.log(`   • http://localhost:${port}/docs/ (same as root)`);
console.log(`   • http://localhost:${port}/index.html (explicit index)`);
console.log(`   • http://localhost:${port}/scores/ (data files)`);
console.log(`⏹️  Press Ctrl+C to stop the server`);
console.log(`🔍 Debug logging is ${DEBUG ? "ENABLED" : "DISABLED"}`);
console.log("");

// new native API (no external import required)
Deno.serve({ port }, handleRequest);
