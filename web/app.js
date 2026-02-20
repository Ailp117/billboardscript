const panel = document.getElementById("panel");
const enabledInput = document.getElementById("enabled");
const rotationInput = document.getElementById("rotationSeconds");
const urlsInput = document.getElementById("urls");
const rotationHint = document.getElementById("rotationHint");
const urlHint = document.getElementById("urlHint");
const previewUrl = document.getElementById("previewUrl");
const previewImage = document.getElementById("previewImage");
const previewPlaceholder = document.getElementById("previewPlaceholder");
const saveBtn = document.getElementById("saveBtn");
const closeBtn = document.getElementById("closeBtn");

let limits = {
    minRotationSeconds: 5,
    maxRotationSeconds: 600,
    maxUrls: 20,
    maxUrlLength: 512
};
let previewDebounce = null;
let activePreviewUrl = "";
let isSaving = false;

const postNui = async (eventName, payload = {}) => {
    const response = await fetch(`https://${GetParentResourceName()}/${eventName}`, {
        method: "POST",
        headers: { "Content-Type": "application/json; charset=UTF-8" },
        body: JSON.stringify(payload)
    });

    if (!response.ok) {
        throw new Error(`NUI request failed (${response.status})`);
    }
};

const parseUrls = (raw) => {
    const result = [];
    const seen = new Set();

    raw.split("\n")
        .map((url) => url.trim())
        .filter((url) => url.length > 0)
        .forEach((url) => {
            if (!seen.has(url)) {
                result.push(url);
                seen.add(url);
            }
        });

    return result;
};

const setUrlHint = (isError, message) => {
    urlHint.classList.toggle("error", isError);
    urlHint.textContent = message;
};

const setSavingState = (saving) => {
    isSaving = saving;
    saveBtn.disabled = saving;
    saveBtn.textContent = saving ? "Speichere..." : "Speichern";
};

const isValidHttpUrl = (value) => {
    try {
        const parsed = new URL(value);
        return parsed.protocol === "http:" || parsed.protocol === "https:";
    } catch (_error) {
        return false;
    }
};

const getCurrentLineUrl = () => {
    const allLines = urlsInput.value.split("\n");
    const cursorPos = urlsInput.selectionStart || 0;
    const currentLineIndex = urlsInput.value.slice(0, cursorPos).split("\n").length - 1;
    const currentLine = allLines[currentLineIndex] || "";
    return currentLine.trim();
};

const setPreviewState = (url, isError) => {
    if (!url) {
        activePreviewUrl = "";
        previewUrl.textContent = "Keine URL ausgewaehlt";
        previewImage.classList.add("hidden");
        previewPlaceholder.classList.remove("hidden");
        previewPlaceholder.textContent = "Keine gueltige Bild-URL in der aktuellen Zeile.";
        return;
    }

    previewUrl.textContent = url;
    if (isError) {
        previewImage.classList.add("hidden");
        previewPlaceholder.classList.remove("hidden");
        previewPlaceholder.textContent = "Vorschau konnte nicht geladen werden (kein direktes Bild oder blockierte URL).";
        return;
    }

    previewPlaceholder.classList.remove("hidden");
    previewPlaceholder.textContent = "Lade Vorschau...";
    previewImage.classList.add("hidden");
};

const refreshPreview = () => {
    const currentLineUrl = getCurrentLineUrl();
    const fallbackUrls = parseUrls(urlsInput.value);
    const selectedUrl = currentLineUrl.length > 0 ? currentLineUrl : (fallbackUrls[0] || "");

    if (!selectedUrl || !isValidHttpUrl(selectedUrl)) {
        setPreviewState("", false);
        return;
    }

    if (activePreviewUrl !== selectedUrl) {
        setPreviewState(selectedUrl, false);
        activePreviewUrl = selectedUrl;
        previewImage.src = selectedUrl;
        return;
    }

    if (previewImage.complete && previewImage.naturalWidth > 0) {
        previewPlaceholder.classList.add("hidden");
        previewImage.classList.remove("hidden");
    }
};

const schedulePreviewRefresh = () => {
    if (previewDebounce) {
        clearTimeout(previewDebounce);
    }

    previewDebounce = setTimeout(refreshPreview, 120);
};

const hidePanel = () => {
    panel.classList.add("hidden");
    document.body.classList.remove("active");
    setSavingState(false);
};

const showPanel = () => {
    panel.classList.remove("hidden");
    document.body.classList.add("active");
};

window.addEventListener("message", (event) => {
    const data = event.data;
    if (!data || !data.type) {
        return;
    }

    if (data.type === "open") {
        limits = data.limits || limits;

        const settings = data.settings || {};
        enabledInput.checked = settings.enabled === true;
        rotationInput.min = String(limits.minRotationSeconds);
        rotationInput.max = String(limits.maxRotationSeconds);
        rotationInput.value = String(settings.rotationSeconds ?? limits.minRotationSeconds);
        rotationInput.step = "1";
        urlsInput.value = Array.isArray(settings.urls) ? settings.urls.join("\n") : "";

        rotationHint.textContent = `Erlaubt: ${limits.minRotationSeconds}s bis ${limits.maxRotationSeconds}s`;
        setUrlHint(false, `Maximal ${limits.maxUrls} URLs, je URL max ${limits.maxUrlLength} Zeichen.`);
        setSavingState(false);
        refreshPreview();
        showPanel();
    }

    if (data.type === "close") {
        hidePanel();
    }
});

previewImage.addEventListener("error", () => {
    activePreviewUrl = "";
    setPreviewState(previewUrl.textContent, true);
});

previewImage.addEventListener("load", () => {
    previewPlaceholder.classList.add("hidden");
    previewImage.classList.remove("hidden");
});

urlsInput.addEventListener("input", schedulePreviewRefresh);
urlsInput.addEventListener("keyup", schedulePreviewRefresh);
urlsInput.addEventListener("click", schedulePreviewRefresh);
urlsInput.addEventListener("focus", schedulePreviewRefresh);

saveBtn.addEventListener("click", async () => {
    if (isSaving) {
        return;
    }

    const urls = parseUrls(urlsInput.value);
    if (urls.length === 0) {
        setUrlHint(true, "Bitte mindestens eine gueltige URL eintragen.");
        return;
    }

    if (urls.length > limits.maxUrls) {
        setUrlHint(true, `Zu viele URLs. Maximum: ${limits.maxUrls}`);
        return;
    }

    for (const url of urls) {
        if (url.length > limits.maxUrlLength) {
            setUrlHint(true, `URL zu lang (max ${limits.maxUrlLength} Zeichen).`);
            return;
        }
        if (!isValidHttpUrl(url)) {
            setUrlHint(true, "Alle URLs muessen mit http:// oder https:// gueltig sein.");
            return;
        }
    }

    const rotationSeconds = Number(rotationInput.value);
    const clampedRotation = Math.max(
        limits.minRotationSeconds,
        Math.min(limits.maxRotationSeconds, Math.floor(rotationSeconds || limits.minRotationSeconds))
    );

    try {
        setSavingState(true);
        await postNui("saveSettings", {
            enabled: enabledInput.checked,
            rotationSeconds: clampedRotation,
            urls
        });
    } catch (_error) {
        setSavingState(false);
        setUrlHint(true, "Speichern fehlgeschlagen. Bitte erneut versuchen.");
    }
});

closeBtn.addEventListener("click", async () => {
    try {
        await postNui("close");
    } catch (_error) {
        hidePanel();
    }
});

window.addEventListener("keydown", async (event) => {
    if (event.key === "Escape" && !panel.classList.contains("hidden")) {
        try {
            await postNui("close");
        } catch (_error) {
            hidePanel();
        }
    }
});
