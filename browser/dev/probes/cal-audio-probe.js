// Cal.com (Cal Video) audio-path probe. Paste into DevTools on the tab that is in
// the call, once per frame: run it in `top`, then pick the call iframe from the
// DevTools context dropdown and run it again there.
//
// Question: which stack carries the call, and does remote audio reach the page as
// a normal RTP receiver track (so the existing `receiver-track` seam works) or
// by some other path (DataChannel + WASM, like Zoom — journal #152)?
//
// Read-only: one synchronous snapshot, no listeners, no wraps, no mutation. Emits
// origins, hostnames, element and track shapes, truncated track ids and global
// key names. No display names, no URL paths (they carry the booking/room id).
(() => {
  const isNative = (f) =>
    typeof f === "function" && /\[native code\]/.test(Function.prototype.toString.call(f));
  const origin = (u) => {
    try {
      return new URL(u, location.href).origin;
    } catch {
      return "?";
    }
  };

  const frames = [...document.querySelectorAll("iframe")].map((f) => {
    let sameOrigin = false;
    try {
      sameOrigin = !!f.contentDocument;
    } catch {}
    return { origin: origin(f.src), sameOrigin, allow: f.allow || "" };
  });

  const media = [...document.querySelectorAll("audio,video")].map((el) => {
    const s = el.srcObject;
    return {
      tag: el.tagName.toLowerCase(),
      srcObject: s instanceof MediaStream ? "MediaStream" : s ? typeof s : null,
      srcUrl: el.src ? origin(el.src) : null,
      paused: el.paused,
      muted: el.muted,
      tracks: s instanceof MediaStream
        ? s.getTracks().map((t) => ({
            kind: t.kind,
            id: t.id.slice(0, 8),
            readyState: t.readyState,
            muted: t.muted,
            enabled: t.enabled,
          }))
        : [],
    };
  });

  const vendorHosts = [
    ...new Set(
      performance
        .getEntriesByType("resource")
        .map((e) => origin(e.name))
        .filter((o) => /daily|livekit|jitsi|twilio|agora|mediasoup|100ms|stream-io|wss?:/i.test(o)),
    ),
  ];

  const result = {
    host: location.host,
    topFrame: window === top,
    frames,
    media,
    vendorHosts,
    globals: Object.keys(window).filter((k) =>
      /daily|livekit|jitsi|twilio|agora|mediasoup|callframe|callobject/i.test(k),
    ),
    apis: {
      RTCPeerConnectionNative: isNative(window.RTCPeerConnection),
      AudioContextNative: isNative(window.AudioContext),
      MediaStreamTrackProcessor: "MediaStreamTrackProcessor" in window,
      earsHookPresent: !!window.__earsLiveTracks,
    },
  };
  console.log("[ears][cal-probe]", JSON.stringify(result, null, 2));
  return result;
})();
