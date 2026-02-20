local resourceName = GetCurrentResourceName()
local ESX
local currentSettings
local dbTableName = tostring(Config.DatabaseTable or "billboard_settings")
local debugEnabled = Config.Debug == true
local initialized = false
local startupError = nil
local saveInProgress = false
local lastRequestAt = {}
local lastSaveAt = {}
local requestCooldownMs = math.max(0, math.floor(tonumber(Config.RequestCooldownMs) or 1000))
local saveCooldownMs = math.max(0, math.floor(tonumber(Config.SaveCooldownMs) or 2000))
local maxIncomingPayloadUrls = math.max(1, math.floor(tonumber(Config.MaxIncomingPayloadUrls) or 200))
local maxIncomingPayloadBytes = math.max(1024, math.floor(tonumber(Config.MaxIncomingPayloadBytes) or 65535))
local minRotationSeconds = math.max(1, math.floor(tonumber(Config.MinRotationSeconds) or 5))
local maxRotationSeconds = math.max(minRotationSeconds, math.floor(tonumber(Config.MaxRotationSeconds) or 600))
local maxUrls = math.max(1, math.floor(tonumber(Config.MaxUrls) or 20))
local maxUrlLength = math.max(8, math.floor(tonumber(Config.MaxUrlLength) or 512))
local coverageMinRadius = math.max(1.0, tonumber(Config.CoverageMinRadius) or 50.0)
local coverageMaxRadius = math.max(coverageMinRadius, tonumber(Config.CoverageMaxRadius) or 1500.0)
local coverageDefaultRadius = math.min(
    coverageMaxRadius,
    math.max(coverageMinRadius, tonumber(Config.CoverageDefaultRadius) or 350.0)
)

local function logInfo(message)
    print(("[%s] %s"):format(resourceName, message))
end

local function logDebug(message, ...)
    if not debugEnabled then
        return
    end

    if select("#", ...) > 0 then
        logInfo(("[DEBUG] " .. message):format(...))
        return
    end

    logInfo("[DEBUG] " .. tostring(message))
end

local function notifyPlayer(source, message)
    TriggerClientEvent("billboard:client:notify", source, message)
end

local function nowMs()
    return GetGameTimer()
end

local function isRateLimited(source, tracker, cooldownMs)
    local src = tonumber(source) or source

    if src == 0 or cooldownMs <= 0 then
        return false, 0
    end

    local now = nowMs()
    local last = tracker[src]
    if last and (now - last) < cooldownMs then
        return true, (cooldownMs - (now - last))
    end

    tracker[src] = now
    return false, 0
end

local function clearPlayerState(source)
    local src = tonumber(source) or source
    lastRequestAt[src] = nil
    lastSaveAt[src] = nil
end

AddEventHandler("playerDropped", function()
    clearPlayerState(source)
end)

local function trim(value)
    return value:match("^%s*(.-)%s*$")
end

local function copySettings(settings)
    local copiedUrls = {}
    for i = 1, #settings.urls do
        copiedUrls[i] = settings.urls[i]
    end

    return {
        enabled = settings.enabled == true,
        rotationSeconds = settings.rotationSeconds,
        urls = copiedUrls
    }
end

local function payloadByteSize(input)
    local ok, encoded = pcall(json.encode, input)
    if not ok or type(encoded) ~= "string" then
        return math.huge
    end

    return #encoded
end

local function sanitizeSettings(input)
    if type(input) ~= "table" then
        return nil, "Payload ist ungueltig."
    end

    local payloadBytes = payloadByteSize(input)
    if payloadBytes > maxIncomingPayloadBytes then
        return nil, ("Payload zu gross (%s Bytes)."):format(payloadBytes)
    end

    local enabled = input.enabled == true
    local defaultRotation = math.floor(tonumber((Config.DefaultSettings or {}).rotationSeconds) or 30)
    local rotationSeconds = math.floor(tonumber(input.rotationSeconds) or defaultRotation)

    if rotationSeconds < minRotationSeconds then
        rotationSeconds = minRotationSeconds
    end

    if rotationSeconds > maxRotationSeconds then
        rotationSeconds = maxRotationSeconds
    end

    if type(input.urls) ~= "table" then
        return nil, "URLs muessen als Liste gesendet werden."
    end

    local sanitizedUrls = {}
    local seen = {}
    local numericKeys = {}

    for key in pairs(input.urls) do
        if type(key) ~= "number" or key < 1 or key % 1 ~= 0 then
            return nil, "URLs muessen als numerische Liste gesendet werden."
        end
        numericKeys[#numericKeys + 1] = key
    end

    table.sort(numericKeys)

    if #numericKeys > maxIncomingPayloadUrls then
        return nil, "Zu viele URL-Eintraege im Payload."
    end

    for _, key in ipairs(numericKeys) do
        local rawUrl = input.urls[key]

        if type(rawUrl) == "string" then
            local url = trim(rawUrl)

            if #url > 0 and #url <= maxUrlLength and url:match("^https?://") then
                if not seen[url] then
                    sanitizedUrls[#sanitizedUrls + 1] = url
                    seen[url] = true
                end
            end
        end
    end

    if #sanitizedUrls == 0 then
        return nil, "Mindestens eine gueltige URL (http/https) wird benoetigt."
    end

    if #sanitizedUrls > maxUrls then
        local limited = {}
        for i = 1, maxUrls do
            limited[#limited + 1] = sanitizedUrls[i]
        end
        sanitizedUrls = limited
    end

    return {
        enabled = enabled,
        rotationSeconds = rotationSeconds,
        urls = sanitizedUrls
    }
end

local function settingsEqual(a, b)
    if not a or not b then
        return false
    end

    if a.enabled ~= b.enabled or a.rotationSeconds ~= b.rotationSeconds then
        return false
    end

    if #a.urls ~= #b.urls then
        return false
    end

    for i = 1, #a.urls do
        if a.urls[i] ~= b.urls[i] then
            return false
        end
    end

    return true
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

local function getValidatedTableName()
    local tableName = tostring(Config.DatabaseTable or "")
    if not tableName:match("^[%w_]+$") then
        error("Config.DatabaseTable darf nur Buchstaben, Zahlen und Unterstriche enthalten.")
    end

    return tableName
end

local function setDebugEnabled(newState, actorSource)
    debugEnabled = newState == true
    TriggerClientEvent("billboard:client:setDebug", -1, debugEnabled)

    local actor = actorSource == 0 and "console" or ("player " .. tostring(actorSource))
    logInfo(("Debug-Modus %s (%s)."):format(debugEnabled and "aktiviert" or "deaktiviert", actor))
end

local function dbExecute(query, params)
    local ok, result = pcall(function()
        return MySQL.query.await(query, params or {})
    end)

    if not ok then
        return false, result
    end

    return true, result
end

local function dbSingle(query, params)
    local ok, result = pcall(function()
        return MySQL.single.await(query, params or {})
    end)

    if not ok then
        return nil, result
    end

    return result, nil
end

local function ensureDatabaseSchema()
    local query = ([[
        CREATE TABLE IF NOT EXISTS `%s` (
            `id` INT NOT NULL,
            `settings` LONGTEXT NOT NULL,
            `updated_at` TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
            PRIMARY KEY (`id`)
        ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;
    ]]):format(dbTableName)

    local ok, err = dbExecute(query)
    if not ok then
        error(("Konnte Tabelle `%s` nicht erstellen: %s"):format(dbTableName, tostring(err)))
    end

    logDebug("Datenbankschema geprueft: %s", dbTableName)
end

local function saveSettings()
    local encoded = json.encode(currentSettings)
    local query = ("INSERT INTO `%s` (id, settings) VALUES (?, ?) ON DUPLICATE KEY UPDATE settings = VALUES(settings), updated_at = CURRENT_TIMESTAMP"):format(dbTableName)
    local ok, err = dbExecute(query, { Config.DatabaseRowId, encoded })

    if not ok then
        return false, err
    end

    logDebug(
        "Einstellungen gespeichert: enabled=%s rotation=%s urls=%s",
        tostring(currentSettings.enabled),
        tostring(currentSettings.rotationSeconds),
        tostring(#currentSettings.urls)
    )

    return true
end

local function loadDefaultSettings()
    local fallback, err = sanitizeSettings(Config.DefaultSettings)
    if not fallback then
        error(("DefaultSettings ungueltig: %s"):format(err))
    end
    currentSettings = fallback
end

local function loadSettings()
    local query = ("SELECT settings FROM `%s` WHERE id = ? LIMIT 1"):format(dbTableName)
    local row, dbErr = dbSingle(query, { Config.DatabaseRowId })

    if dbErr then
        error(("Konnte Billboard-Einstellungen nicht laden: %s"):format(tostring(dbErr)))
    end

    if not row or not row.settings or row.settings == "" then
        loadDefaultSettings()
        local ok, saveErr = saveSettings()
        if not ok then
            logInfo(("Konnte Default-Einstellungen nicht speichern: %s"):format(tostring(saveErr)))
        end
        return
    end

    local decoded = json.decode(row.settings)
    local sanitized, err = sanitizeSettings(decoded)
    if not sanitized then
        logInfo(("Gespeicherte DB-Einstellungen defekt (%s), nutze Defaults."):format(err))
        loadDefaultSettings()
        local ok, saveErr = saveSettings()
        if not ok then
            logInfo(("Konnte Default-Einstellungen nicht speichern: %s"):format(tostring(saveErr)))
        end
        return
    end

    currentSettings = sanitized
    logDebug(
        "Einstellungen geladen: enabled=%s rotation=%s urls=%s",
        tostring(currentSettings.enabled),
        tostring(currentSettings.rotationSeconds),
        tostring(#currentSettings.urls)
    )
end

local function ensureInitialized(source)
    if initialized then
        return true
    end

    if source and source ~= 0 then
        notifyPlayer(source, "System startet noch. Bitte in wenigen Sekunden erneut versuchen.")
    end

    if startupError then
        logInfo(("Init-Fehler: %s"):format(startupError))
    end

    return false
end

local function isPlayerAdmin(source)
    if source == 0 then
        return true
    end

    if IsPlayerAceAllowed(source, Config.AcePermission) then
        return true
    end

    if not ESX then
        return false
    end

    local xPlayer = ESX.GetPlayerFromId(source)
    if not xPlayer or not xPlayer.getGroup then
        return false
    end

    local group = xPlayer.getGroup()

    for _, allowed in ipairs(Config.AdminGroups) do
        if group == allowed then
            return true
        end
    end

    return false
end

local function getUiLimits()
    return {
        minRotationSeconds = minRotationSeconds,
        maxRotationSeconds = maxRotationSeconds,
        maxUrls = maxUrls,
        maxUrlLength = maxUrlLength
    }
end

local function initializeResource()
    local ok, result = pcall(function()
        return exports["es_extended"]:getSharedObject()
    end)

    if ok then
        ESX = result
    else
        logInfo("Konnte ESX nicht laden. Nur ACE-Adminchecks sind aktiv.")
    end

    dbTableName = getValidatedTableName()

    if Config.AutoCreateSchema then
        ensureDatabaseSchema()
    end

    loadSettings()
    initialized = true
    TriggerClientEvent("billboard:client:setDebug", -1, debugEnabled)
    logDebug("Debug-Modus ist aktiv.")
    logInfo(
        ("Resource gestartet. Commands: /%s, /%s, /%s"):format(
            Config.AdminCommand,
            Config.DebugCommand,
            Config.CoverageCommand
        )
    )
end

CreateThread(function()
    MySQL.ready(function()
        local ok, err = pcall(initializeResource)
        if not ok then
            startupError = tostring(err)
            initialized = false
            logInfo(("Resource-Init fehlgeschlagen: %s"):format(startupError))
        end
    end)
end)

RegisterCommand(Config.AdminCommand, function(source)
    if source == 0 then
        logInfo("Dieser Command ist nur Ingame nutzbar.")
        return
    end

    if not isPlayerAdmin(source) then
        notifyPlayer(source, "Keine Berechtigung.")
        return
    end

    if not ensureInitialized(source) then
        return
    end

    if not currentSettings then
        loadDefaultSettings()
    end

    logDebug("Admin-UI geoeffnet von Player %s", tostring(source))
    TriggerClientEvent("billboard:client:openUi", source, copySettings(currentSettings), getUiLimits())
end, false)

RegisterCommand(Config.DebugCommand, function(source, args)
    if source ~= 0 and not isPlayerAdmin(source) then
        notifyPlayer(source, "Keine Berechtigung.")
        return
    end

    local action = string.lower(tostring(args[1] or "toggle"))
    local targetState = debugEnabled

    if action == "status" then
        local statusMessage = ("Debug ist %s."):format(debugEnabled and "AN" or "AUS")
        if source == 0 then
            logInfo(statusMessage)
        else
            notifyPlayer(source, statusMessage)
        end
        return
    elseif action == "on" or action == "1" or action == "true" then
        targetState = true
    elseif action == "off" or action == "0" or action == "false" then
        targetState = false
    elseif action == "toggle" then
        targetState = not debugEnabled
    else
        local usage = ("Nutze /%s [on|off|toggle|status]"):format(Config.DebugCommand)
        if source == 0 then
            logInfo(usage)
        else
            notifyPlayer(source, usage)
        end
        return
    end

    if targetState == debugEnabled then
        local noChange = ("Debug ist bereits %s."):format(debugEnabled and "AN" or "AUS")
        if source == 0 then
            logInfo(noChange)
        else
            notifyPlayer(source, noChange)
        end
        return
    end

    setDebugEnabled(targetState, source)

    if source ~= 0 then
        notifyPlayer(source, ("Debug ist jetzt %s."):format(targetState and "AN" or "AUS"))
    end
end, false)

RegisterCommand(Config.CoverageCommand, function(source, args)
    if source == 0 then
        logInfo("Coverage-Command ist nur Ingame nutzbar.")
        return
    end

    if not isPlayerAdmin(source) then
        notifyPlayer(source, "Keine Berechtigung.")
        return
    end

    local action = string.lower(tostring(args[1] or "toggle"))
    local radius = sanitizeCoverageRadius(args[2])

    if action ~= "toggle" and action ~= "on" and action ~= "off" and action ~= "scan" and action ~= "status" then
        notifyPlayer(source, ("Nutze /%s [toggle|on|off|scan|status] [radius]"):format(Config.CoverageCommand))
        return
    end

    TriggerClientEvent("billboard:client:coverageCommand", source, {
        action = action,
        radius = radius
    })
end, false)

RegisterNetEvent("billboard:server:requestSettings", function()
    local source = source

    if not ensureInitialized(source) then
        return
    end

    local limited = isRateLimited(source, lastRequestAt, requestCooldownMs)
    if limited then
        return
    end

    if not currentSettings then
        loadDefaultSettings()
    end

    TriggerClientEvent("billboard:client:applySettings", source, copySettings(currentSettings))
    TriggerClientEvent("billboard:client:setDebug", source, debugEnabled)
    logDebug("Settings + Debugstatus an Player %s gesendet", tostring(source))
end)

RegisterNetEvent("billboard:server:saveSettings", function(payload)
    local source = source

    if not ensureInitialized(source) then
        return
    end

    if not isPlayerAdmin(source) then
        logInfo(("Player %s hat unerlaubt saveSettings aufgerufen."):format(source))
        return
    end

    local limited, remainingMs = isRateLimited(source, lastSaveAt, saveCooldownMs)
    if limited then
        notifyPlayer(source, ("Bitte warte %.1f Sekunden."):format(remainingMs / 1000))
        return
    end

    if saveInProgress then
        notifyPlayer(source, "Speichern laeuft bereits, bitte kurz warten.")
        return
    end

    local sanitized, err = sanitizeSettings(payload)
    if not sanitized then
        notifyPlayer(source, ("Speichern fehlgeschlagen: %s"):format(err))
        return
    end

    if currentSettings and settingsEqual(currentSettings, sanitized) then
        notifyPlayer(source, "Keine Aenderung erkannt.")
        logDebug("Save von Player %s verworfen: unveraenderte Daten.", tostring(source))
        return
    end

    saveInProgress = true
    currentSettings = sanitized
    local ok, dbErr = saveSettings()
    saveInProgress = false

    if not ok then
        notifyPlayer(source, "Speichern fehlgeschlagen: Datenbankfehler.")
        logInfo(("DB-Fehler beim Speichern durch Player %s: %s"):format(source, tostring(dbErr)))
        return
    end

    TriggerClientEvent("billboard:client:applySettings", -1, copySettings(currentSettings))
    logDebug("Einstellungen an alle Clients verteilt.")
    notifyPlayer(source, "Billboard-Einstellungen gespeichert.")
    logInfo(("Player %s hat Billboard-Einstellungen aktualisiert."):format(source))
end)
