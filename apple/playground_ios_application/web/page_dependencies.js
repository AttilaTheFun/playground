// The platform services a Playground build gets in a page (isomer's
// examples/shared/platform_services, over browser APIs): the Safari run's
// (index.html) and the hidden web view's (native_head.html) alike.

export function pageDependencies(Dependencies) {
  // The platform services (isomer's examples/shared/platform_services) for the
  // web run, over browser APIs — the same table the example web app
  // installs, the keychain under a playground prefix in localStorage. The
  // build's network and files are Foundation's (the runtime's fetch and
  // IndexedDB); a project's imported files are not served here.
  const sandbox = "playground.";
  const toBase64 = (bytes) => btoa(String.fromCharCode(...bytes));
  const fromBase64 = (text) => Uint8Array.from(atob(text), (c) => c.charCodeAt(0));
  return {
    keychain: Dependencies.keychainService(() => ({
      async get(key) {
        const stored = localStorage.getItem(sandbox + "keychain:" + key);
        if (stored === null) throw new Error("no keychain value for " + key);
        return fromBase64(stored);
      },
      async set(value, key) { localStorage.setItem(sandbox + "keychain:" + key, toBase64(value)); },
      async delete(key) { localStorage.removeItem(sandbox + "keychain:" + key); },
    })),
    analytics: Dependencies.analyticsService(() => ({
      track(event) { console.log("[analytics]", event); },
    })),
    configuration: Dependencies.configurationService(() => ({
      flag(key) { return key === "promo_banner"; },
    })),
    // `<input type="file" accept="image/*">`, scaled on a canvas to
    // maxDimension and returned as a blob URL ("" when cancelled).
    imagePicker: Dependencies.imagePickerService(() => ({
      pickImage(maxDimension) {
        return new Promise((resolve, reject) => {
          const input = document.createElement("input");
          input.type = "file";
          input.accept = "image/*";
          input.style.display = "none";
          document.body.appendChild(input);
          const finish = (value) => { input.remove(); resolve(value); };
          input.onchange = () => {
            const file = input.files && input.files[0];
            if (!file) return finish("");
            const image = new Image();
            const objectURL = URL.createObjectURL(file);
            image.onload = () => {
              const scale = Math.min(1, maxDimension / Math.max(1, image.width, image.height));
              const canvas = document.createElement("canvas");
              canvas.width = Math.max(1, Math.round(image.width * scale));
              canvas.height = Math.max(1, Math.round(image.height * scale));
              canvas.getContext("2d").drawImage(image, 0, 0, canvas.width, canvas.height);
              URL.revokeObjectURL(objectURL);
              // A blob URL: the <img> loads it directly, nothing crosses the tree but the URL.
              canvas.toBlob((blob) => finish(blob ? URL.createObjectURL(blob) : ""), "image/jpeg", 0.85);
            };
            image.onerror = () => { URL.revokeObjectURL(objectURL); reject(new Error("not an image")); };
            image.src = objectURL;
          };
          input.oncancel = () => finish("");
          input.click();
        });
      },
    })),
  };
}
