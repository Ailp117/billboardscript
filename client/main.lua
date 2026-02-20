local RUNTIME_TXD = "billboard_runtime_txd"
local RUNTIME_TXN = "billboard_runtime_txn"
local configuredTextureTargets = type(Config.TextureTargets) == "table" and Config.TextureTargets or {}
local textureTargets = {}
local textureTargetKeys = {}
local cacheBustEnabled = Config.CacheBust == true
local duiWidth = math.max(64, math.floor(tonumber(Config.DuiWidth) or 1920))
local duiHeight = math.max(64, math.floor(tonumber(Config.DuiHeight) or 1080))
local minRotationSeconds = math.max(1, math.floor(tonumber(Config.MinRotationSeconds) or 5))
local maxRotationSeconds = math.max(minRotationSeconds, math.floor(tonumber(Config.MaxRotationSeconds) or 600))
local defaultRotationSeconds = math.floor(tonumber((Config.DefaultSettings or {}).rotationSeconds) or 30)
local coverageModels = type(Config.VanillaBillboardModels) == "table" and Config.VanillaBillboardModels or {}
local coverageDefaultRadius = math.min(
    math.max(1.0, tonumber(Config.CoverageMaxRadius) or 1500.0),
    math.max(math.max(1.0, tonumber(Config.CoverageMinRadius) or 50.0), tonumber(Config.CoverageDefaultRadius) or 350.0)
)
local coverageMinRadius = math.max(1.0, tonumber(Config.CoverageMinRadius) or 50.0)
local coverageMaxRadius = math.max(coverageMinRadius, tonumber(Config.CoverageMaxRadius) or 1500.0)
local coverageScanIntervalMs = math.max(1000, math.floor(tonumber(Config.CoverageScanIntervalMs) or 5000))
local coverageDrawDistance = math.max(1.0, tonumber(Config.CoverageDrawDistance) or 80.0)
local coverageMaxDrawEntries = math.max(1, math.floor(tonumber(Config.CoverageMaxDrawEntries) or 60))
local requiredTextureNamePart = tostring(Config.TextureNameMustContain or ""):lower():match("^%s*(.-)%s*$")
local autoDiscoverEnabled = Config.AutoDiscoverBillboardTargets == true
local autoDiscoverRadius = math.max(20.0, tonumber(Config.AutoDiscoverRadius) or 800.0)
local autoDiscoverIntervalMs = math.max(1000, math.floor(tonumber(Config.AutoDiscoverIntervalMs) or 10000))
local autoDiscoverByDimensions = Config.AutoDiscoverByDimensions ~= false
local autoDiscoverMinFaceArea = math.max(4.0, tonumber(Config.AutoDiscoverMinFaceArea) or 20.0)
local autoDiscoverMinLongestSide = math.max(2.0, tonumber(Config.AutoDiscoverMinLongestSide) or 4.5)
local autoDiscoverMaxDepth = math.max(0.2, tonumber(Config.AutoDiscoverMaxDepth) or 2.5)
local autoDiscoverKeywords = {}
local canLookupArchetypeName = type(GetEntityArchetypeName) == "function"

local duiObject
local runtimeTxd
local replacementsApplied = false

local uiOpen = false
local activeSettings = nil
local currentUrlIndex = 1
local nextSwitchAt = 0
local hasRenderedCurrent = false
local debugEnabled = Config.Debug == true
local hasReceivedSettings = false
local lastSettingsRequestAt = 0
local settingsRetryMs = math.max(1000, tonumber(Config.ClientSettingsRetryMs) or 5000)
local coverageEnabled = false
local coverageRadius = coverageDefaultRadius
local coverageLastScanAt = 0
local coverageLastSummary = "Kein Scan ausgefuehrt."
local coverageEntities = {}
local coverageHashToModel = {}
local coverageMappedModels = {}
local autoDiscoveredModels = {}
local autoDiscoverShapeCache = {}

local function notify(message)
    if GetResourceState("chat") == "started" then
        TriggerEvent("chat:addMessage", {
            color = { 255, 200, 0 },
            args = { "Billboards", message }
        })
        return
    end

    print(("[billboardscript][client] %s"):format(tostring(message)))
end

local function debugLog(message, ...)
    if not debugEnabled then
        return
    end

    if select("#", ...) > 0 then
        print(("[billboardscript][client][DEBUG] " .. message):format(...))
        return
    end

    print("[billboardscript][client][DEBUG] " .. tostring(message))
end

local function normalizeName(name)
    return tostring(name or ""):lower():gsub("_lod$", "")
end

local function sanitizeTextureName(name)
    local sanitized = tostring(name or ""):match("^%s*(.-)%s*$")
    if not sanitized or #sanitized == 0 then
        return nil
    end

    return sanitized
end

local function isTextureAllowed(txd, txn)
    if not requiredTextureNamePart or requiredTextureNamePart == "" then
        return true
    end

    local txdName = tostring(txd or ""):lower()
    local txnName = tostring(txn or ""):lower()
    return txdName:find(requiredTextureNamePart, 1, true) ~= nil
        or txnName:find(requiredTextureNamePart, 1, true) ~= nil
end

local function registerTextureTarget(txd, txn, sourceTag)
    local cleanTxd = sanitizeTextureName(txd)
    local cleanTxn = sanitizeTextureName(txn)
    if not cleanTxd or not cleanTxn then
        return false
    end

    if not isTextureAllowed(cleanTxd, cleanTxn) then
        return false
    end

    local key = ("%s|%s"):format(cleanTxd:lower(), cleanTxn:lower())
    if textureTargetKeys[key] then
        return false
    end

    textureTargetKeys[key] = true
    textureTargets[#textureTargets + 1] = {
        txd = cleanTxd,
        txn = cleanTxn
    }
    coverageMappedModels[normalizeName(cleanTxd)] = true
    coverageMappedModels[normalizeName(cleanTxn)] = true

    if replacementsApplied then
        AddReplaceTexture(cleanTxd, cleanTxn, RUNTIME_TXD, RUNTIME_TXN)
    end

    debugLog(
        "Texture-Target registriert: %s/%s (%s)",
        cleanTxd,
        cleanTxn,
        tostring(sourceTag or "unspecified")
    )
    return true
end

local function registerTargetsForModel(modelName, sourceTag)
    local cleanModel = sanitizeTextureName(modelName)
    if not cleanModel then
        return 0
    end

    local lodName = cleanModel .. "_lod"
    local added = 0

    if registerTextureTarget(cleanModel, cleanModel, sourceTag) then
        added = added + 1
    end
    if registerTextureTarget(cleanModel, lodName, sourceTag) then
        added = added + 1
    end
    if registerTextureTarget(lodName, cleanModel, sourceTag) then
        added = added + 1
    end
    if registerTextureTarget(lodName, lodName, sourceTag) then
        added = added + 1
    end

    return added
end

local function isBillboardLikeShape(modelHash)
    local cached = autoDiscoverShapeCache[modelHash]
    if cached ~= nil then
        return cached
    end

    local minDim, maxDim = GetModelDimensions(modelHash)
    if not minDim or not maxDim then
        autoDiscoverShapeCache[modelHash] = false
        return false
    end

    local sx = math.abs((maxDim.x or 0.0) - (minDim.x or 0.0))
    local sy = math.abs((maxDim.y or 0.0) - (minDim.y or 0.0))
    local sz = math.abs((maxDim.z or 0.0) - (minDim.z or 0.0))

    local smallest = sx
    if sy < smallest then
        smallest = sy
    end
    if sz < smallest then
        smallest = sz
    end

    local largest = sx
    if sy > largest then
        largest = sy
    end
    if sz > largest then
        largest = sz
    end

    local middle = (sx + sy + sz) - smallest - largest
    local faceArea = largest * middle
    local looksLikeBillboard = smallest <= autoDiscoverMaxDepth
        and largest >= autoDiscoverMinLongestSide
        and faceArea >= autoDiscoverMinFaceArea

    autoDiscoverShapeCache[modelHash] = looksLikeBillboard
    return looksLikeBillboard
end

if type(Config.AutoDiscoverKeywords) == "table" then
    for _, rawKeyword in ipairs(Config.AutoDiscoverKeywords) do
        local keyword = sanitizeTextureName(rawKeyword)
        if keyword then
            autoDiscoverKeywords[#autoDiscoverKeywords + 1] = keyword:lower()
        end
    end
end

if #autoDiscoverKeywords == 0 then
    autoDiscoverKeywords = {
        "billboards"
    }
end

if autoDiscoverEnabled and not canLookupArchetypeName then
    print("[billboardscript][client] Hinweis: GetEntityArchetypeName nicht verfuegbar, nutze Dimensions-Fallback.")
end

for _, target in ipairs(configuredTextureTargets) do
    if type(target) == "table" then
        registerTextureTarget(target.txd, target.txn, "config")
    end
end

for _, modelName in ipairs(coverageModels) do
    if type(modelName) == "string" and #modelName > 0 then
        coverageHashToModel[GetHashKey(modelName)] = modelName
    end
end

local function addCacheBuster(url)
    if not cacheBustEnabled then
        return url
    end

    local joiner = "?"
    if url:find("?", 1, true) then
        joiner = "&"
    end

    return ("%s%scache=%d"):format(url, joiner, GetGameTimer())
end

local function destroyDui()
    if duiObject then
        DestroyDui(duiObject)
        duiObject = nil
    end
end

local function applyTextureReplacements()
    if replacementsApplied then
        return
    end

    for _, target in ipairs(textureTargets) do
        AddReplaceTexture(target.txd, target.txn, RUNTIME_TXD, RUNTIME_TXN)
    end

    replacementsApplied = true
    debugLog("Texture-Replacements aktiv: %s Targets", tostring(#textureTargets))
end

local function removeTextureReplacements()
    if not replacementsApplied then
        return
    end

    for _, target in ipairs(textureTargets) do
        RemoveReplaceTexture(target.txd, target.txn)
    end

    replacementsApplied = false
    debugLog("Texture-Replacements entfernt.")
end

local function ensureDui(url)
    local resolvedUrl = addCacheBuster(url)

    if not duiObject then
        duiObject = CreateDui(resolvedUrl, duiWidth, duiHeight)

        if not runtimeTxd then
            runtimeTxd = CreateRuntimeTxd(RUNTIME_TXD)
        end

        local duiHandle = GetDuiHandle(duiObject)
        CreateRuntimeTextureFromDuiHandle(runtimeTxd, RUNTIME_TXN, duiHandle)
        applyTextureReplacements()
        debugLog("DUI erstellt: %s", resolvedUrl)
        return
    end

    SetDuiUrl(duiObject, resolvedUrl)
    debugLog("DUI URL gewechselt: %s", resolvedUrl)

    if not replacementsApplied then
        applyTextureReplacements()
    end
end

local function disableBillboards()
    if duiObject then
        SetDuiUrl(duiObject, "about:blank")
    end

    removeTextureReplacements()
    hasRenderedCurrent = false
    currentUrlIndex = 1
    nextSwitchAt = 0
    debugLog("Billboards deaktiviert.")
end

local function sanitizeCoverageRadius(rawRadius)
    local value = tonumber(rawRadius) or coverageDefaultRadius
    if value < coverageMinRadius then
        value = coverageMinRadius
    end
    if value > coverageMaxRadius then
        value = coverageMaxRadius
    end
    return value
end

local function isAutoDiscoverMatch(name)
    for _, keyword in ipairs(autoDiscoverKeywords) do
        if name:find(keyword, 1, true) then
            return true
        end
    end

    return false
end

local function getModelHashLabel(modelHash)
    return ("hash_0x%08X"):format((modelHash or 0) & 0xFFFFFFFF)
end

local function tryRegisterDiscoveredModel(modelHash, modelName, sourceTag)
    local normalizedModel = sanitizeTextureName(modelName)
    if not normalizedModel then
        return false, 0
    end

    local discoveryKey = ("%s|%s"):format(tostring(modelHash), normalizedModel:lower())
    if autoDiscoveredModels[discoveryKey] then
        return false, 0
    end

    autoDiscoveredModels[discoveryKey] = true
    coverageHashToModel[modelHash] = normalizedModel

    local addedTargets = registerTargetsForModel(normalizedModel, sourceTag)
    return true, addedTargets
end

local function discoverTextureTargets()
    if not autoDiscoverEnabled then
        return
    end

    if (not activeSettings or not activeSettings.enabled) and not coverageEnabled then
        return
    end

    local ped = PlayerPedId()
    if ped == 0 then
        return
    end

    local playerCoords = GetEntityCoords(ped)
    local objects = GetGamePool("CObject") or {}
    local addedModels = 0
    local addedTargets = 0

    for _, object in ipairs(objects) do
        local coords = GetEntityCoords(object)
        local distance = #(coords - playerCoords)

        if distance <= autoDiscoverRadius then
            local modelHash = GetEntityModel(object)
            local matchedByShape = autoDiscoverByDimensions and isBillboardLikeShape(modelHash)
            local archetypeName = ""

            if canLookupArchetypeName then
                archetypeName = tostring(GetEntityArchetypeName(object) or ""):lower()
            end

            local matchedByName = #archetypeName > 0 and isAutoDiscoverMatch(archetypeName)
            if matchedByName or matchedByShape then
                local modelName = archetypeName
                if #modelName == 0 then
                    modelName = coverageHashToModel[modelHash] or ""
                end

                if #modelName == 0 then
                    local hashLabel = getModelHashLabel(modelHash)
                    local hashOnlyKey = ("hash_only|%s"):format(hashLabel)
                    if not autoDiscoveredModels[hashOnlyKey] then
                        autoDiscoveredModels[hashOnlyKey] = true
                        coverageHashToModel[modelHash] = hashLabel
                        addedModels = addedModels + 1
                        debugLog(
                            "Auto-Discovery: Billboard-Objekt ueber Form erkannt, aber ohne Modellname (%s).",
                            hashLabel
                        )
                    end
                else
                    local discovered, newTargets = tryRegisterDiscoveredModel(
                        modelHash,
                        modelName,
                        matchedByName and "auto_discovery_name" or "auto_discovery_shape"
                    )

                    if discovered then
                        addedModels = addedModels + 1
                        addedTargets = addedTargets + newTargets
                    end
                end
            end
        end
    end

    if addedModels > 0 then
        debugLog(
            "Auto-Discovery: %s neue Modellnamen erkannt, %s neue Texture-Targets aktiv.",
            tostring(addedModels),
            tostring(addedTargets)
        )
    end
end

local function requestSettings(reason)
    local now = GetGameTimer()
    if (now - lastSettingsRequestAt) < 1000 then
        return
    end

    lastSettingsRequestAt = now
    debugLog("Fordere Settings vom Server an (%s).", tostring(reason or "unspecified"))
    TriggerServerEvent("billboard:server:requestSettings")
end

local function normalizeSettings(settings)
    if type(settings) ~= "table" then
        return nil
    end

    local normalized = {
        enabled = settings.enabled == true,
        rotationSeconds = math.floor(tonumber(settings.rotationSeconds) or defaultRotationSeconds),
        urls = {}
    }

    for _, url in ipairs(settings.urls or {}) do
        if type(url) == "string" and #url > 0 then
            normalized.urls[#normalized.urls + 1] = url
        end
    end

    if normalized.rotationSeconds < minRotationSeconds then
        normalized.rotationSeconds = minRotationSeconds
    end

    if normalized.rotationSeconds > maxRotationSeconds then
        normalized.rotationSeconds = maxRotationSeconds
    end

    if #normalized.urls == 0 then
        normalized.enabled = false
    end

    return normalized
end

local function setSettings(settings)
    hasReceivedSettings = true
    activeSettings = normalizeSettings(settings)

    if not activeSettings or not activeSettings.enabled then
        disableBillboards()
        debugLog("Keine aktiven Billboard-Einstellungen.")
        return
    end

    currentUrlIndex = 1
    hasRenderedCurrent = false
    nextSwitchAt = 0
    debugLog(
        "Neue Einstellungen: enabled=%s rotation=%s urls=%s",
        tostring(activeSettings.enabled),
        tostring(activeSettings.rotationSeconds),
        tostring(#activeSettings.urls)
    )
end

local function drawText3d(coords, text, r, g, b)
    local onScreen, x, y = World3dToScreen2d(coords.x, coords.y, coords.z)
    if not onScreen then
        return
    end

    SetTextScale(0.28, 0.28)
    SetTextFont(4)
    SetTextProportional(1)
    SetTextCentre(true)
    SetTextColour(r, g, b, 220)
    SetTextOutline()
    BeginTextCommandDisplayText("STRING")
    AddTextComponentSubstringPlayerName(text)
    EndTextCommandDisplayText(x, y)
end

local function buildModelSummary(counts)
    local entries = {}
    for modelName, count in pairs(counts) do
        entries[#entries + 1] = { model = modelName, count = count }
    end

    table.sort(entries, function(a, b)
        if a.count == b.count then
            return a.model < b.model
        end
        return a.count > b.count
    end)

    local out = {}
    local maxParts = 6
    for i = 1, math.min(#entries, maxParts) do
        out[#out + 1] = ("%s x%s"):format(entries[i].model, entries[i].count)
    end

    if #entries > maxParts then
        out[#out + 1] = ("+%s weitere Modelle"):format(#entries - maxParts)
    end

    return table.concat(out, ", ")
end

local function performCoverageScan(radius, keepEntities)
    local ped = PlayerPedId()
    if ped == 0 then
        return nil
    end

    local playerCoords = GetEntityCoords(ped)
    local objects = GetGamePool("CObject") or {}
    local counts = {}
    local entities = {}
    local unmappedSet = {}
    local total = 0

    for _, object in ipairs(objects) do
        local modelName = coverageHashToModel[GetEntityModel(object)]
        if modelName then
            local coords = GetEntityCoords(object)
            local distance = #(coords - playerCoords)

            if distance <= radius then
                total = total + 1
                counts[modelName] = (counts[modelName] or 0) + 1

                local mapped = coverageMappedModels[normalizeName(modelName)] == true
                if not mapped then
                    unmappedSet[modelName] = true
                end

                if keepEntities and #entities < coverageMaxDrawEntries then
                    entities[#entities + 1] = {
                        coords = coords,
                        model = modelName,
                        mapped = mapped,
                        distance = distance
                    }
                end
            end
        end
    end

    table.sort(entities, function(a, b)
        return a.distance < b.distance
    end)

    local unmapped = {}
    for name in pairs(unmappedSet) do
        unmapped[#unmapped + 1] = name
    end
    table.sort(unmapped)

    local summary
    if total == 0 then
        summary = ("Coverage: Keine Vanilla-Billboards im Radius %.0fm gefunden."):format(radius)
    else
        local details = buildModelSummary(counts)
        summary = ("Coverage: %s Billboard(s) im Radius %.0fm. %s"):format(total, radius, details)
        if #unmapped > 0 then
            summary = summary .. (" | UNMAPPED: %s"):format(table.concat(unmapped, ", "))
        else
            summary = summary .. " | Alle gefundenen Modelle sind gemappt."
        end
    end

    coverageLastScanAt = GetGameTimer()
    coverageLastSummary = summary
    coverageEntities = keepEntities and entities or {}

    return {
        total = total,
        counts = counts,
        unmapped = unmapped,
        summary = summary
    }
end

local function setCoverageMode(state, radius, silent)
    coverageEnabled = state == true
    coverageRadius = sanitizeCoverageRadius(radius)

    if not coverageEnabled then
        coverageEntities = {}
    end

    if not silent then
        notify(
            ("Coverage-Mode: %s (Radius %.0fm)"):format(
                coverageEnabled and "AN" or "AUS",
                coverageRadius
            )
        )
    end
end

local function openUi(settings, limits)
    if uiOpen then
        return
    end

    uiOpen = true
    SetNuiFocus(true, true)
    SendNUIMessage({
        type = "open",
        settings = settings,
        limits = limits
    })
    debugLog("Admin-UI geoeffnet.")
end

local function closeUi()
    if not uiOpen then
        return
    end

    uiOpen = false
    SetNuiFocus(false, false)
    SendNUIMessage({ type = "close" })
    debugLog("Admin-UI geschlossen.")
end

RegisterNetEvent("billboard:client:notify", function(message)
    notify(message)
end)

RegisterNetEvent("billboard:client:openUi", function(settings, limits)
    openUi(settings, limits)
end)

RegisterNetEvent("billboard:client:applySettings", function(settings)
    setSettings(settings)
end)

RegisterNetEvent("billboard:client:setDebug", function(state)
    debugEnabled = state == true
    debugLog("Debug-Modus synchronisiert: %s", debugEnabled and "AN" or "AUS")
end)

RegisterNetEvent("billboard:client:coverageCommand", function(payload)
    if type(payload) ~= "table" then
        return
    end

    local action = string.lower(tostring(payload.action or "toggle"))
    local radius = sanitizeCoverageRadius(payload.radius)

    if action == "status" then
        local status = coverageEnabled and "AN" or "AUS"
        notify(("Coverage-Mode ist %s (Radius %.0fm)."):format(status, coverageRadius))
        notify(coverageLastSummary)
        return
    end

    if action == "scan" then
        local result = performCoverageScan(radius, false)
        if result then
            notify(result.summary)
        else
            notify("Coverage-Scan konnte nicht ausgefuehrt werden.")
        end
        return
    end

    if action == "on" then
        setCoverageMode(true, radius, false)
    elseif action == "off" then
        setCoverageMode(false, radius, false)
    else
        setCoverageMode(not coverageEnabled, radius, false)
    end

    if coverageEnabled then
        local result = performCoverageScan(coverageRadius, true)
        if result then
            notify(result.summary)
        end
    end
end)

RegisterNUICallback("close", function(_, cb)
    if not uiOpen then
        cb({ ok = false, error = "ui_not_open" })
        return
    end

    closeUi()
    cb({ ok = true })
end)

RegisterNUICallback("saveSettings", function(data, cb)
    if not uiOpen then
        cb({ ok = false, error = "ui_not_open" })
        return
    end

    if type(data) ~= "table" then
        cb({ ok = false, error = "invalid_payload" })
        return
    end

    TriggerServerEvent("billboard:server:saveSettings", data)
    closeUi()
    cb({ ok = true })
end)

CreateThread(function()
    Wait(1500)
    requestSettings("initial_boot")
end)

CreateThread(function()
    while true do
        Wait(coverageScanIntervalMs)

        if coverageEnabled then
            performCoverageScan(coverageRadius, true)
        end
    end
end)

CreateThread(function()
    if not autoDiscoverEnabled then
        return
    end

    Wait(2500)
    while true do
        discoverTextureTargets()
        Wait(autoDiscoverIntervalMs)
    end
end)

CreateThread(function()
    while true do
        if not coverageEnabled then
            Wait(500)
        else
            Wait(0)
            local playerCoords = GetEntityCoords(PlayerPedId())

            for _, entry in ipairs(coverageEntities) do
                local distance = #(entry.coords - playerCoords)
                if distance <= coverageDrawDistance then
                    local colorR = entry.mapped and 120 or 255
                    local colorG = entry.mapped and 255 or 90
                    local colorB = entry.mapped and 120 or 90
                    local stateLabel = entry.mapped and "MAPPED" or "UNMAPPED"

                    DrawMarker(
                        0,
                        entry.coords.x,
                        entry.coords.y,
                        entry.coords.z + 2.2,
                        0.0,
                        0.0,
                        0.0,
                        0.0,
                        0.0,
                        0.0,
                        0.18,
                        0.18,
                        0.18,
                        colorR,
                        colorG,
                        colorB,
                        180,
                        false,
                        false,
                        2,
                        false,
                        nil,
                        nil,
                        false
                    )

                    drawText3d(
                        vector3(entry.coords.x, entry.coords.y, entry.coords.z + 2.4),
                        ("%s [%s]"):format(entry.model, stateLabel),
                        colorR,
                        colorG,
                        colorB
                    )
                end
            end
        end
    end
end)

CreateThread(function()
    while true do
        Wait(settingsRetryMs)

        if not hasReceivedSettings then
            requestSettings("retry_no_settings")
        end
    end
end)

CreateThread(function()
    while true do
        Wait(500)

        if not activeSettings or not activeSettings.enabled or #activeSettings.urls == 0 then
            Wait(1000)
        else
            local now = GetGameTimer()

            if not hasRenderedCurrent then
                ensureDui(activeSettings.urls[currentUrlIndex])
                hasRenderedCurrent = true
                nextSwitchAt = now + (activeSettings.rotationSeconds * 1000)
                debugLog("Starte Billboard-Rotation mit URL #%s", tostring(currentUrlIndex))
            elseif now >= nextSwitchAt then
                currentUrlIndex = (currentUrlIndex % #activeSettings.urls) + 1
                ensureDui(activeSettings.urls[currentUrlIndex])
                nextSwitchAt = now + (activeSettings.rotationSeconds * 1000)
                debugLog("Rotation weiter auf URL #%s", tostring(currentUrlIndex))
            end
        end
    end
end)

AddEventHandler("onClientResourceStart", function(startedResource)
    if startedResource ~= GetCurrentResourceName() then
        return
    end

    requestSettings("resource_start")
end)

RegisterNetEvent("esx:playerLoaded", function()
    requestSettings("player_loaded")
end)

AddEventHandler("onResourceStop", function(stoppedResource)
    if stoppedResource ~= GetCurrentResourceName() then
        return
    end

    closeUi()
    setCoverageMode(false, coverageRadius, true)
    disableBillboards()
    destroyDui()
end)
