// A build run headless in a web view the app keeps out of sight, drawn by
// the app's own head: the Playground's second engine on Apple platforms
// (apple/host/WebViewEngine.swift). The same `iso_hot` bundle the Safari run
// (index.html, isomer's hot_host.js) and the WasmKit run take, run by the web
// view's JavaScript engine (its JIT), with no renderer here: each tree the
// reactor pushes goes to the app (`isomerHead` messages), which draws it as
// a WasmKit run's is drawn; the app's calls (start, events, resizes) come in
// through `window.isoHead.call`. Frames are scheduled with setTimeout, not
// requestAnimationFrame, which a web view out of sight may hold back.
//
// To the app, as `{ kind, … }` messages:
//   ready {instantiateMs}   the reactor instantiated and initialised
//   tree {bytes}            a tree.proto patch, base64
//   log {line}  platform {key, value}  error {message}

import { BlobWriter, Runtime, Tags, Types, decoder as ffiDecoder, encodeErrorBlob, foreignObjects, pendingCalls, registerForeign, wasiShim } from "./swift_ffi_runtime.js";
import { appFilesKey, openAppFiles } from "./runtime/file_system.js";
import { browserNetworkHosts } from "./runtime/network.js";
import { Dependencies } from "./app_bridge.js";
import { pageDependencies } from "./page_dependencies.js";

const decoder = new TextDecoder();
const post = (message) => window.webkit.messageHandlers.isomerHead.postMessage(message);

/** Bytes as base64, in chunks (a spread of a large array overflows the stack). */
function base64(bytes) {
  let text = "";
  for (let i = 0; i < bytes.length; i += 0x8000) {
    text += String.fromCharCode.apply(null, bytes.subarray(i, i + 0x8000));
  }
  return btoa(text);
}

const fromBase64 = (text) => Uint8Array.from(atob(text), (c) => c.charCodeAt(0));

async function run() {
  const started = performance.now();
  const files = await openAppFiles(appFilesKey("dev.isomer.playground.web-view-run"));
  const dependencies = { ...browserNetworkHosts(Dependencies, {}), ...pageDependencies(Dependencies) };
  let memory = null;
  let exports = null;
  let ffiRuntime = null;

  const guestString = (ptr, len) =>
    len <= 0 ? "" : decoder.decode(new Uint8Array(memory.buffer, ptr, len));
  const foreignBytes = (ptr, len) =>
    len === 0 ? new Uint8Array(0) : new Uint8Array(memory.buffer, ptr, len).slice();
  const foreignString = (ptr, len) =>
    len === 0 ? "" : ffiDecoder.decode(new Uint8Array(memory.buffer, ptr, len));
  const packForeignBytes = (bytes) => {
    if (bytes.length === 0) return 0n;
    const ptr = exports.swift_ffi_alloc(bytes.length);
    new Uint8Array(memory.buffer, ptr, bytes.length).set(bytes);
    return (BigInt(bytes.length) << 32n) | BigInt(ptr >>> 0);
  };

  let renderQueued = false;
  function scheduleRender() {
    if (renderQueued) return;
    renderQueued = true;
    setTimeout(() => {
      renderQueued = false;
      if (exports) exports.iso_hot_render();
    }, 0);
  }

  const imports = {
    iso_hot: {
      render_tree(ptr, len) {
        post({ kind: "tree", bytes: base64(new Uint8Array(memory.buffer, ptr, len)) });
      },
      log(ptr, len) {
        post({ kind: "log", line: guestString(ptr, len) });
      },
      epoch_millis() {
        return Date.now();
      },
      schedule_render() {
        scheduleRender();
      },
      // The app does what it can with a platform command (copy, openURL,
      // share), as it does for a WasmKit run.
      platform_command(kp, kl, vp, vl) {
        post({ kind: "platform", key: guestString(kp, kl), value: guestString(vp, vl) });
      },
      host_value() {
        return -1;
      },
    },
    // swift_ffi's transport, as hot_host.js binds it: the page's platform
    // services (page_dependencies.js) and Foundation's networking over fetch.
    swift_ffi: {
      closure_invoke(id, argsPtr, argsLen) {
        const dispatcher = foreignObjects.get(id);
        let result;
        try {
          if (!dispatcher) throw new Error(`no foreign object ${id}`);
          result = dispatcher(foreignBytes(argsPtr, argsLen));
        } catch (error) {
          result = encodeErrorBlob(error instanceof Error ? error.message : String(error));
        }
        return packForeignBytes(result);
      },
      foreign_release(id) { foreignObjects.delete(id); },
      dependency_get(keyPtr, keyLen) {
        const dep = dependencies[foreignString(keyPtr, keyLen)];
        if (!dep) return 0n;
        const w = new BlobWriter();
        w.header(Tags.list, 0);
        w.i64(3n);
        Types.bool.encode(w, dep.lazy);
        Types.string.encode(w, dep.key);
        Types.int32.encode(w, registerForeign((args) => dep.dispatcher(args, () => ffiRuntime)));
        return packForeignBytes(w.data());
      },
      task_enqueue(job) {
        queueMicrotask(() => {
          if (exports && exports.swift_ffi_task_run) exports.swift_ffi_task_run(job);
        });
      },
      task_enqueue_after(job, delayMs) {
        setTimeout(() => {
          if (exports && exports.swift_ffi_task_run) exports.swift_ffi_task_run(job);
        }, Math.max(0, delayMs));
      },
      async_complete(callId, blobPtr, blobLen) {
        const pending = pendingCalls.get(callId);
        pendingCalls.delete(callId);
        if (pending) pending.resolve(pending.decode(foreignBytes(blobPtr, blobLen)));
      },
    },
    wasi_snapshot_preview1: wasiShim(() => {
      if (!memory) throw new Error("wasm memory accessed before instantiation");
      return memory;
    }, (getMemory, builtins) => files.wasi(getMemory, builtins, {
      environment: { ISOMER_BUNDLE_IDENTIFIER: "dev.isomer.playground.web-view-run" },
    })),
  };

  const response = await fetch("./app.wasm");
  if (!response.ok) throw new Error(`app.wasm fetch ${response.status}`);
  const { instance } = await WebAssembly.instantiate(await response.arrayBuffer(), imports);
  memory = instance.exports.memory;
  instance.exports._initialize();
  exports = instance.exports;
  ffiRuntime = new Runtime(instance.exports);
  for (const name of Object.keys(instance.exports)) {
    if (/^swift_ffi_.*_register_/.test(name)) instance.exports[name]();
  }

  // The app's calls: an export by name, each argument a number or, for
  // bytes the app staged (`{bytes}`, base64), the guest's copy of them,
  // freed after. What the export returns goes back as the call's answer.
  window.isoHead = {
    call(name, args) {
      const fn = exports && exports[name];
      if (!fn) return null;
      const staged = [];
      const values = args.map((arg) => {
        if (arg && typeof arg === "object" && "bytes" in arg) {
          const bytes = fromBase64(arg.bytes);
          const ptr = exports.iso_hot_alloc(bytes.length);
          new Uint8Array(memory.buffer, ptr, bytes.length).set(bytes);
          staged.push(ptr);
          return ptr;
        }
        return arg;
      });
      const result = fn(...values);
      for (const ptr of staged) exports.iso_hot_free(ptr);
      // An event or a resize wants a frame, as the renderer would ask.
      if (name === "iso_hot_event" || name === "iso_hot_resize" || name.startsWith("iso_hot_set_")) scheduleRender();
      return typeof result === "bigint" ? Number(result) : result ?? null;
    },
  };
  post({ kind: "ready", instantiateMs: performance.now() - started });
}

run().catch((error) => post({ kind: "error", message: String(error && error.stack ? error.stack : error) }));
