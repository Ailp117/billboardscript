Config = {}

Config.AdminCommand = "billboardadmin"
Config.DebugCommand = "billboarddebug"
Config.CoverageCommand = "billboardcoverage"
Config.AdminGroups = { "admin", "superadmin" }
Config.AcePermission = "billboard.admin"
Config.Debug = false

Config.DatabaseTable = "billboard_settings"
Config.DatabaseRowId = 1
Config.AutoCreateSchema = true

Config.DefaultSettings = {
    enabled = true,
    rotationSeconds = 30,
    urls = {
        "https://picsum.photos/1920/1080?random=1001",
        "https://picsum.photos/1920/1080?random=1002",
        "https://picsum.photos/1920/1080?random=1003"
    }
}

Config.MinRotationSeconds = 5
Config.MaxRotationSeconds = 600
Config.MaxUrls = 20
Config.MaxUrlLength = 512
Config.MaxIncomingPayloadUrls = 200
Config.MaxIncomingPayloadBytes = 65535

Config.RequestCooldownMs = 1000
Config.SaveCooldownMs = 2000

Config.DuiWidth = 1920
Config.DuiHeight = 1080
Config.CacheBust = true
Config.ClientSettingsRetryMs = 5000
Config.CoverageDefaultRadius = 350.0
Config.CoverageMinRadius = 50.0
Config.CoverageMaxRadius = 1500.0
Config.CoverageScanIntervalMs = 5000
Config.CoverageDrawDistance = 80.0
Config.CoverageMaxDrawEntries = 60
-- Auto-discovers nearby billboard-like model names (e.g. custom map assets)
-- and creates txd/txn replacements with name + name_lod combos.
Config.TextureNameMustContain = "billboards"
Config.AutoDiscoverBillboardTargets = true
Config.AutoDiscoverRadius = 800.0
Config.AutoDiscoverIntervalMs = 10000
-- Optional shape-based fallback for map-placed world billboards.
-- Helps when naming is inconsistent, but can be tuned if too broad.
Config.AutoDiscoverByDimensions = false
Config.AutoDiscoverMinFaceArea = 20.0
Config.AutoDiscoverMinLongestSide = 4.5
Config.AutoDiscoverMaxDepth = 2.5
Config.AutoDiscoverKeywords = {
    "billboards"
}

-- All known vanilla billboard textures.
-- LOD variants are auto-added so replacements stay visible at distance.
Config.VanillaBillboardTextures = {
    "prop_billboard_01",
    "prop_billboard_02",
    "prop_billboard_03",
    "prop_billboard_04",
    "prop_billboard_05",
    "prop_billboard_05a",
    "prop_billboard_05b",
    "prop_billboard_06",
    "prop_billboard_07",
    "prop_billboard_08",
    "prop_billboard_09",
    "prop_billboard_09wall",
    "prop_billboard_10",
    "prop_billboard_11",
    "prop_billboard_12",
    "prop_billboard_13",
    "prop_billboard_14",
    "prop_billboard_15",
    "prop_billboard_16"
}

-- Model names used for coverage scans. Can be extended for custom maps.
Config.VanillaBillboardModels = {
    "prop_billboard_01",
    "prop_billboard_02",
    "prop_billboard_03",
    "prop_billboard_04",
    "prop_billboard_05",
    "prop_billboard_05a",
    "prop_billboard_05b",
    "prop_billboard_06",
    "prop_billboard_07",
    "prop_billboard_08",
    "prop_billboard_09",
    "prop_billboard_09wall",
    "prop_billboard_10",
    "prop_billboard_11",
    "prop_billboard_12",
    "prop_billboard_13",
    "prop_billboard_14",
    "prop_billboard_15",
    "prop_billboard_16"
}

Config.TextureTargets = {}
-- Optional manual txd/txn pairs for custom maps:
-- { txd = "my_txd_name", txn = "my_texture_name" }
Config.CustomTextureTargets = {}

local seenTextureTargets = {}

local function addTextureTarget(txd, txn)
    local key = ("%s|%s"):format(txd, txn)
    if seenTextureTargets[key] then
        return
    end

    seenTextureTargets[key] = true
    Config.TextureTargets[#Config.TextureTargets + 1] = {
        txd = txd,
        txn = txn
    }
end

for _, textureName in ipairs(Config.VanillaBillboardTextures) do
    addTextureTarget(textureName, textureName)
    addTextureTarget(textureName, textureName .. "_lod")
    addTextureTarget(textureName .. "_lod", textureName)
    addTextureTarget(textureName .. "_lod", textureName .. "_lod")
end

for _, target in ipairs(Config.CustomTextureTargets) do
    if type(target) == "table" then
        addTextureTarget(target.txd, target.txn)
    end
end
