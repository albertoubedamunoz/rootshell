/* eslint-disable */
/*
 * wasm-host.js — runs on the WKWebView main thread. Spawns one Web Worker
 * per .wasm invocation, brokers messages between the Worker (which runs the
 * WASI + socket runtime) and Swift via window.webkit.messageHandlers.
 *
 * The Worker blocks on Atomics.wait over a SharedArrayBuffer to make WASI
 * calls feel synchronous to the WASM module. Each blocked call is paired
 * with a callID so we can fulfil it from Swift via deliver(...).
 */

const MH = window.webkit.messageHandlers;

function postStdio(msg)   { MH.wasmStdio.postMessage(msg); }
function postFs(msg)      { MH.wasmFs.postMessage(msg); }
function postSocket(msg)  { MH.wasmSocket.postMessage(msg); }
function postControl(msg) { MH.wasmControl.postMessage(msg); }
function jsLog(message)   { postControl({ kind: "log", message: String(message) }); }

/* Map callID -> Worker reference so deliver(...) routes replies to the
 * right Worker. We support one active Worker today but the structure leaves
 * room for parallel WASM processes in v2. */
const workers = new Map();        // processID -> { worker, sab, view, callIDs:Set, stdinQueue:Uint8Array[] }

let cachedWorkerURL = null;

/* Fetch the worker source and wrap it as a Blob URL. Some WebKit versions
 * refuse to instantiate `new Worker()` directly from custom URL schemes
 * (only http/https), but a Blob URL is universally accepted as long as
 * the page itself is cross-origin-isolated. */
async function getWorkerURL() {
    if (cachedWorkerURL) return cachedWorkerURL;
    const resp = await fetch("wasm-worker.js");
    if (!resp.ok) throw new Error("failed to load wasm-worker.js: " + resp.status);
    const src = await resp.text();
    const blob = new Blob([src], { type: "application/javascript" });
    cachedWorkerURL = URL.createObjectURL(blob);
    return cachedWorkerURL;
}

window.rootshellWasm = {
    async run(launch) {
        const { processID, wasm, argv, env, cwd, sandboxRoot } = launch;

        // SharedArrayBuffer requires crossOriginIsolated to be true. The
        // custom scheme handler in Swift sets COOP/COEP for us. If something
        // is misconfigured this throws here, which surfaces to Swift as an
        // "error" control message.
        if (!self.crossOriginIsolated) {
            postControl({
                kind: "error",
                message: "wasm host page is not crossOriginIsolated — SharedArrayBuffer unavailable. " +
                         "Check COOP/COEP headers in WasmHostSchemeHandler."
            });
            return;
        }

        const sab = new SharedArrayBuffer(64 * 1024);  // sync syscall reply slot
        const view = new Int32Array(sab);

        let worker;
        try {
            const workerURL = await getWorkerURL();
            worker = new Worker(workerURL);
        } catch (e) {
            postControl({ kind: "error", message: "failed to spawn worker: " + (e && e.message || e) });
            return;
        }

        const ctx = {
            worker, sab, view,
            stdinQueue: [],
            stdinClosed: false,
        };
        workers.set(processID, ctx);

        worker.onmessage = (ev) => onWorkerMessage(processID, ev.data);
        worker.onerror = (err) => {
            postControl({ kind: "error", message: "worker error: " + err.message });
            cleanup(processID);
        };

        worker.postMessage({
            kind: "start",
            processID, wasm, argv, env, cwd, sandboxRoot,
            sab,
        });
    },

    /* Swift calls this with arbitrary opaque payload that should be written
     * into the Worker's SharedArrayBuffer. We package the payload as JSON,
     * UTF-8, length-prefixed at byte 4, and use slot 0 as the "ready" lock
     * the Worker is parked on. */
    deliver(reply) {
        const ctx = findContextForCall(reply.callID);
        if (!ctx) return;
        writeReplyAndNotify(ctx, reply);
    },

    feedStdin(processID, base64) {
        const ctx = workers.get(processID);
        if (!ctx) return;
        const bytes = b64ToBytes(base64);
        ctx.stdinQueue.push(bytes);
        // If the Worker is parked waiting for stdin, wake it.
        if (ctx.pendingStdin) {
            const next = ctx.pendingStdin;
            ctx.pendingStdin = null;
            satisfyStdinRead(ctx, next);
        }
    },

    cancel(processID) {
        const ctx = workers.get(processID);
        if (!ctx) return;
        // A parked Worker (Atomics.wait inside a WASI syscall) can't
        // process incoming messages, so postMessage(cancel) wouldn't be
        // seen until the next syscall returned. terminate() is the only
        // way to interrupt a synchronous blocking call mid-flight.
        try { ctx.worker.terminate(); } catch (_) {}
        // Synthesise the SIGINT-style exit code so the host UI sees the
        // process as cancelled, not crashed.
        postControl({ kind: "exit", processID, code: 130 });
        cleanup(processID);
    }
};

function findContextForCall(callID) {
    for (const ctx of workers.values()) {
        if (ctx.callIDs && ctx.callIDs.has(callID)) {
            ctx.callIDs.delete(callID);
            ctx.pendingCallID = null;
            return ctx;
        }
        if (ctx.pendingCallID === callID) {
            ctx.pendingCallID = null;
            return ctx;
        }
    }
    return null;
}

function onWorkerMessage(processID, msg) {
    const ctx = workers.get(processID);
    if (!ctx) return;

    switch (msg.kind) {
        case "stdout":
        case "stderr":
            postStdio({
                processID,
                stream: msg.kind,
                data: msg.data,  // already base64
            });
            break;

        case "fs":
            ctx.pendingCallID = msg.callID;
            postFs({ ...msg.payload, callID: msg.callID });
            break;

        case "socket":
            ctx.pendingCallID = msg.callID;
            postSocket({ ...msg.payload, callID: msg.callID });
            break;

        case "terminal":
            // Forward to Swift via the control channel — same shape as the
            // FS/socket round-trips so the Worker stays parked on
            // Atomics.wait until Swift writes a reply.
            ctx.pendingCallID = msg.callID;
            postControl({ kind: "terminal", callID: msg.callID, ...msg.payload, processID });
            break;

        case "stdinRead":
            // The Worker wants stdin bytes. Serve from the queue, or park.
            satisfyStdinRead(ctx, msg);
            break;

        case "exit":
            postControl({ kind: "exit", processID, code: msg.code });
            cleanup(processID);
            break;

        case "log":
            jsLog("[worker] " + msg.message);
            break;

        case "error":
            postControl({ kind: "error", message: msg.message });
            cleanup(processID);
            break;
    }
}

function satisfyStdinRead(ctx, msg) {
    // Pop up to `maxLen` bytes from the queue. If empty, park.
    if (ctx.stdinQueue.length === 0) {
        if (ctx.stdinClosed) {
            // EOF: deliver zero bytes.
            writeStdinReplyAndNotify(ctx, msg.callID, new Uint8Array(0));
            return;
        }
        ctx.pendingStdin = msg;
        return;
    }
    let collected = new Uint8Array(msg.maxLen);
    let off = 0;
    while (off < msg.maxLen && ctx.stdinQueue.length > 0) {
        const head = ctx.stdinQueue[0];
        const take = Math.min(head.length, msg.maxLen - off);
        collected.set(head.subarray(0, take), off);
        off += take;
        if (take === head.length) {
            ctx.stdinQueue.shift();
        } else {
            ctx.stdinQueue[0] = head.subarray(take);
        }
    }
    writeStdinReplyAndNotify(ctx, msg.callID, collected.subarray(0, off));
}

function writeStdinReplyAndNotify(ctx, callID, bytes) {
    const reply = {
        callID,
        errno: 0,
        data: bytesToB64(bytes),
    };
    writeReplyAndNotify(ctx, reply);
}

/* Replies are written into the SAB as: [magic=1][length][JSON bytes]. The
 * Worker reads, parses, and resumes. */
function writeReplyAndNotify(ctx, reply) {
    const json = JSON.stringify(reply);
    const enc = new TextEncoder().encode(json);
    // Layout: i32[0] = ready flag, i32[1] = byte length, then UTF-8 JSON.
    const byteView = new Uint8Array(ctx.sab);
    if (enc.length + 8 > byteView.length) {
        // Reply too big — fail.
        const fail = JSON.stringify({ callID: reply.callID, errno: 28 /* EINVAL */ });
        const failEnc = new TextEncoder().encode(fail);
        byteView.set(failEnc, 8);
        Atomics.store(ctx.view, 1, failEnc.length);
    } else {
        byteView.set(enc, 8);
        Atomics.store(ctx.view, 1, enc.length);
    }
    Atomics.store(ctx.view, 0, 1);
    Atomics.notify(ctx.view, 0);
}

function cleanup(processID) {
    const ctx = workers.get(processID);
    if (!ctx) return;
    try { ctx.worker.terminate(); } catch (_) {}
    workers.delete(processID);
}

function b64ToBytes(b64) {
    const bin = atob(b64);
    const out = new Uint8Array(bin.length);
    for (let i = 0; i < bin.length; i++) out[i] = bin.charCodeAt(i);
    return out;
}
function bytesToB64(bytes) {
    let s = "";
    for (let i = 0; i < bytes.length; i++) s += String.fromCharCode(bytes[i]);
    return btoa(s);
}

postControl({ kind: "ready" });
