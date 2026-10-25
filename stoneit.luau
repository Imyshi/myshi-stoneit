-- =====================================================================
-- MYSHI HUB - COMPACT STEAL RADAR
-- UI    : Fluent-Pro Modded, compact left-tab layout
-- Theme : Charcoal (dark, text putih)
-- =====================================================================

local CoreGui = game:GetService("CoreGui")
local Players = game:GetService("Players")
local Workspace = game:GetService("Workspace")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local HttpService = game:GetService("HttpService")
local RunService = game:GetService("RunService")
local LocalPlayer = Players.LocalPlayer

FLUENT_URL = "https://github.com/StyearX/Fluent-Modded/releases/download/1.6.0/main.lua"
UI_NAME = "Myshi Hub"
REFRESH_INTERVAL = 1
AUTO_STEAL_TIMEOUT = 8
AUTO_STEAL_RETRY_DELAY = 0.08
AUTO_STEAL_TARGET_COOLDOWN = 2.5
AUTO_STEAL_TP_SETTLE = 0.18
PROMPT_MAX_DISTANCE = 8
PROMPT_FORCE_RANGE = 100000
AUTO_STEAL_TP_DEPTH_DEFAULT = 4
AUTO_STEAL_TP_DEPTH_MAX = 8
AUTO_STEAL_TP_DISTANCE_DEFAULT = 3.5
AUTO_STEAL_TP_DISTANCE_MAX = 4
AUTO_PLACE_TP_DISTANCE_DEFAULT = 12
AUTO_PLACE_TP_DISTANCE_MAX = 20
SELL_SAFE_DEPTH_DEFAULT = 4
SELL_SAFE_DEPTH_MAX = 6
GHOST_DEPTH_DEFAULT = 500
GHOST_DEPTH_MAX = 1500
SMART_AFK_PULSE_INTERVAL = 60
SMART_HOME_RETRY = 15
AUTO_STEAL_SHOTS = 3
AUTO_STEAL_SHOT_DELAY = 0.12
AUTO_STEAL_NO_TP_SHOTS = 5
AUTO_STEAL_NO_TP_SHOT_DELAY = 0.1
TRACKER_RADIUS_DEFAULT = 60
TRACKER_VERSION = 1
TRACKER_FILE = "MyshiStoneTracker.json"
CONFIG_FOLDER = "MyshiHub"
BOOTSTRAP_FILE = CONFIG_FOLDER .. "/startup.cfg"
SELL_POSITION_FILE = CONFIG_FOLDER .. "/sell.cfg"
ANTI_AFK_INTERVAL_DEFAULT = 30
AUTO_PLACE_DELAY_DEFAULT = 2
PLACE_FAIL_COOLDOWN = 6
GRINDER_RADIUS_DEFAULT = 150
GRINDER_DISPLAY_LIMIT = 8
GRINDER_DEDUPE_DISTANCE = 1.5
GRINDER_STONE_RADIUS = 5
GRINDER_STONE_HEIGHT = 4
HOME_RADIUS_DEFAULT = 40
HOME_DETECT_TIMEOUT = 10
HOME_TRAVEL_DISTANCE = 40
HOME_FILE = CONFIG_FOLDER .. "/home.cfg"
SELL_INTERVAL_DEFAULT = 3
SELL_STEP_DELAY = 0.1
SELL_MAX_ITEMS = 200
INSTANT_STEAL_STEP_DELAY = 0.1
INSTANT_STEAL_ATTEMPTS = 5
INSTANT_STEAL_MAX_FAILS = 40
INSTANT_STEAL_RETRY_COOLDOWN = 2.5
INSTANT_STEAL_TIMEOUT = 10

-- Urutan rarity tertinggi -> terendah (Galaxy selalu didahulukan)
local RARITY_ORDER = {
    "Galaxy",
    "Secret",
    "Mythic",
    "Legendary",
    "Epic",
    "Rare",
    "Uncommon",
    "Common",
}

local RARITY_SCORE = {}
for index, rarity in ipairs(RARITY_ORDER) do
    RARITY_SCORE[string.lower(rarity)] = #RARITY_ORDER - index + 1
end

local StealUtil = {}
MyshiUtil = MyshiUtil or {}

function MyshiUtil.GetGuiRoots()
    local roots = { CoreGui, LocalPlayer:FindFirstChild("PlayerGui") }
    if type(gethui) == "function" then
        local ok, hidden = pcall(gethui)
        if ok and hidden then
            table.insert(roots, hidden)
        end
    end
    return roots
end

-- Titik TP mengikuti arah pandang karakter, bukan arah mata angin. Jarak
-- mendatar dan kedalamannya bisa diatur dari UI.
local function GetFlatLookDirection(root, targetPosition)
    if not root then
        return Vector3.new(0, 0, -1)
    end

    local look = root.CFrame.LookVector
    local flat = Vector3.new(look.X, 0, look.Z)

    -- Kalau kamera menghadap lurus atas/bawah, pakai arah dari pemain ke batu.
    if flat.Magnitude < 0.05 and targetPosition then
        flat = Vector3.new(
            targetPosition.X - root.Position.X,
            0,
            targetPosition.Z - root.Position.Z
        )
    end

    if flat.Magnitude < 0.05 then
        return Vector3.new(0, 0, -1)
    end

    return flat / flat.Magnitude
end

-- Menahan karakter di tempat saat TP ke bawah tanah. PENTING: root TIDAK
-- di-anchor sebelum TP. Kalau di-anchor dulu, server bisa tetap melihat posisi
-- lama sehingga prompt Giling Batu menolak walau di layar sudah dekat. Jadi:
--   1. TP dulu saat root masih unanchored (CFrame-nya direplikasi ke server).
--   2. Beri satu frame, lalu anchor supaya tidak jatuh ke void.
--   3. Saat selesai: unanchor dulu, baru kembalikan ke posisi aman.
ghostActive = false

-- Sembunyikan avatar dari kamera sendiri selama berada di bawah tanah.
-- LocalTransparencyModifier hanya berlaku di client ini; pemain lain tetap
-- tidak melihat karakter karena posisinya sudah di bawah lantai.
local stealthLocalParts = {}

local function SetStealthLocalHidden(hidden)
    local character = LocalPlayer.Character
    if not character or not character.Parent then
        return
    end

    if hidden then
        for _, part in ipairs(character:GetDescendants()) do
            if part:IsA("BasePart") and not stealthLocalParts[part] then
                local ok, previous = pcall(function()
                    return part.LocalTransparencyModifier
                end)
                stealthLocalParts[part] = ok and previous or 0
                pcall(function()
                    part.LocalTransparencyModifier = 1
                end)
            end
        end
    else
        for part, previous in pairs(stealthLocalParts) do
            if part and part.Parent then
                pcall(function()
                    part.LocalTransparencyModifier = previous or 0
                end)
            end
        end
        stealthLocalParts = {}
    end
end

local StealthHold = {
    active = false,
    held = false,
    root = nil,
    character = nil,
    safeCFrame = nil,
    originalAnchored = false,
}

function StealthHold.Begin()
    if ghostActive then
        return false
    end

    SafeSellAnchor.Release(false)

    if StealthHold.active and StealthHold.root and StealthHold.root.Parent then
        return true
    end

    local character = LocalPlayer.Character
    local root = character and character:FindFirstChild("HumanoidRootPart")
    if not root or not root.Parent then
        return false
    end

    StealthHold.active = true
    StealthHold.held = false
    StealthHold.root = root
    StealthHold.character = character
    StealthHold.safeCFrame = root.CFrame
    StealthHold.originalAnchored = root.Anchored == true
    return true
end

-- Lepas anchor sebelum TP ke titik baru. Kalau tetap anchored, CFrame baru
-- hanya berubah di client dan server masih melihat posisi lama.
function StealthHold.Release()
    if not StealthHold.active or not StealthHold.held then
        return false
    end

    local root = StealthHold.root
    if root and root.Parent then
        pcall(function()
            root.Anchored = StealthHold.originalAnchored
        end)
    end

    StealthHold.held = false
    return true
end

-- Dipanggil setelah CFrame tujuan dipasang. CFrame dibiarkan replikasi dulu
-- selama satu tick, lalu di-anchor di posisi yang sama supaya tidak jatuh.
function StealthHold.Hold(cframe)
    if not StealthHold.active then
        return false
    end

    local root = StealthHold.root
    if not root or not root.Parent then
        return false
    end

    -- 0,1 detik cukup untuk beberapa paket replikasi CFrame sampai ke server
    -- sebelum karakter ditahan (di-anchor) di titik bawah tanah.
    task.wait(0.1)

    local ok = pcall(function()
        -- CFrame sudah dipasang oleh pemanggil saat root masih unanchored.
        -- Jangan memasangnya lagi tepat sebelum anchor: perubahan kedua itu
        -- sering tidak sempat direplikasi, sehingga server/pemain lain masih
        -- melihat karakter di posisi lama (di permukaan).
        root.AssemblyLinearVelocity = Vector3.zero
        root.AssemblyAngularVelocity = Vector3.zero
        root.Anchored = true
    end)

    if ok then
        StealthHold.held = true
        SetStealthLocalHidden(true)
    end

    return ok
end

function StealthHold.End(keepPosition)
    if ghostActive then
        return
    end

    if not StealthHold.active then
        return
    end

    local root = StealthHold.root
    local sameCharacter = LocalPlayer.Character == StealthHold.character
    local safeCFrame = StealthHold.safeCFrame
    local originalAnchored = StealthHold.originalAnchored

    if root and root.Parent then
        pcall(function()
            -- Unanchor dulu supaya CFrame aman ikut tereplikasi, bukan cuma
            -- berubah di client lalu karakter dianggap masih di bawah tanah.
            if StealthHold.held then
                root.Anchored = originalAnchored
            end
            -- keepPosition = true: jangan muncul ke permukaan. Dipakai saat
            -- transisi dari bawah penggiling ke titik Sell bawah tanah.
            if sameCharacter and safeCFrame and not keepPosition then
                root.CFrame = safeCFrame
            end
            root.AssemblyLinearVelocity = Vector3.zero
            root.AssemblyAngularVelocity = Vector3.zero
        end)
    end

    SetStealthLocalHidden(false)

    StealthHold.active = false
    StealthHold.held = false
    StealthHold.root = nil
    StealthHold.character = nil
    StealthHold.safeCFrame = nil
    StealthHold.originalAnchored = false
end

-- Anchor terpisah untuk Safe Position Sell. Titik sell disimpan di bawah
-- permukaan supaya karakter tidak perlu TP ke toko lagi setiap kali selesai
-- place. Release() wajib dipanggil sebelum TP/steal berikutnya.
SafeSellAnchor = {
    active = false,
    root = nil,
    character = nil,
    originalCFrame = nil,
    originalAnchored = false,
}

function SafeSellAnchor.Hold(cframe)
    if not cframe then
        return false
    end

    SafeSellAnchor.Release(false)

    local character = LocalPlayer.Character
    local root = character and character:FindFirstChild("HumanoidRootPart")
    if not root or not root.Parent then
        return false
    end

    SafeSellAnchor.root = root
    SafeSellAnchor.character = character
    SafeSellAnchor.originalCFrame = root.CFrame
    SafeSellAnchor.originalAnchored = root.Anchored == true
    SafeSellAnchor.active = true

    pcall(function()
        root.Anchored = false
        root.CFrame = cframe
        root.AssemblyLinearVelocity = Vector3.zero
        root.AssemblyAngularVelocity = Vector3.zero
    end)

    task.wait(0.12)

    if SafeSellAnchor.active and SafeSellAnchor.root == root and root.Parent then
        pcall(function()
            root.Anchored = true
        end)
        SetStealthLocalHidden(true)
    end

    return SafeSellAnchor.active
end

function SafeSellAnchor.Release(restore)
    if not SafeSellAnchor.active then
        return false
    end

    local root = SafeSellAnchor.root
    local character = SafeSellAnchor.character
    local originalCFrame = SafeSellAnchor.originalCFrame
    local originalAnchored = SafeSellAnchor.originalAnchored

    SafeSellAnchor.active = false
    SafeSellAnchor.root = nil
    SafeSellAnchor.character = nil
    SafeSellAnchor.originalCFrame = nil
    SafeSellAnchor.originalAnchored = false

    SetStealthLocalHidden(false)

    if root and root.Parent and character == LocalPlayer.Character then
        pcall(function()
            root.Anchored = originalAnchored
            if restore ~= false and originalCFrame then
                root.CFrame = originalCFrame
            end
            root.AssemblyLinearVelocity = Vector3.zero
            root.AssemblyAngularVelocity = Vector3.zero
        end)
    end

    return true
end

local rarityOptions = {}
local rarityOptionSet = {}
for _, rarity in ipairs(RARITY_ORDER) do
    table.insert(rarityOptions, rarity)
    rarityOptionSet[string.lower(rarity)] = true
end

local selectedRarities = { galaxy = true, secret = true }
local autoCooldown = {}
local instantAttempted = {}
-- Diisi ulang oleh UpdateRadar. Dipakai FindHeldStone supaya tidak memindai
-- seluruh Workspace berkali-kali di setiap tembakan prompt.
local cachedStoneParts = {}
local stoneCacheReady = false
local autoBusy = false
local instantBusy = false
local autoStealOn = false
local autoStealTeleport = true
forcePromptRange = true
promptOriginalRange = setmetatable({}, { __mode = "k" })
promptOriginalLineOfSight = setmetatable({}, { __mode = "k" })
local autoStealTpDepth = AUTO_STEAL_TP_DEPTH_DEFAULT
local autoStealTpDistance = AUTO_STEAL_TP_DISTANCE_DEFAULT
local instantStealOn = false
local smartAutoStealOn = false
local smartSafeMode = false
local smartHomeBusy = false
local smartHomeDone = false
local smartNextHomeAt = 0
local smartNextAntiAfkAt = 0
local smartStatusLabel
local smartLastStatus
local smartOtherCount = 0
local smartOtherName
local autoRefreshOn = true
local running = true
local Fluent
local UI
local Window
local StatusLabel
local instantStatusLabel
local RarityDropdown
local AutoStealToggle
local AutoStealTeleportToggle
ForcePromptRangeToggle = nil
AutoPlaceTpToggle = nil
GhostModeToggle = nil
local InstantStealToggle

-- Urutan fitur saat beberapa otomasi aktif. Hanya satu yang jalan per giliran.
local PRIORITY_OPTIONS = {
    "Steal > Place > Sell",
    "Steal > Sell > Place",
    "Place > Steal > Sell",
    "Place > Sell > Steal",
    "Sell > Steal > Place",
    "Sell > Place > Steal",
}

local PRIORITY_MAP = {
    ["Steal > Place > Sell"] = { "steal", "place", "sell" },
    ["Steal > Sell > Place"] = { "steal", "sell", "place" },
    ["Place > Steal > Sell"] = { "place", "steal", "sell" },
    ["Place > Sell > Steal"] = { "place", "sell", "steal" },
    ["Sell > Steal > Place"] = { "sell", "steal", "place" },
    ["Sell > Place > Steal"] = { "sell", "place", "steal" },
}

local featurePriority = PRIORITY_MAP["Steal > Place > Sell"]

local trackerOn = false
local trackerRadius = TRACKER_RADIUS_DEFAULT
local trackerRecords = {}
local trackedInstances = setmetatable({}, { __mode = "k" })
local trackerStatusLabel
local trackerLastLabel
local trackerExportLabel

local autoPlaceOn = false
local autoPlaceDelay = AUTO_PLACE_DELAY_DEFAULT
local autoPlaceTeleport = true
local autoPlaceTpDistance = AUTO_PLACE_TP_DISTANCE_DEFAULT
local autoPlaceCheckStone = true
local grinderRadius = GRINDER_RADIUS_DEFAULT
local placeBusy = false
local placePrepBusy = false
local placeCooldownUntil = 0
local placeFailedAt = {}
local grinderListParagraph
local placeSummaryLabel
local placeStatusLabel

-- Acuan "home": Auto Place memilih penggiling yang paling dekat titik ini.
local homeOnly = true
local homeRadius = HOME_RADIUS_DEFAULT
local homePosition = nil
local homeSource = nil
local homeBusy = false
local startupHomePending = true
local homeAttemptAt = 0
local homeTravelAt = 0
local homeLabel

sellTpOnPlace = true
sellPosition = nil
sellPositionSource = nil
sellUnderground = nil
sellUndergroundSource = nil
sellSafeDepth = SELL_SAFE_DEPTH_DEFAULT
sellLabel = nil
sellDetectCache = nil
sellDetectCacheAt = 0

local autoSellOn = false
local autoSellInterval = SELL_INTERVAL_DEFAULT
local sellBusy = false
local sellNextAt = 0
local sellWaiting = false
autoSellToggle = nil
sellFailStreak = 0
local sellStatusLabel
local sellItemsLabel
local priorityDropdown
local antiAfkOn = true
antiAfkInterval = ANTI_AFK_INTERVAL_DEFAULT
local antiAfkGeneration = 0
local antiAfkConnection
antiAfkPulses = 0
antiAfkIdledCount = 0
antiAfkStatusLabel = nil
antiAfkLastMethod = "-"
local disable3dRender = false
ghostModeOn = false
ghostDepth = GHOST_DEPTH_DEFAULT
ghostLockCamera = true
ghostRoot = nil
ghostCharacter = nil
ghostSafeCFrame = nil
ghostCameraCFrame = nil
ghostCameraType = nil
ghostOriginalAnchored = false
ghostPartRestore = {}
ghostStatusLabel = nil
ghostWanted = false
ghostHumanoid = nil
ghostHumanoidRestore = nil

local function RegisterRarity(rarity)
    local text = tostring(rarity)
    local key = string.lower(text)

    if text == "" or rarityOptionSet[key] then
        return
    end

    rarityOptionSet[key] = true
    table.insert(rarityOptions, text)

    if RarityDropdown then
        RarityDropdown:Refresh(rarityOptions, true)
    end
end

local function IsRaritySelected(rarity)
    return selectedRarities[string.lower(tostring(rarity))] == true
end

local function RarityRank(rarity)
    return RARITY_SCORE[string.lower(tostring(rarity))] or 0
end


-- =====================================================================
-- 0. FILE API
-- =====================================================================
local function HasFileAPI()
    return type(isfile) == "function"
        and type(readfile) == "function"
        and type(writefile) == "function"
end

-- Kalau eksekusi sebelumnya sempat mematikan 3D render, kembalikan dulu.
-- Config Auto Load akan menerapkan ulang kalau settingnya memang disimpan.
pcall(function()
    RunService:Set3dRenderingEnabled(true)
end)

pcall(function()
    if type(makefolder) == "function"
        and type(isfolder) == "function"
        and not isfolder(CONFIG_FOLDER)
    then
        makefolder(CONFIG_FOLDER)
    end
end)


-- =====================================================================
-- 1. CLEANUP UI LAMA
-- =====================================================================
if _G.DoubleStealActive then
    _G.DoubleStealActive = false
    task.wait(1.05)
end

if _G.DoubleStealWindow then
    pcall(function()
        _G.DoubleStealWindow:Destroy()
    end)
    _G.DoubleStealWindow = nil
end

do
    local roots = MyshiUtil.GetGuiRoots()
    for _, guiName in ipairs({ UI_NAME, "MyshiHub", "MyshiHubScroll", "MyshiHubPopup", "MyshiDoubleStealUI" }) do
        for _, root in ipairs(roots) do
            local oldGui = root and root:FindFirstChild(guiName)
            if oldGui then
                oldGui:Destroy()
            end
        end
    end
end

-- Muat library Fluent-Pro
local loaded, loadedFluent = pcall(function()
    return loadstring(game:HttpGet(FLUENT_URL))()
end)

if not loaded or type(loadedFluent) ~= "table" then
    error("[Myshi Hub] Gagal memuat Fluent-Pro: " .. tostring(loadedFluent))
end

Fluent = loadedFluent


-- =====================================================================
-- 2. LOGIKA UTAMA (DOUBLE-TRY STEAL)
-- =====================================================================
local function TeleportToHome()
    local playerGui = LocalPlayer:FindFirstChild("PlayerGui")
    if not playerGui then
        return false
    end

    for _, obj in ipairs(playerGui:GetDescendants()) do
        if (obj:IsA("TextButton") or obj:IsA("ImageButton"))
            and obj.Visible ~= false
        then
            local name = string.lower(obj.Name)
            local text = obj:IsA("TextButton") and string.lower(obj.Text) or ""
            local parentName = string.lower(obj.Parent and obj.Parent.Name or "")

            if string.find(name, "home")
                or string.find(text, "home")
                or string.find(parentName, "home")
                or string.find(name, "house")
                or string.find(name, "rumah")
                or string.find(text, "rumah")
            then
                local fired = false
                if type(getconnections) == "function" then
                    pcall(function()
                        for _, connection in ipairs(getconnections(obj.Activated)) do
                            if connection and type(connection.Fire) == "function" then
                                pcall(function() connection:Fire() end)
                                fired = true
                            end
                        end
                        for _, connection in ipairs(getconnections(obj.MouseButton1Click)) do
                            if connection and type(connection.Fire) == "function" then
                                pcall(function() connection:Fire() end)
                                fired = true
                            end
                        end
                    end)
                end
                if fired then
                    return true
                end
            end
        end
    end

    return false
end

local function IsTargetValid(stone, prompt)
    return stone ~= nil
        and stone.Parent ~= nil
        and prompt ~= nil
        and prompt.Parent ~= nil
        and prompt.Enabled ~= false
end

-- Opsi paksa jarak: beberapa game hanya memeriksa MaxActivationDistance di
-- client, jadi menaikkan properti prompt membuat fireproximityprompt tetap
-- diterima dari jauh. Kalau server memvalidasi jarak sendiri, opsi ini aman
-- dimatikan dan Auto TP tetap dipakai.
function ApplyPromptRange(prompt)
    -- Prompt selalu dipaksa jarak jauh. Game ini tidak memvalidasi jarak di
    -- server, jadi tombol/toggle tidak boleh bisa mematikan kemampuan ini.
    if not prompt or not prompt.Parent then
        return
    end

    if promptOriginalRange[prompt] == nil then
        promptOriginalRange[prompt] = tonumber(prompt.MaxActivationDistance) or PROMPT_MAX_DISTANCE
        promptOriginalLineOfSight[prompt] = prompt.RequiresLineOfSight == true
    end

    pcall(function()
        prompt.MaxActivationDistance = math.max(
            promptOriginalRange[prompt] or PROMPT_MAX_DISTANCE,
            PROMPT_FORCE_RANGE
        )
        -- Prompt batu di game ini tidak punya validasi jarak ketat. Tetap
        -- paksa line-of-sight mati supaya prompt dari home/base bisa dipakai.
        prompt.RequiresLineOfSight = false
    end)
end

function RestorePromptRanges()
    for prompt, original in pairs(promptOriginalRange) do
        if prompt and prompt.Parent then
            local lineOfSight = promptOriginalLineOfSight[prompt]
            pcall(function()
                prompt.MaxActivationDistance = original
                if lineOfSight ~= nil then
                    prompt.RequiresLineOfSight = lineOfSight
                end
            end)
        end
    end
    promptOriginalRange = setmetatable({}, { __mode = "k" })
    promptOriginalLineOfSight = setmetatable({}, { __mode = "k" })
end

StealUtil.ApplyPromptRange = ApplyPromptRange

-- Cari permukaan tanah di bawah sebuah titik. Dipakai supaya karakter
-- benar-benar terkubur di bawah map, bukan hanya di bawah batu yang mungkin
-- melayang di udara. Filter karakter dan objek acuan supaya ray tidak
-- mengenai badan sendiri atau batu yang sedang di-steal.
function MyshiUtil.GetGroundY(position, ignore)
    if not position then
        return nil
    end

    local ok, result = pcall(function()
        local params = RaycastParams.new()
        params.FilterType = Enum.RaycastFilterType.Exclude

        local filter = {}
        local character = LocalPlayer.Character
        if character then
            table.insert(filter, character)
        end
        if ignore and ignore.Parent then
            table.insert(filter, ignore)
        end
        params.FilterDescendantsInstances = filter

        local origin = Vector3.new(position.X, position.Y + 8, position.Z)
        return Workspace:Raycast(origin, Vector3.new(0, -800, 0), params)
    end)

    if ok and result and result.Position then
        return result.Position.Y
    end
    return nil
end

StealUtil.GetGroundY = MyshiUtil.GetGroundY

function StealUtil.PromptWorldPosition(stone, prompt)
    local parent = prompt and prompt.Parent
    if parent and parent:IsA("Attachment") then
        local ok, position = pcall(function()
            return parent.WorldPosition
        end)
        if ok and position then
            return position
        end
    end
    if parent and parent:IsA("BasePart") then
        return parent.Position
    end
    return stone and (stone.Position + Vector3.new(0, 3, 0)) or nil
end

local function FirePromptOnce(prompt)
    if not prompt or not prompt.Parent then
        return false
    end

    ApplyPromptRange(prompt)

    -- Jalur utama semua executor. Kalau fungsi global tidak ada, pakai API
    -- ProximityPrompt lokal sebagai cadangan.
    if type(fireproximityprompt) == "function" then
        local ok = pcall(function()
            fireproximityprompt(prompt)
        end)
        if ok then
            return true
        end
    end

    local held = pcall(function()
        prompt:InputHoldBegin()
    end)
    if held then
        task.wait(0.03)
        pcall(function()
            prompt:InputHoldEnd()
        end)
        return true
    end

    return false
end

function StealUtil.SpamPrompt(prompt, shots, delay)
    local fired = 0
    for _ = 1, math.max(1, shots or 1) do
        if not prompt or not prompt.Parent then
            break
        end
        if FirePromptOnce(prompt) then
            fired = fired + 1
        end
        task.wait(delay or AUTO_STEAL_SHOT_DELAY)
    end
    return fired
end

-- Pindah ke bawah batu mengikuti arah pandang. Beberapa langkah kecil ke
-- depan dipakai bergantian supaya prompt tetap mendaftar walau posisi hasil
-- replication bergeser sedikit.
function StealUtil.TeleportNearStone(stone, prompt, cycle)
    -- Ghost mode tidak memindahkan karakter sama sekali. Prompt ditembak dari
    -- posisi terkubur, jadi pemain lain tidak melihat karakter berpindah.
    if ghostActive then
        return true
    end

    local character = LocalPlayer.Character
    local root = character and character:FindFirstChild("HumanoidRootPart")
    local promptPosition = StealUtil.PromptWorldPosition(stone, prompt)
    if not root or not root.Parent or not promptPosition then
        return false
    end

    -- Jangan restore ke permukaan: itu membuat karakter sempat terlihat.
    SafeSellAnchor.Release(false)

    -- Putaran berikutnya harus mulai dari root yang unanchored supaya CFrame
    -- baru ikut tereplikasi ke server, bukan cuma berubah di layar.
    if StealthHold and StealthHold.active and StealthHold.held then
        StealthHold.Release()
        task.wait(0.04)
    end

    local direction = GetFlatLookDirection(root, promptPosition)

    -- Game ini tetap punya batas prompt 8 stud di sisi server walau properti
    -- MaxActivationDistance dinaikkan. Karena itu posisi TP harus benar-benar
    -- berada di dalam radius 8 stud dari prompt, bukan hanya "di bawah batu".
    -- Kalau terlalu dalam, fireproximityprompt diterima client tapi ditolak
    -- server, persis gejala "harus dekat berkali-kali baru berhasil".
    local maxDistance = math.max(6.5, PROMPT_MAX_DISTANCE - 0.2)
    local burial = math.clamp(
        tonumber(autoStealTpDepth) or AUTO_STEAL_TP_DEPTH_DEFAULT,
        3,
        6
    )

    local stonePosition = stone and stone.Position or promptPosition
    local floorY = MyshiUtil.GetGroundY(stonePosition, stone)

    -- Utamakan 3-6 stud di bawah lantai, tetapi jangan sampai jarak total ke
    -- prompt melewati 8 stud. Kalau lantai tinggi, karakter tetap sedalam
    -- mungkin yang masih bisa dijangkau prompt.
    local destinationY = promptPosition.Y - maxDistance
    if floorY and floorY < promptPosition.Y then
        destinationY = math.max(destinationY, floorY - burial)
    end
    -- Jangan pernah berakhir di atas prompt. Kalau raycast mengenai atap
    -- atau objek di atas batu, floorY bisa lebih tinggi dari prompt.
    destinationY = math.min(destinationY, promptPosition.Y - 1.5)

    local verticalToPrompt = math.abs(promptPosition.Y - destinationY)
    local maxHorizontal = math.sqrt(math.max(
        0,
        maxDistance * maxDistance - verticalToPrompt * verticalToPrompt
    ))
    maxHorizontal = math.min(maxHorizontal, AUTO_STEAL_TP_DISTANCE_MAX)

    local baseDistance = math.clamp(
        tonumber(autoStealTpDistance) or AUTO_STEAL_TP_DISTANCE_DEFAULT,
        0,
        maxHorizontal
    )
    local step = math.min(
        baseDistance + (cycle - 1) * 0.25,
        maxHorizontal
    )

    local destination = Vector3.new(
        promptPosition.X + direction.X * step,
        destinationY,
        promptPosition.Z + direction.Z * step
    )

    -- Kalau titik horizontal mendarat di tanah yang lebih tinggi (lereng),
    -- turunkan lagi tanpa melewati batas jarak prompt.
    local destinationFloor = MyshiUtil.GetGroundY(destination, stone)
    if destinationFloor and destinationFloor < destination.Y then
        local hiddenY = destinationFloor - burial
        local minY = promptPosition.Y - maxDistance
        destination = Vector3.new(
            destination.X,
            math.max(hiddenY, minY),
            destination.Z
        )
    end

    -- Pertahankan arah pandang; CFrame.new saja akan mereset rotasi ke -Z.
    local original = root.CFrame
    local rotation = original - original.Position
    local destinationCFrame = CFrame.new(destination) * rotation

    -- TP saat root masih unanchored supaya server ikut melihat posisi baru.
    local ok = pcall(function()
        root.CFrame = destinationCFrame
        root.AssemblyLinearVelocity = Vector3.zero
        root.AssemblyAngularVelocity = Vector3.zero
    end)

    -- Baru setelah satu tick, tahan di posisi itu supaya tidak jatuh ke void.
    if ok and StealthHold and StealthHold.active then
        StealthHold.Hold(destinationCFrame)
    end

    return ok
end

local function ExecuteDoubleTrySteal(stone, prompt, teleport)
    if not IsTargetValid(stone, prompt) then
        return false
    end
    if teleport and not (LocalPlayer.Character
        and LocalPlayer.Character:FindFirstChild("HumanoidRootPart")) then
        return false
    end

    for cycle = 1, 4 do
        if not IsTargetValid(stone, prompt) then
            return true
        end
        if teleport then
            if not StealUtil.TeleportNearStone(stone, prompt, cycle) then
                return false
            end
            task.wait(AUTO_STEAL_TP_SETTLE)
        end

        StealUtil.SpamPrompt(prompt, teleport and AUTO_STEAL_SHOTS or AUTO_STEAL_NO_TP_SHOTS,
            teleport and AUTO_STEAL_SHOT_DELAY or AUTO_STEAL_NO_TP_SHOT_DELAY)
        if not IsTargetValid(stone, prompt) then
            return true
        end
    end
    return false
end

-- Dipakai tombol steal manual di radar supaya TP bawah tanah juga tidak
-- menjatuhkan karakter ke void.
local function ExecuteSafeDoubleTrySteal(stone, prompt, teleport)
    if not teleport then
        return ExecuteDoubleTrySteal(stone, prompt, false)
    end
    if not StealthHold.Begin() then
        return false
    end

    local ok, result = pcall(ExecuteDoubleTrySteal, stone, prompt, true)
    StealthHold.End()

    if not ok then
        return false
    end
    return result
end

-- Diisi di section Auto Place; dipakai Auto Steal untuk cek batu di tangan.
local FindHeldStone

-- Spam prompt sampai batu hilang / prompt hilang, bukan hanya 2 tembakan.
local function RunAutoStealCore(target)
    if type(fireproximityprompt) ~= "function" then
        if StatusLabel then
            StatusLabel:Set("Status: Auto Steal tidak tersedia (fireproximityprompt).")
        end
        return false
    end

    local stone = target.stone
    local prompt = target.prompt
    local rarity = target.rarity
    local deadline = os.time() + AUTO_STEAL_TIMEOUT
    local success = false
    local attempts = 0
    local cycle = 0
    local skippedHolding = false

    while running and autoStealOn and not smartSafeMode
        and IsRaritySelected(rarity) and os.time() < deadline
    do
        -- Jangan steal kalau sedang memegang batu; Auto Place yang jalan.
        if FindHeldStone and FindHeldStone() then
            skippedHolding = true
            break
        end

        if not IsTargetValid(stone, prompt) then
            success = attempts > 0
            break
        end

        cycle = cycle + 1
        local teleport = autoStealTeleport ~= false and not ghostActive
        if teleport then
            if not StealUtil.TeleportNearStone(stone, prompt, cycle) then
                break
            end
            task.wait(AUTO_STEAL_TP_SETTLE)
        else
            task.wait(0.03)
        end

        if not IsTargetValid(stone, prompt) then
            success = true
            break
        end

        local shots = teleport and AUTO_STEAL_SHOTS or AUTO_STEAL_NO_TP_SHOTS
        local delay = teleport and AUTO_STEAL_SHOT_DELAY or AUTO_STEAL_NO_TP_SHOT_DELAY
        for _ = 1, shots do
            if smartSafeMode then
                break
            end
            if not IsTargetValid(stone, prompt) then
                success = true
                break
            end

            attempts = attempts + StealUtil.SpamPrompt(prompt, 1, delay)

            if not IsTargetValid(stone, prompt) then
                success = true
                break
            end
            if FindHeldStone and FindHeldStone() then
                success = true
                break
            end
        end

        if success then
            break
        end
        task.wait(AUTO_STEAL_RETRY_DELAY)
    end

    if not IsTargetValid(stone, prompt) then
        success = success or attempts > 0
    end

    local stillValid = IsTargetValid(stone, prompt)
    local timedOut = os.time() >= deadline

    if skippedHolding then
        if StatusLabel and not smartSafeMode then
            StatusLabel:Set("Status: Auto Steal skip - sedang memegang batu.")
        end
        return false
    end

    -- Jangan kunci target selamanya. Beri jeda pendek lalu target boleh dicoba
    -- lagi; kalau prompt masih ditolak server, scheduler akan spam lagi.
    if not success and stillValid then
        autoCooldown[stone] = os.time() + AUTO_STEAL_TARGET_COOLDOWN
    end

    if StatusLabel and not smartSafeMode then
        if success then
            StatusLabel:Set(string.format(
                "Status: Auto Steal berhasil [%s] (%d tembakan).",
                tostring(rarity),
                attempts
            ))
        elseif timedOut and stillValid then
            StatusLabel:Set(string.format(
                "Status: Auto Steal gagal [%s] (%d tembakan), dicoba lagi.",
                tostring(rarity),
                attempts
            ))
        end
    end

    return success
end

-- Wrapper: tahan karakter selama TP bawah tanah. Kalau steal berhasil dan
-- batu masih dipegang, jangan langsung muncul ke permukaan: Auto Place akan
-- memakai posisi bawah tanah yang sama sampai batu selesai diletakkan.
local function RunAutoSteal(target)
    local useHold = autoStealTeleport ~= false and not ghostActive
    if useHold and not StealthHold.Begin() then
        if StatusLabel and not smartSafeMode then
            StatusLabel:Set("Status: Auto TP ditahan - anti-void tidak bisa aktif.")
        end
        return
    end

    local ok, result = pcall(RunAutoStealCore, target)
    local keepUnderground = false

    if ok and result then
        task.wait(0.12)
        local held = FindHeldStone and FindHeldStone() or nil
        -- Beri waktu singkat untuk Tool/stone masuk ke Backpack sebelum
        -- memutuskan muncul ke permukaan. Kalau langsung End, karakter sempat
        -- terlihat walaupun steal berhasil.
        if not held then
            for _ = 1, 4 do
                task.wait(0.2)
                held = FindHeldStone and FindHeldStone() or nil
                if held then
                    break
                end
            end
        end
        keepUnderground = held ~= nil
    end

    if useHold and not keepUnderground then
        StealthHold.End()
    elseif keepUnderground and StatusLabel and not smartSafeMode then
        StatusLabel:Set("Status: batu didapat - karakter tetap di bawah tanah, menunggu Auto Place.")
    end

    if not ok then
        error(result, 0)
    end
end


-- =====================================================================
-- 2b. TRACKER PENEMPATAN BATU
-- =====================================================================
local function UpdateTrackerLabels()
    if trackerStatusLabel then
        trackerStatusLabel:Set(string.format(
            "Tracker: %s | Terekam: %d posisi",
            trackerOn and "merekam" or "nonaktif",
            #trackerRecords
        ))
    end
end

local function SnapshotExistingStones()
    for _, obj in ipairs(Workspace:GetDescendants()) do
        if obj.Name == "batu" and obj:IsA("BasePart") then
            trackedInstances[obj] = true
        end
    end
end

local function TrackPlacedStone(stone)
    if not trackerOn or trackedInstances[stone] then
        return
    end
    trackedInstances[stone] = true

    local character = LocalPlayer.Character
    local root = character and character:FindFirstChild("HumanoidRootPart")
    if not root or not root.Parent then
        return
    end

    local position = stone.Position
    local playerPosition = root.Position
    if (position - playerPosition).Magnitude > trackerRadius then
        return
    end

    local record = {
        index = #trackerRecords + 1,
        time = os.time(),
        recordedAt = os.date("%Y-%m-%d %H:%M:%S"),
        name = stone.Name,
        rarity = tostring(stone:GetAttribute("Rarity") or "Unknown"),
        anchored = stone.Anchored == true,
        hasPrompt = stone:FindFirstChild("CustomPromptAttachment") ~= nil,
        position = {
            x = position.X,
            y = position.Y,
            z = position.Z,
        },
        playerPosition = {
            x = playerPosition.X,
            y = playerPosition.Y,
            z = playerPosition.Z,
        },
    }

    local sizeOk, size = pcall(function()
        return stone.Size
    end)
    if sizeOk and size then
        record.size = { x = size.X, y = size.Y, z = size.Z }
    end

    local cframeOk, components = pcall(function()
        return { stone.CFrame:GetComponents() }
    end)
    if cframeOk then
        record.cframe = components
    end

    local playerCframeOk, playerComponents = pcall(function()
        return { root.CFrame:GetComponents() }
    end)
    if playerCframeOk then
        record.playerCFrame = playerComponents
    end

    table.insert(trackerRecords, record)
    UpdateTrackerLabels()

    if trackerLastLabel then
        trackerLastLabel:Set(string.format(
            "Terakhir: [%s] X %.1f, Y %.1f, Z %.1f",
            record.rarity,
            position.X,
            position.Y,
            position.Z
        ))
    end
end

local function BuildTrackerExport()
    local payload = {
        version = TRACKER_VERSION,
        placeId = game.PlaceId,
        gameName = game.Name,
        exportedAt = os.time(),
        exportedAtText = os.date("%Y-%m-%d %H:%M:%S"),
        count = #trackerRecords,
        records = trackerRecords,
    }

    local ok, json = pcall(function()
        return game:GetService("HttpService"):JSONEncode(payload)
    end)

    if not ok then
        return nil, tostring(json)
    end
    return json
end

local function CopyTrackerExport()
    if #trackerRecords == 0 then
        if trackerStatusLabel then
            trackerStatusLabel:Set("Tracker: belum ada data untuk di-export.")
        end
        return
    end

    local json, encodeError = BuildTrackerExport()
    if not json then
        if trackerStatusLabel then
            trackerStatusLabel:Set("Tracker: gagal membuat JSON: " .. tostring(encodeError))
        end
        return
    end

    local methods = {}

    if type(setclipboard) == "function" then
        local ok = pcall(setclipboard, json)
        if ok then
            table.insert(methods, "clipboard")
        end
    end

    if type(writefile) == "function" then
        local ok = pcall(writefile, TRACKER_FILE, json)
        if ok then
            table.insert(methods, "file " .. TRACKER_FILE)
        end
    end

    if #methods == 0 then
        print("[Myshi Hub] Tracker export (" .. #trackerRecords .. " posisi):")
        print(json)
    end

    local methodText = #methods > 0 and table.concat(methods, " + ") or "console"
    local recordCount = #trackerRecords

    if trackerStatusLabel then
        trackerStatusLabel:Set(string.format("Tracker: %d posisi siap (%s).", recordCount, methodText))
    end
    if trackerExportLabel then
        trackerExportLabel:Set(string.format("Export terakhir: %d record | %s", recordCount, methodText))
    end

    pcall(function()
        UI:Notify({
            Title = "Tracker Export",
            Content = string.format("%d posisi -> %s", recordCount, methodText),
            Icon = "clipboard-check",
            Type = "Success",
            Duration = 4,
        })
    end)
end

local function ClearTrackerData()
    trackerRecords = {}
    trackedInstances = setmetatable({}, { __mode = "k" })

    if trackerOn then
        SnapshotExistingStones()
    end

    UpdateTrackerLabels()

    if trackerLastLabel then
        trackerLastLabel:Set("Terakhir: -")
    end
    if trackerExportLabel then
        trackerExportLabel:Set("Belum ada export.")
    end
end


-- =====================================================================
-- 2c. AUTO PLACE (PENGGILING DINAMIS)
-- =====================================================================
local GRINDER_NAME_KEYWORD = "penggiling"

local function IsStoneName(name)
    local value = string.lower(tostring(name or ""))
    return string.find(value, "batu", 1, true) ~= nil
        or string.find(value, "stone", 1, true) ~= nil
end

local function GetCharacterRoot()
    local character = LocalPlayer.Character
    return character and character:FindFirstChild("HumanoidRootPart")
end

-- =====================================================================
-- 2c-1. ACUAN HOME
-- Home dipakai sebagai titik ukur: Auto Place hanya mau menyentuh
-- penggiling yang paling dekat dengan home, bukan base pemain lain.
-- =====================================================================
local function GetObjectAnchorPosition(obj)
    if obj:IsA("BasePart") then
        return obj.Position
    end

    local ok, pivot = pcall(function()
        return obj:GetPivot()
    end)
    if ok and pivot then
        return pivot.Position
    end

    return nil
end

local function IsOwnedByLocalPlayer(obj)
    local ok, attributes = pcall(function()
        return obj:GetAttributes()
    end)
    if not ok or type(attributes) ~= "table" then
        return false, false
    end

    local playerName = string.lower(tostring(LocalPlayer.Name or ""))
    local userId = tonumber(LocalPlayer.UserId)
    local hasOwner = false

    for attributeName, value in pairs(attributes) do
        local key = string.lower(tostring(attributeName))
        if key == "owner" or key == "ownername" or key == "player"
            or key == "playername" or key == "username"
        then
            hasOwner = true
            if string.lower(tostring(value)) == playerName then
                return true, false
            end
        elseif key == "ownerid" or key == "userid" or key == "playerid" then
            hasOwner = true
            if tonumber(value) == userId then
                return true, false
            end
        end
    end

    return false, hasOwner
end

-- Cari marker home di Workspace, misal Model bernama Home / Rumah atau
-- plot yang atributnya menunjuk ke pemain lokal.
-- ownedOnly = true hanya percaya plot yang atributnya milik pemain lokal.
local function FindHomeMarker(ownedOnly)
    local best = nil
    local bestScore = 0

    for _, obj in ipairs(Workspace:GetDescendants()) do
        if obj:IsA("Model") or obj:IsA("BasePart") then
            local name = string.lower(tostring(obj.Name or ""))
            local isHomeName = string.find(name, "home", 1, true) ~= nil
                or string.find(name, "rumah", 1, true) ~= nil

            local owned = false
            local foreignOwner = false
            if obj:IsA("Model") then
                owned, foreignOwner = IsOwnedByLocalPlayer(obj)
            end

            if not foreignOwner
                and (owned or (not ownedOnly and isHomeName))
                and not string.find(name, "baseplate", 1, true)
            then
                local position = GetObjectAnchorPosition(obj)
                if position then
                    local score = (owned and 10 or 0) + (isHomeName and 2 or 0)
                    if score > bestScore then
                        bestScore = score
                        best = {
                            position = position,
                            source = owned and "plot pemain" or ("marker " .. tostring(obj.Name)),
                        }
                    end
                end
            end
        end
    end

    return best
end

local function LoadHomeFile()
    if not HasFileAPI() or not isfile(HOME_FILE) then
        return
    end

    local ok, data = pcall(function()
        return HttpService:JSONDecode(readfile(HOME_FILE))
    end)
    if not ok or type(data) ~= "table" then
        return
    end

    if data.placeId ~= nil and tonumber(data.placeId) ~= tonumber(game.PlaceId) then
        return
    end

    local position = data.position
    if type(position) == "table"
        and tonumber(position.x)
        and tonumber(position.y)
        and tonumber(position.z)
    then
        homePosition = Vector3.new(
            tonumber(position.x),
            tonumber(position.y),
            tonumber(position.z)
        )
        homeSource = type(data.source) == "string" and data.source or "tersimpan"
    end
end

local function SaveHomeFile()
    if not HasFileAPI() or not homePosition then
        return
    end

    pcall(function()
        if type(isfolder) == "function"
            and type(makefolder) == "function"
            and not isfolder(CONFIG_FOLDER)
        then
            makefolder(CONFIG_FOLDER)
        end
        writefile(HOME_FILE, HttpService:JSONEncode({
            placeId = tonumber(game.PlaceId) or 0,
            source = homeSource,
            position = {
                x = homePosition.X,
                y = homePosition.Y,
                z = homePosition.Z,
            },
        }))
    end)
end

local function UpdateHomeLabel()
    if not homeLabel then
        return
    end

    if homePosition then
        homeLabel:Set(string.format(
            "Home: X %.1f, Y %.1f, Z %.1f (%s) | Radius %d",
            homePosition.X,
            homePosition.Y,
            homePosition.Z,
            tostring(homeSource or "manual"),
            math.floor(homeRadius + 0.5)
        ))
    else
        homeLabel:Set("Home: belum ditandai. Klik 'Tandai Home' atau 'Set ke Posisi Ini'.")
    end
end

local function SetHomeFromPosition(source)
    local root = GetCharacterRoot()
    if not root then
        return false, "karakter belum siap"
    end

    homePosition = root.Position
    homeSource = source or "posisi"
    placeFailedAt = {}
    placeCooldownUntil = 0
    SaveHomeFile()
    UpdateHomeLabel()
    return true
end

local function WaitForHomeTeleport(before, timeout)
    local deadline = os.time() + (timeout or HOME_DETECT_TIMEOUT)

    while running and os.time() < deadline do
        task.wait(0.25)
        local current = GetCharacterRoot()
        if current then
            if before == nil or (current.Position - before).Magnitude >= 4 then
                return true, current.Position
            end
        end
    end

    return false, nil
end

-- Tandai home dengan menekan tombol Home di game, lalu simpan posisi mendarat.
local function MarkHomeByTeleport()
    if homeBusy then
        return false, "sedang menandai home"
    end

    homeBusy = true

    pcall(StealthHold.End)
    SafeSellAnchor.Release()

    local root = GetCharacterRoot()
    local before = root and root.Position
    local clicked = TeleportToHome()
    if not clicked then
        homeBusy = false
        return false, "tombol Home di game tidak ditemukan"
    end

    local moved = WaitForHomeTeleport(before, HOME_DETECT_TIMEOUT)
    task.wait(0.3)

    -- Jangan simpan posisi spawn acak sebagai home kalau tombol Home ternyata
    -- tidak menggerakkan karakter. Home lama tetap dipakai sebagai acuan.
    if not moved and homePosition and before
        and (before - homePosition).Magnitude > 10
    then
        homeBusy = false
        return false, "tombol Home tidak menggerakkan karakter"
    end

    homeBusy = false
    return SetHomeFromPosition("teleport home")
end

-- Pastikan home sudah ada sebelum Auto Place memilih penggiling.
-- Urutan: home tersimpan -> tombol Home di game -> marker Workspace.
local function EnsureHomeReady()
    if not homeOnly then
        return true
    end
    if homePosition then
        return true
    end
    if homeBusy then
        return false, "sedang menandai home"
    end
    if os.time() < homeAttemptAt then
        return false, "home belum ditandai"
    end

    homeAttemptAt = os.time() + 8

    -- Tombol Home di game adalah acuan paling akurat.
    local marked, markError = MarkHomeByTeleport()
    if marked then
        return true
    end

    -- Cadangan: marker Home / Rumah di Workspace.
    local marker = FindHomeMarker(false)
    if marker then
        homePosition = marker.position
        homeSource = marker.source
        placeFailedAt = {}
        placeCooldownUntil = 0
        SaveHomeFile()
        UpdateHomeLabel()
        return true
    end

    return false, markError
end

-- TP pulang tanpa mengubah titik home yang sudah ditandai.
local function TravelHome()
    local root = GetCharacterRoot()
    if not root then
        return false, "karakter belum siap"
    end

    pcall(StealthHold.End)
    SafeSellAnchor.Release()

    if not TeleportToHome() then
        return false, "tombol Home di game tidak ditemukan"
    end

    WaitForHomeTeleport(root.Position, HOME_DETECT_TIMEOUT)
    task.wait(0.5)
    return true
end

LoadHomeFile()

do
    if not homePosition then
        local marker = FindHomeMarker(true)
        if marker then
            homePosition = marker.position
            homeSource = marker.source
            SaveHomeFile()
        end
    end
end

-- =====================================================================
-- 2c-2. SAFE POSITION: TITIK SELL SETELAH PLACE
-- =====================================================================
function UpdateSellPositionLabel()
    if not sellLabel then
        return
    end

    if sellPosition or sellUnderground then
        local surface = sellPosition
        local safe = sellUnderground
        local parts = {}

        if surface then
            table.insert(parts, string.format(
                "Sell X %.1f, Y %.1f, Z %.1f (%s)",
                surface.X,
                surface.Y,
                surface.Z,
                tostring(sellPositionSource or "manual")
            ))
        end
        if safe then
            table.insert(parts, string.format(
                "Safe bawah tanah X %.1f, Y %.1f, Z %.1f",
                safe.X,
                safe.Y,
                safe.Z
            ))
        else
            table.insert(parts, "Safe bawah tanah: belum disimpan")
        end

        sellLabel:Set("Sell: " .. table.concat(parts, " | "))
    elseif sellDetectCache then
        sellLabel:Set("Sell: terdeteksi otomatis di " .. tostring(sellDetectCache.label or "-") .. ".")
    else
        sellLabel:Set("Sell: belum ditandai. Klik 'Set Posisi Sell' atau 'Deteksi Sell'.")
    end
end

function SaveSellFile()
    if not HasFileAPI() or (not sellPosition and not sellUnderground) then
        return
    end

    pcall(function()
        local data = {
            placeId = tonumber(game.PlaceId) or 0,
            source = sellPositionSource or "manual",
            safeDepth = tonumber(sellSafeDepth) or SELL_SAFE_DEPTH_DEFAULT,
        }
        if sellPosition then
            data.position = {
                x = sellPosition.X,
                y = sellPosition.Y,
                z = sellPosition.Z,
            }
        end
        if sellUnderground then
            data.safePosition = {
                x = sellUnderground.X,
                y = sellUnderground.Y,
                z = sellUnderground.Z,
            }
        end
        writefile(SELL_POSITION_FILE, HttpService:JSONEncode(data))
    end)
end

function LoadSellFile()
    if not HasFileAPI() or not isfile(SELL_POSITION_FILE) then
        return
    end

    local ok, data = pcall(function()
        return HttpService:JSONDecode(readfile(SELL_POSITION_FILE))
    end)
    if not ok or type(data) ~= "table" then
        return
    end
    if data.placeId ~= nil and tonumber(data.placeId) ~= tonumber(game.PlaceId) then
        return
    end

    local position = data.position
    if type(position) == "table" then
        local x = tonumber(position.x)
        local y = tonumber(position.y)
        local z = tonumber(position.z)
        if x and y and z then
            sellPosition = Vector3.new(x, y, z)
            sellPositionSource = tostring(data.source or "file")
        end
    end

    if tonumber(data.safeDepth) then
        -- Titik Sell juga harus berada di dalam radius prompt 8 stud. File
        -- lama yang menyimpan kedalaman 14-40 otomatis dipendekkan.
        sellSafeDepth = math.clamp(
            tonumber(data.safeDepth) or SELL_SAFE_DEPTH_DEFAULT,
            3,
            SELL_SAFE_DEPTH_MAX
        )
    end

    local safe = data.safePosition
    if type(safe) == "table" then
        local x = tonumber(safe.x)
        local y = tonumber(safe.y)
        local z = tonumber(safe.z)
        if x and y and z then
            sellUnderground = Vector3.new(x, y, z)
            sellUndergroundSource = "file"
        end
    end

    -- Migrasi file lama yang titik amannya terlalu dekat ke permukaan, supaya
    -- karakter tidak lagi kelihatan saat TP ke Sell.
    if sellUnderground and sellPosition
        and ((sellPosition.Y - sellUnderground.Y)
            < (tonumber(sellSafeDepth) or SELL_SAFE_DEPTH_DEFAULT) - 2
            or (sellPosition.Y - sellUnderground.Y) > SELL_SAFE_DEPTH_MAX + 2)
    then
        local floorY = MyshiUtil.GetGroundY(sellPosition, nil)
        local baseY = floorY and math.min(sellPosition.Y, floorY) or sellPosition.Y
        sellUnderground = Vector3.new(
            sellPosition.X,
            baseY - (tonumber(sellSafeDepth) or SELL_SAFE_DEPTH_DEFAULT),
            sellPosition.Z
        )
        sellUndergroundSource = "migrasi kedalaman"
        SaveSellFile()
    end
end

function GetPromptAnchorPosition(prompt)
    local parent = prompt and prompt.Parent
    if not parent then
        return nil
    end

    if parent:IsA("Attachment") then
        local ok, position = pcall(function()
            return parent.WorldPosition
        end)
        if ok and position then
            return position
        end
    elseif parent:IsA("BasePart") then
        return parent.Position
    end

    local node = parent
    while node and node ~= Workspace do
        if node:IsA("Model") then
            local ok, pivot = pcall(function()
                return node:GetPivot()
            end)
            if ok and pivot then
                return pivot.Position
            end
        end
        node = node.Parent
    end

    return nil
end

function FindSellTarget(forceFresh)
    local now = os.time()
    if not forceFresh and sellDetectCache and (now - sellDetectCacheAt) < 8 then
        local prompt = sellDetectCache.prompt
        if sellDetectCache.position
            and (not prompt or (prompt.Parent and prompt.Enabled ~= false))
        then
            return sellDetectCache
        end
    end

    local result = nil

    -- Prioritas: ProximityPrompt dengan aksi/objek Sell atau Jual.
    for _, obj in ipairs(Workspace:GetDescendants()) do
        if obj:IsA("ProximityPrompt") then
            local action = string.lower(tostring(obj.ActionText or ""))
            local object = string.lower(tostring(obj.ObjectText or ""))
            local name = string.lower(tostring(obj.Name or ""))
            if string.find(action, "sell", 1, true)
                or string.find(action, "jual", 1, true)
                or string.find(object, "sell", 1, true)
                or string.find(object, "jual", 1, true)
                or string.find(name, "sell", 1, true)
                or string.find(name, "jual", 1, true)
            then
                local position = GetPromptAnchorPosition(obj)
                if position then
                    result = { position = position, prompt = obj, label = tostring(obj.ActionText or obj.Name) }
                    break
                end
            end
        end
    end

    -- Cadangan: part/model bernama Sell, Jual, SellShop, SellArea, dll.
    if not result then
        for _, obj in ipairs(Workspace:GetDescendants()) do
            if obj:IsA("BasePart") or obj:IsA("Model") then
                local name = string.lower(tostring(obj.Name or ""))
                if string.find(name, "sell", 1, true)
                    or string.find(name, "jual", 1, true)
                    or string.find(name, "sellshop", 1, true)
                then
                    local position = GetObjectAnchorPosition(obj)
                    if position then
                        result = { position = position, label = tostring(obj.Name) }
                        break
                    end
                end
            end
        end
    end

    sellDetectCache = result
    sellDetectCacheAt = now
    UpdateSellPositionLabel()
    return result
end

function SetSellPositionFromHere()
    local root = GetCharacterRoot()
    if not root then
        return false, "karakter belum siap"
    end

    sellPosition = root.Position
    sellPositionSource = "manual"
    sellUnderground = nil
    sellUndergroundSource = nil
    SaveSellFile()
    UpdateSellPositionLabel()
    return true
end

local function SaveSellUndergroundFrom(position, source)
    if not position then
        return nil
    end

    local depth = math.clamp(
        tonumber(sellSafeDepth) or SELL_SAFE_DEPTH_DEFAULT,
        3,
        SELL_SAFE_DEPTH_MAX
    )
    local floorY = MyshiUtil.GetGroundY(position, nil)
    local baseY = floorY and math.min(position.Y, floorY) or position.Y
    -- Tetap di dalam radius prompt; jangan pernah memakai 300 stud lagi.
    local sellY = floorY and (baseY - depth) or (position.Y - depth)
    sellUnderground = Vector3.new(position.X, sellY, position.Z)
    sellUndergroundSource = source or "auto"
    SaveSellFile()
    UpdateSellPositionLabel()
    return sellUnderground
end

function TravelToSell()
    if smartSafeMode then
        return false, "Smart mode aktif"
    end

    local root = GetCharacterRoot()
    if not root then
        return false, "karakter belum siap"
    end

    local target = FindSellTarget()
    local surface = sellPosition or (target and target.position)

    -- Titik bawah tanah manual tetap boleh dipakai walau titik permukaan
    -- toko belum pernah ditandai.
    if not surface and not sellUnderground then
        return false, "titik Sell belum ada"
    end

    if surface and not sellPosition then
        sellPosition = surface
        sellPositionSource = target and ("auto: " .. tostring(target.label or "Sell")) or "auto"
        SaveSellFile()
        UpdateSellPositionLabel()
    end

    -- Titik aman dihitung dari permukaan toko, bukan dari posisi karakter.
    -- Disimpan sekali, lalu dipakai lagi setelah Auto Place berikutnya.
    if surface and not sellUnderground then
        SaveSellUndergroundFrom(surface, "auto sekali di bawah Sell")
    end

    local safe = sellUnderground
    if not safe then
        return false, "titik aman bawah tanah gagal dibuat"
    end

    -- Ghost mode tidak perlu pindah; prompt Sell tetap ditembak dari jauh.
    if ghostActive then
        if target and target.prompt then
            StealUtil.ApplyPromptRange(target.prompt)
            FirePromptOnce(target.prompt)
        end
        return true, "ghost"
    end

    -- Jangan restore ke permukaan: setelah place, karakter masih di bawah
    -- penggiling dan langsung dipindah ke titik Sell bawah tanah.
    pcall(StealthHold.End, true)

    -- Kalau sudah berada di titik bawah tanah, jangan TP ke Sell lagi.
    -- Prompt tetap ditembak dari sini karena jarak prompt tidak divalidasi.
    if SafeSellAnchor.active and root and (root.Position - safe).Magnitude <= 8 then
        if target and target.prompt then
            StealUtil.ApplyPromptRange(target.prompt)
            FirePromptOnce(target.prompt)
        end
        UpdateSellPositionLabel()
        return true, "sudah di titik sell"
    end

    SafeSellAnchor.Release(false)
    SafeSellAnchor.Hold(CFrame.new(safe))
    task.wait(0.15)

    -- Langsung tembak prompt Sell dari bawah tanah. Tidak ada kunjungan ke
    -- permukaan toko, jadi pemain lain tidak melihat karakter bolak-balik.
    if target and target.prompt then
        StealUtil.ApplyPromptRange(target.prompt)
        FirePromptOnce(target.prompt)
    end

    UpdateSellPositionLabel()
    return true, "safe underground"
end

LoadSellFile()

-- =====================================================================
-- 2c-3. GHOST MODE: KARAKTER TERKUBUR, AKSI LEWAT PROMPT JARAK JAUH
-- =====================================================================
local function SetGhostPartsHidden(hidden)
    if not ghostCharacter or not ghostCharacter.Parent then
        return
    end

    if hidden then
        for _, part in ipairs(ghostCharacter:GetDescendants()) do
            if part:IsA("BasePart") and not ghostPartRestore[part] then
                ghostPartRestore[part] = {
                    transparency = part.Transparency,
                    canCollide = part.CanCollide,
                    canQuery = part.CanQuery,
                }
                pcall(function()
                    part.Transparency = 1
                    part.CanCollide = false
                    part.CanQuery = false
                end)
            end
        end
    else
        for part, info in pairs(ghostPartRestore) do
            if part and part.Parent then
                pcall(function()
                    part.Transparency = info.transparency
                    part.CanCollide = info.canCollide
                    part.CanQuery = info.canQuery
                end)
            end
        end
        ghostPartRestore = {}
    end
end

local function ExitGhostMode()
    if not ghostActive then
        ghostModeOn = false
        return
    end

    SetGhostPartsHidden(false)

    if ghostHumanoid and ghostHumanoid.Parent and ghostHumanoidRestore then
        pcall(function()
            ghostHumanoid.DisplayDistanceType = ghostHumanoidRestore.display
                or Enum.HumanoidDisplayDistanceType.Viewer
            ghostHumanoid.HealthDisplayType = ghostHumanoidRestore.health
                or Enum.HumanoidHealthDisplayType.DisplayWhenDamaged
        end)
    end
    ghostHumanoid = nil
    ghostHumanoidRestore = nil

    local camera = Workspace.CurrentCamera
    if camera and ghostCameraCFrame and ghostLockCamera then
        pcall(function()
            camera.CameraType = ghostCameraType or Enum.CameraType.Custom
            camera.CFrame = ghostCameraCFrame
        end)
    end

    local root = ghostRoot
    if root and root.Parent and LocalPlayer.Character == ghostCharacter then
        pcall(function()
            root.Anchored = false
            if ghostSafeCFrame then
                root.CFrame = ghostSafeCFrame
            end
            root.AssemblyLinearVelocity = Vector3.zero
            root.AssemblyAngularVelocity = Vector3.zero
        end)
    end

    ghostActive = false
    ghostModeOn = false
    ghostRoot = nil
    ghostCharacter = nil
    ghostSafeCFrame = nil
    ghostCameraCFrame = nil
    ghostCameraType = nil
    ghostOriginalAnchored = false
end

local function EnterGhostMode()
    if ghostActive then
        return true
    end

    local character = LocalPlayer.Character
    local root = character and character:FindFirstChild("HumanoidRootPart")
    if not root or not root.Parent then
        return false, "karakter belum siap"
    end

    pcall(StealthHold.End)
    SafeSellAnchor.Release()

    -- Karakter dikubur SANGAT dalam di bawah home, bukan cuma beberapa stud.
    -- Pemain lain hampir pasti tidak menerima replikasi visual di kedalaman
    -- ini, dan nama/health bar juga dimatikan. Prompt tetap bisa ditembak
    -- dari sini karena Paksa Jarak selalu aktif.
    local base = homePosition or root.Position
    local depth = math.clamp(
        tonumber(ghostDepth) or GHOST_DEPTH_DEFAULT,
        100,
        GHOST_DEPTH_MAX
    )
    local destination = Vector3.new(base.X, base.Y - depth, base.Z)
    local rotation = root.CFrame - root.CFrame.Position
    local destinationCFrame = CFrame.new(destination) * rotation

    ghostCharacter = character
    ghostRoot = root
    ghostSafeCFrame = root.CFrame
    ghostOriginalAnchored = root.Anchored == true

    ghostHumanoid = character:FindFirstChildOfClass("Humanoid")
    if ghostHumanoid then
        ghostHumanoidRestore = {
            display = ghostHumanoid.DisplayDistanceType,
            health = ghostHumanoid.HealthDisplayType,
        }
        pcall(function()
            ghostHumanoid.DisplayDistanceType = Enum.HumanoidDisplayDistanceType.None
            ghostHumanoid.HealthDisplayType = Enum.HumanoidHealthDisplayType.AlwaysOff
        end)
    end

    local camera = Workspace.CurrentCamera
    if camera then
        ghostCameraCFrame = camera.CFrame
        ghostCameraType = camera.CameraType
    end

    pcall(function()
        root.Anchored = false
        root.CFrame = destinationCFrame
        root.AssemblyLinearVelocity = Vector3.zero
        root.AssemblyAngularVelocity = Vector3.zero
    end)
    task.wait(0.15)

    if root.Parent then
        pcall(function()
            root.Anchored = true
        end)
    end

    SetGhostPartsHidden(true)

    if camera and ghostLockCamera and ghostCameraCFrame then
        pcall(function()
            camera.CameraType = Enum.CameraType.Scriptable
            camera.CFrame = ghostCameraCFrame
        end)
    end

    ghostActive = true
    ghostModeOn = true
    ghostWanted = true
    return true
end

local function UpdateGhostStatus()
    if not ghostStatusLabel then
        return
    end

    if ghostActive then
        ghostStatusLabel:Set(string.format(
            "Ghost: aktif | %.0f stud di bawah map | nama disembunyikan | kamera %s",
            tonumber(ghostDepth) or GHOST_DEPTH_DEFAULT,
            ghostLockCamera and "dikunci" or "bebas"
        ))
    else
        ghostStatusLabel:Set(ghostWanted
            and "Ghost: menunggu karakter respawn..."
            or "Ghost: nonaktif.")
    end
end

-- Ghost mode tidak bisa memakai StealthHold (memang sengaja tidak boleh
-- unanchor saat ghost). Untuk Auto Place, pindahkan root sementara ke bawah
-- penggiling, lalu kembalikan ke titik ghost setelah percobaan selesai.
ghostActionReturnCFrame = nil

function GhostMoveTo(cframe)
    if not ghostActive or not ghostRoot or not ghostRoot.Parent
        or not cframe or not ghostCharacter
        or LocalPlayer.Character ~= ghostCharacter
    then
        return false
    end

    if not ghostActionReturnCFrame then
        ghostActionReturnCFrame = ghostRoot.CFrame
    end

    pcall(function()
        ghostRoot.Anchored = false
        ghostRoot.CFrame = cframe
        ghostRoot.AssemblyLinearVelocity = Vector3.zero
        ghostRoot.AssemblyAngularVelocity = Vector3.zero
    end)
    task.wait(0.12)

    if ghostRoot and ghostRoot.Parent then
        pcall(function()
            ghostRoot.Anchored = true
        end)
    end

    return true
end

function GhostRestore()
    if not ghostActive then
        ghostActionReturnCFrame = nil
        return
    end
    if not ghostActionReturnCFrame or not ghostRoot or not ghostRoot.Parent then
        ghostActionReturnCFrame = nil
        return
    end

    local back = ghostActionReturnCFrame
    ghostActionReturnCFrame = nil

    pcall(function()
        ghostRoot.Anchored = false
        ghostRoot.CFrame = back
        ghostRoot.AssemblyLinearVelocity = Vector3.zero
        ghostRoot.AssemblyAngularVelocity = Vector3.zero
    end)
    task.wait(0.12)

    if ghostRoot and ghostRoot.Parent then
        pcall(function()
            ghostRoot.Anchored = true
        end)
    end
end

LocalPlayer.CharacterAdded:Connect(function()
    local wasWanted = ghostWanted or ghostActive
    if ghostActive then
        pcall(ExitGhostMode)
    end

    if wasWanted then
        task.delay(1.2, function()
            if running and ghostWanted and not ghostActive then
                local ok, err = pcall(EnterGhostMode)
                if not ok and ghostStatusLabel then
                    ghostStatusLabel:Set("Ghost: gagal masuk ulang - " .. tostring(err) .. ".")
                end
            end
        end)
    end
end)

local function GetDirectGrinderPrompt(grinder)
    local attachment = grinder and grinder:FindFirstChild("CustomPromptAttachment")
    if not attachment then
        return nil
    end

    local prompt = attachment:FindFirstChild("CustomPrompt")
    if prompt and prompt:IsA("ProximityPrompt") then
        return prompt
    end

    return nil
end

local function GetGrinderPrompt(grinder)
    local prompt = GetDirectGrinderPrompt(grinder)
    if prompt then
        return prompt
    end

    -- Cadangan kalau struktur prompt sedikit berbeda.
    for _, obj in ipairs(grinder:GetDescendants()) do
        if obj:IsA("ProximityPrompt") then
            local action = string.lower(tostring(obj.ActionText or ""))
            local object = string.lower(tostring(obj.ObjectText or ""))
            if string.find(action, "giling", 1, true)
                or string.find(action, "grind", 1, true)
                or string.find(object, GRINDER_NAME_KEYWORD, 1, true)
            then
                return obj
            end
        end
    end

    return nil
end

-- Mengembalikan part yang jadi titik acuan penggiling, atau nil.
-- Penggiling bisa berupa Part langsung (seperti save.rbxmx) atau Model yang
-- membungkus part tersebut.
local function GetGrinderAnchor(obj)
    if not obj then
        return nil
    end

    local isPart = obj:IsA("BasePart")
    if not isPart and not obj:IsA("Model") then
        return nil
    end

    local name = string.lower(tostring(obj.Name or ""))
    local nameMatches = string.find(name, GRINDER_NAME_KEYWORD, 1, true) ~= nil

    if nameMatches then
        if GetGrinderPrompt(obj) == nil then
            return nil
        end

        if isPart then
            return obj
        end

        -- Model: pakai part yang punya prompt sebagai titik acuan.
        for _, descendant in ipairs(obj:GetDescendants()) do
            if descendant:IsA("BasePart") and GetGrinderPrompt(descendant) then
                return descendant
            end
        end

        return nil
    end

    if not isPart then
        return nil
    end

    local prompt = GetDirectGrinderPrompt(obj)
    if not prompt then
        return nil
    end

    local action = string.lower(tostring(prompt.ActionText or ""))
    local object = string.lower(tostring(prompt.ObjectText or ""))
    if string.find(action, "giling", 1, true)
        or string.find(action, "grind", 1, true)
        or string.find(object, GRINDER_NAME_KEYWORD, 1, true)
    then
        return obj
    end

    return nil
end

local function GetGrinderPosition(grinder)
    local attachment = grinder:FindFirstChild("CustomPromptAttachment")
    if attachment and attachment:IsA("Attachment") then
        local ok, worldPosition = pcall(function()
            return attachment.WorldPosition
        end)
        if ok and worldPosition then
            return worldPosition
        end
    end

    return grinder.Position + Vector3.new(0, grinder.Size.Y / 2 + 1.5, 0)
end

local function GetStoneParts(fresh)
    if not fresh and stoneCacheReady then
        return cachedStoneParts
    end

    local stones = {}
    for _, obj in ipairs(Workspace:GetDescendants()) do
        if obj.Name == "batu" and obj:IsA("BasePart") then
            table.insert(stones, obj)
        end
    end
    return stones
end

local function IsStoneAtGrinder(stone, grinder)
    if not stone or not stone.Parent then
        return false
    end

    -- Batu yang masih dipegang (Tool di karakter) tidak boleh dianggap sudah
    -- diletakkan, walaupun posisinya dekat penggiling saat TP bawah tanah.
    local character = LocalPlayer.Character
    if character and stone:IsDescendantOf(character) then
        return false
    end

    local backpack = LocalPlayer:FindFirstChild("Backpack")
    if backpack and stone:IsDescendantOf(backpack) then
        return false
    end

    local target = GetGrinderPosition(grinder)
    local delta = stone.Position - target

    if math.abs(delta.Y) > GRINDER_STONE_HEIGHT then
        return false
    end

    if Vector2.new(delta.X, delta.Z).Magnitude > GRINDER_STONE_RADIUS then
        return false
    end

    -- Batu yang sedang diangkat biasanya ada di atas kepala. Batu yang sudah
    -- diletakkan di penggiling berada di titik prompt (biasanya lebih rendah
    -- dari root karakter).
    if stone.Anchored then
        return true
    end

    local root = GetCharacterRoot()
    if root and root.Position.Y > target.Y + 1
        and stone.Position.Y >= root.Position.Y + 1.5
        and (stone.Position - root.Position).Magnitude <= 12
    then
        return false
    end

    return true
end

local function GetGrinderLabel(obj, part)
    if obj:IsA("Model") then
        return tostring(obj.Name)
    end

    local parent = obj.Parent
    if parent and parent:IsA("Model") then
        local parentName = string.lower(tostring(parent.Name or ""))
        if string.find(parentName, GRINDER_NAME_KEYWORD, 1, true) then
            return tostring(parent.Name)
        end
    end

    return tostring(part.Name)
end

local function ComputeGrinderStates(grinders, stones)
    local states = {}

    for index, entry in ipairs(grinders) do
        local grinder = entry.part or entry
        local label = entry.label or tostring(grinder.Name)
        local occupant = nil

        for _, stone in ipairs(stones) do
            if IsStoneAtGrinder(stone, grinder) then
                occupant = stone
                break
            end
        end

        states[index] = {
            index = index,
            grinder = grinder,
            label = label,
            distance = entry.distance,
            occupied = occupant ~= nil,
            occupant = occupant,
        }
    end

    return states
end

local function IsGrinderOccupied(grinder, fresh)
    for _, stone in ipairs(GetStoneParts(fresh)) do
        if IsStoneAtGrinder(stone, grinder) then
            return true
        end
    end
    return false
end

local function GetGrinderScanOrigin()
    if homeOnly then
        if homePosition then
            return homePosition, homeRadius
        end
        return nil, 0
    end

    local root = GetCharacterRoot()
    if not root then
        return nil, 0
    end

    return root.Position, grinderRadius
end

local function GetNearbyGrinders()
    local origin, radius = GetGrinderScanOrigin()
    if not origin then
        return {}
    end

    local found = {}

    local seen = {}

    for _, obj in ipairs(Workspace:GetDescendants()) do
        local grinder = GetGrinderAnchor(obj)
        if grinder and grinder.Parent and not seen[grinder] then
            seen[grinder] = true

            local distance = (grinder.Position - origin).Magnitude

            if distance <= radius then
                local duplicate = false
                for _, entry in ipairs(found) do
                    if (entry.part.Position - grinder.Position).Magnitude <= GRINDER_DEDUPE_DISTANCE then
                        duplicate = true
                        break
                    end
                end

                if not duplicate then
                    table.insert(found, {
                        part = grinder,
                        label = GetGrinderLabel(obj, grinder),
                        distance = distance,
                    })
                end
            end
        end
    end

    table.sort(found, function(a, b)
        if math.abs(a.distance - b.distance) < 0.001 then
            return string.lower(a.label) < string.lower(b.label)
        end
        return a.distance < b.distance
    end)

    return found
end

local function GetGrinderStates()
    return ComputeGrinderStates(GetNearbyGrinders(), GetStoneParts())
end

function FindHeldStone()
    local character = LocalPlayer.Character
    local root = character and character:FindFirstChild("HumanoidRootPart")
    if not character or not root then
        return nil
    end

    -- Tool di karakter atau di Backpack. Batu hasil steal kadang masuk ke
    -- Backpack dulu; itu tetap dianggap sedang dibawa supaya Auto Steal tidak
    -- mencuri batu kedua dan karakter tetap menunggu Auto Place.
    for _, container in ipairs({ character, LocalPlayer:FindFirstChild("Backpack") }) do
        if container then
            for _, obj in ipairs(container:GetChildren()) do
                if obj:IsA("Tool") and IsStoneName(obj.Name) then
                    return obj
                end
            end
        end
    end

    local stones = cachedStoneParts
    if not stoneCacheReady then
        stones = Workspace:GetDescendants()
    end

    for _, obj in ipairs(stones) do
        if obj.Parent and obj.Name == "batu"
            and obj:IsA("BasePart") and not obj.Anchored
        then
            -- Batu dunia yang masih punya prompt aktif bukan batu di tangan.
            local attachment = obj:FindFirstChild("CustomPromptAttachment")
            local prompt = attachment and attachment:FindFirstChild("CustomPrompt")
            local hasActivePrompt = prompt ~= nil and prompt.Enabled == true

            -- Batu di tangan menempel dekat root (+-3,5 stud pada data tracker).
            -- Jangan pakai radius 7: batu target yang sedang di-steal dari bawah
            -- juga berjarak sekitar 7 stud dan bisa salah dianggap di tangan.
            if not hasActivePrompt
                and obj.Position.Y >= root.Position.Y + 1.5
                and (obj.Position - root.Position).Magnitude <= 5
            then
                return obj
            end
        end
    end

    return nil
end

-- Cek instance batu yang tadi dipegang. Ini lebih akurat daripada
-- FindHeldStone untuk momen setelah place: batu bisa masih melayang di atas
-- kepala walau belum terdeteksi sebagai Tool.
function MyshiUtil.IsStillCarried(stone, root)
    if not stone or not stone.Parent then
        return false
    end

    if stone:IsA("Tool") then
        local backpack = LocalPlayer:FindFirstChild("Backpack")
        return stone.Parent == LocalPlayer.Character
            or (backpack ~= nil and stone:IsDescendantOf(backpack))
    end

    if stone:IsA("BasePart") and root and root.Parent then
        return stone.Anchored ~= true
            and (stone.Position - root.Position).Magnitude <= 10
    end

    return false
end

local function EquipStoneTool()
    local character = LocalPlayer.Character
    local backpack = LocalPlayer:FindFirstChild("Backpack")
    local humanoid = character and character:FindFirstChildOfClass("Humanoid")
    if not character or not backpack or not humanoid then
        return nil
    end

    for _, obj in ipairs(backpack:GetChildren()) do
        if obj:IsA("Tool") and IsStoneName(obj.Name) then
            pcall(function()
                humanoid:EquipTool(obj)
            end)
            task.wait(0.15)
            return obj
        end
    end

    return nil
end

local function EnsureHeldStone()
    local held = FindHeldStone()

    -- Batu di Backpack harus di-equip dulu; prompt Giling Batu tidak membaca
    -- Tool yang masih tersimpan di inventory.
    if held and held:IsA("Tool") and held.Parent ~= LocalPlayer.Character then
        local character = LocalPlayer.Character
        local humanoid = character and character:FindFirstChildOfClass("Humanoid")
        if humanoid then
            pcall(function()
                humanoid:EquipTool(held)
            end)
            task.wait(0.15)
        end
    end

    return held or EquipStoneTool()
end

local function TryPlaceAtGrinder(state)
    if smartSafeMode then
        return false, "Smart Auto Steal: mode AFK di base"
    end

    local grinder = state.grinder
    if not grinder or not grinder.Parent then
        return false, "penggiling hilang"
    end

    -- Selalu cek fresh, jangan memakai cache radar. Cache yang basi membuat
    -- Auto Place mengira penggiling kosong, menembak prompt yang sudah terisi,
    -- lalu menganggap batu baru sudah masuk dan langsung TP ke Sell.
    if IsGrinderOccupied(grinder, true) then
        return false, "penggiling sudah terisi"
    end

    local heldBefore = EnsureHeldStone()
    MyshiLastPlaceStone = heldBefore
    if autoPlaceCheckStone and not heldBefore then
        return false, "tidak ada batu di tangan"
    end

    local prompt = GetGrinderPrompt(grinder)
    if not prompt then
        return false, "prompt Giling Batu tidak ditemukan"
    end

    -- Auto Place juga butuh mendekat ke prompt. Ghost mode selalu
    -- dipindahkan sementara ke bawah penggiling karena titik ghost berada
    -- ratusan stud di bawah home, jadi prompt Giling Batu ditolak server.
    local usePlaceTp = autoPlaceTeleport or ghostActive
    if usePlaceTp then
        local root = GetCharacterRoot()
        if not root then
            return false, "karakter belum siap"
        end

        -- Sama seperti Auto Steal: posisi tetap di dalam radius prompt 8 stud.
        -- Kedalaman besar membuat server menolak Giling Batu, lalu Auto Place
        -- terlihat tidak pernah memasukkan batu ke penggiling.
        local maxDistance = math.max(6.5, PROMPT_MAX_DISTANCE - 0.2)
        local burial = math.clamp(
            tonumber(autoStealTpDepth) or AUTO_STEAL_TP_DEPTH_DEFAULT,
            3,
            6
        )
        local promptPosition = StealUtil.PromptWorldPosition(nil, prompt)
            or (grinder.Position + Vector3.new(0, grinder.Size.Y / 2 + 1.5, 0))
        local floorY = MyshiUtil.GetGroundY(promptPosition, grinder)
        local placeY = promptPosition.Y - maxDistance
        if floorY and floorY < promptPosition.Y then
            placeY = math.max(placeY, floorY - burial)
        end
        placeY = math.min(placeY, promptPosition.Y - 1.5)
        local placeCFrame = CFrame.new(Vector3.new(
            promptPosition.X,
            placeY,
            promptPosition.Z
        ))

        if ghostActive then
            -- Ghost tidak boleh memakai StealthHold; root-nya di-anchor jauh
            -- di bawah map. GhostMoveTo menyimpan posisi ghost dan
            -- mengembalikannya setelah percobaan place selesai.
            if not GhostMoveTo(placeCFrame) then
                return false, "gagal memindahkan ghost ke penggiling"
            end
            task.wait(0.25)
        else
            -- Kalau karakter masih ditahan di bawah batu sambil membawa batu,
            -- lepas anchor dulu supaya CFrame ke penggiling ikut ke server.
            if StealthHold.active and StealthHold.held then
                StealthHold.Release()
                task.wait(0.05)
            end

            if not StealthHold.Begin() then
                return false, "anti-void tidak bisa aktif"
            end

            -- TP dulu saat unanchored, baru ditahan.
            root.CFrame = placeCFrame
            root.AssemblyLinearVelocity = Vector3.zero
            root.AssemblyAngularVelocity = Vector3.zero
            StealthHold.Hold(placeCFrame)
            task.wait(0.25)
        end
    end

    StealUtil.ApplyPromptRange(prompt)

    -- Tembak berulang selama batu masih di tangan. Server kadang menolak
    -- tembakan pertama (streaming penggiling / Tool baru di-equip), dan
    -- ghost mode butuh kepastian sebelum root dikembalikan ke bawah home.
    local fired = false
    for attempt = 1, (ghostActive and 3 or 2) do
        if attempt > 1 and not (FindHeldStone and FindHeldStone()) then
            break
        end
        if FirePromptOnce(prompt) then
            fired = true
        end
        task.wait(attempt == 1 and 1.4 or 0.9)
    end
    if not fired then
        return false, "prompt Giling Batu gagal ditembak"
    end

    -- Sukses HANYA kalau batu benar-benar lepas dari karakter/Backpack DAN
    -- ada batu di penggiling. Diperiksa beberapa kali supaya batu yang masih
    -- melayang di atas kepala tidak dianggap sudah masuk penggiling.
    local rootAfter = GetCharacterRoot()
    local heldAfter = FindHeldStone and FindHeldStone()
    local occupied = IsGrinderOccupied(grinder, true)
    local placed = heldBefore ~= nil and occupied and heldAfter == nil
        and not MyshiUtil.IsStillCarried(heldBefore, rootAfter)

    if placed then
        for _ = 1, 6 do
            task.wait(0.25)
            rootAfter = GetCharacterRoot()
            heldAfter = FindHeldStone and FindHeldStone() or nil
            if heldAfter or MyshiUtil.IsStillCarried(heldBefore, rootAfter) then
                placed = false
                break
            end
            if not IsGrinderOccupied(grinder, true) then
                placed = false
                break
            end
        end
    end

    if placed then
        return true, "prompt " .. tostring(prompt.ActionText or "Giling Batu")
    end

    if heldAfter then
        return false, "batu masih di tangan, belum masuk penggiling"
    end

    return false, "prompt terkirim, batu belum terlihat di penggiling"
end

local function StartPlaceAttempt(state, manual)
    if placeBusy then
        return false, "Auto Place sedang berjalan"
    end
    if autoBusy or instantBusy or placePrepBusy or sellBusy then
        return false, "fitur lain sedang berjalan"
    end
    if not state then
        return false, "tidak ada penggiling kosong"
    end

    placeBusy = true

    if placeStatusLabel then
        placeStatusLabel:Set(string.format("Auto Place: mencoba %s...", state.label))
    end

    task.spawn(function()
        local callOk, resultA, resultB = pcall(TryPlaceAtGrinder, state)

        -- Kalau tadi GhostMoveTo memindahkan root ke penggiling, kembalikan
        -- ke titik ghost setelah percobaan selesai (berhasil maupun gagal).
        pcall(GhostRestore)

        local ok = false
        local message = "unknown error"

        if callOk then
            ok = resultA == true
            message = resultB
        else
            message = "error: " .. tostring(resultA)
        end

        -- Kalau batu masih dibawa, JANGAN muncul ke permukaan. Auto Place akan
        -- mencoba lagi dan karakter tetap terkubur sampai batu benar-benar
        -- masuk penggiling.
        local rootNow = GetCharacterRoot()
        local heldNow = FindHeldStone and FindHeldStone() or nil
        if not heldNow and MyshiLastPlaceStone
            and MyshiUtil.IsStillCarried(MyshiLastPlaceStone, rootNow)
        then
            heldNow = MyshiLastPlaceStone
        end

        local willSell = ok and sellTpOnPlace
            and not smartSafeMode and not ghostActive
        if not heldNow and not willSell then
            pcall(StealthHold.End)
        end

        placeBusy = false

        if not running then
            return
        end

        placeCooldownUntil = os.time() + math.max(0, tonumber(autoPlaceDelay) or AUTO_PLACE_DELAY_DEFAULT)

        if ok then
            placeFailedAt[state.grinder] = nil
            if placeStatusLabel then
                placeStatusLabel:Set(string.format(
                    "Auto Place: %s berhasil (%s).",
                    state.label,
                    tostring(message)
                ))
            end
            if manual then
                pcall(function()
                    UI:Notify({
                        Title = "Auto Place",
                        Content = string.format("%s berhasil diisi.", state.label),
                        Icon = "gem",
                        Type = "Success",
                        Duration = 3,
                    })
                end)
            end

            -- Sell hanya setelah place sukses DAN batu sudah tidak di tangan.
            -- Dijalankan di luar TryPlaceAtGrinder supaya urutannya tidak bisa
            -- terbalik lagi (shop dulu, penggiling belakangan).
            if sellTpOnPlace and not smartSafeMode and not ghostActive then
                task.spawn(function()
                    placePrepBusy = true
                    -- Beri waktu server memproses Giling Batu. Jangan pernah
                    -- TP ke Sell sebelum batu benar-benar terlihat di penggiling.
                    task.wait(1.5)
                    if not running then
                        placePrepBusy = false
                        return
                    end
                    local sellRoot = GetCharacterRoot()
                    local stillHeld = (FindHeldStone and FindHeldStone())
                        or (MyshiLastPlaceStone
                            and MyshiUtil.IsStillCarried(MyshiLastPlaceStone, sellRoot))
                    if stillHeld then
                        placePrepBusy = false
                        if placeStatusLabel then
                            placeStatusLabel:Set("Auto Place: berhasil, TP Sell ditunda - batu masih dibawa.")
                        end
                        return
                    end
                    local sellCallOk, sellOk, sellErr = pcall(TravelToSell)
                    placePrepBusy = false
                    if not running then
                        return
                    end

                    if not sellCallOk then
                        if placeStatusLabel then
                            placeStatusLabel:Set("Auto Place: berhasil, TP Sell error - "
                                .. tostring(sellOk) .. ".")
                        end
                    elseif not sellOk and placeStatusLabel then
                        placeStatusLabel:Set("Auto Place: berhasil, TP Sell gagal - "
                            .. tostring(sellErr) .. ".")
                    end
                end)
            end
        else
            placeFailedAt[state.grinder] = os.time() + PLACE_FAIL_COOLDOWN
            if placeStatusLabel then
                placeStatusLabel:Set(string.format(
                    "Auto Place: %s gagal - %s",
                    state.label,
                    tostring(message)
                ))
            end
            if manual then
                pcall(function()
                    UI:Notify({
                        Title = "Auto Place gagal",
                        Content = tostring(message),
                        Icon = "triangle-alert",
                        Type = "Warning",
                        Duration = 4,
                    })
                end)
            end
        end
    end)

    return true
end

local function UpdatePlacementStatus(states)
    if not placeSummaryLabel or not grinderListParagraph then
        return
    end

    local found = #states
    local freeCount = 0
    local lines = {}

    if homeOnly and not homePosition then
        grinderListParagraph:Set(
            "Home belum ditandai. Startup akan TP ke home sekali; kalau gagal, klik 'Set Home ke Posisi Ini'."
        )
        placeSummaryLabel:Set("Penggiling: 0 | Home belum ditandai")
        return
    end

    for index, state in ipairs(states) do
        if not state.occupied then
            freeCount = freeCount + 1
        end

        if index <= GRINDER_DISPLAY_LIMIT then
            local suffix = ""
            if state.distance then
                suffix = string.format(" (%.0f stud)", state.distance)
            end
            table.insert(lines, string.format(
                "%s: %s%s",
                state.label,
                state.occupied and "terisi" or "kosong",
                suffix
            ))
        end
    end

    if found > GRINDER_DISPLAY_LIMIT then
        table.insert(lines, string.format(
            "+%d penggiling lain...",
            found - GRINDER_DISPLAY_LIMIT
        ))
    end

    local radius = homeOnly and homeRadius or grinderRadius
    local anchorText = homeOnly and "home" or "karakter"

    if found == 0 then
        grinderListParagraph:Set(string.format(
            "Belum ada penggiling terdeteksi dalam radius %d stud dari %s.",
            radius,
            anchorText
        ))
        if homeOnly then
            placeSummaryLabel:Set("Penggiling di home: 0 | cek posisi home / naikkan radius")
        else
            placeSummaryLabel:Set("Penggiling: 0 | dekatkan ke penggiling / naikkan radius")
        end
    else
        grinderListParagraph:Set(table.concat(lines, "\n"))
        if homeOnly then
            placeSummaryLabel:Set(string.format(
                "Penggiling di home: %d | Kosong: %d | Radius %d",
                found,
                freeCount,
                radius
            ))
        else
            placeSummaryLabel:Set(string.format(
                "Penggiling: %d | Kosong: %d | Radius %d",
                found,
                freeCount,
                radius
            ))
        end
    end
end

local function FindAutoPlaceTarget(states, now)
    now = now or os.time()

    local target = nil
    local freeCount = 0

    for _, state in ipairs(states) do
        if not state.occupied then
            freeCount = freeCount + 1
            if not target and now >= (placeFailedAt[state.grinder] or 0) then
                target = state
            end
        end
    end

    return target, #states, freeCount
end

local function ManualPlace()
    if placeBusy then
        pcall(function()
            UI:Notify({
                Title = "Auto Place",
                Content = "Sedang mencoba place. Tunggu sebentar.",
                Icon = "clock",
                Type = "Info",
                Duration = 2,
            })
        end)
        return
    end

    if autoBusy or instantBusy or placePrepBusy or sellBusy then
        pcall(function()
            UI:Notify({
                Title = "Auto Place",
                Content = "Fitur lain sedang berjalan. Tunggu sampai selesai.",
                Icon = "clock",
                Type = "Info",
                Duration = 2,
            })
        end)
        return
    end

    -- Mode home: pastikan titik home sudah ada.
    if homeOnly and not homePosition then
        placePrepBusy = true
        task.spawn(function()
            if placeStatusLabel then
                placeStatusLabel:Set("Auto Place: menandai home...")
            end

            local callOk, ok, err = pcall(EnsureHomeReady)
            placePrepBusy = false
            if not running then
                return
            end

            if not callOk then
                pcall(function()
                    UI:Notify({
                        Title = "Home gagal ditandai",
                        Content = tostring(ok),
                        Icon = "triangle-alert",
                        Type = "Warning",
                        Duration = 4,
                    })
                end)
            elseif ok then
                task.wait(0.8)
                ManualPlace()
            else
                pcall(function()
                    UI:Notify({
                        Title = "Home belum ditandai",
                        Content = tostring(err) .. ". Berdiri di home lalu klik 'Set ke Posisi Ini'.",
                        Icon = "house",
                        Type = "Warning",
                        Duration = 4,
                    })
                end)
            end
        end)
        return
    end

    local states = GetGrinderStates()
    UpdatePlacementStatus(states)

    -- Mode home: penggiling home belum termuat (streaming), TP pulang dulu.
    if homeOnly and homePosition and #states == 0 then
        local root = GetCharacterRoot()
        if root and (root.Position - homePosition).Magnitude > HOME_TRAVEL_DISTANCE then
            if placeStatusLabel then
                placeStatusLabel:Set("Auto Place: TP home dulu untuk memuat penggiling...")
            end

            placePrepBusy = true
            task.spawn(function()
                local callOk, ok, err = pcall(TravelHome)
                placePrepBusy = false
                if not running then
                    return
                end

                if not callOk then
                    if placeStatusLabel then
                        placeStatusLabel:Set("Auto Place: error TP home - " .. tostring(ok) .. ".")
                    end
                elseif ok then
                    task.wait(1)
                    ManualPlace()
                elseif placeStatusLabel then
                    placeStatusLabel:Set("Auto Place: " .. tostring(err) .. ".")
                end
            end)
            return
        end
    end

    if #states == 0 then
        pcall(function()
            UI:Notify({
                Title = "Auto Place",
                Content = "Penggiling belum terdeteksi di sekitar home. Cek posisi home atau naikkan Radius Home.",
                Icon = "map-pin",
                Type = "Warning",
                Duration = 3,
            })
        end)
        return
    end

    local target = nil
    for _, state in ipairs(states) do
        if not state.occupied then
            target = state
            break
        end
    end

    if not target then
        pcall(function()
            UI:Notify({
                Title = "Auto Place",
                Content = "Semua penggiling sudah ada batu.",
                Icon = "check",
                Type = "Info",
                Duration = 3,
            })
        end)
        return
    end

    StartPlaceAttempt(target, true)
end

local function HandleAutoPlace(states)
    if not autoPlaceOn or smartSafeMode then
        return false
    end
    if startupHomePending then
        if placeStatusLabel then
            placeStatusLabel:Set("Auto Place: menunggu auto-home startup selesai...")
        end
        return false
    end
    if placeBusy
        or placePrepBusy
        or autoBusy
        or instantBusy
        or sellBusy
        or os.time() < placeCooldownUntil
    then
        return false
    end

    local character = LocalPlayer.Character
    local humanoid = character and character:FindFirstChildOfClass("Humanoid")
    if not character or not humanoid or humanoid.Health <= 0 then
        return false
    end

    -- Home ditandai sekali saat startup. Jangan menebak posisi spawn sebagai
    -- home; kalau belum ada, minta set manual.
    if homeOnly and not homePosition then
        if placeStatusLabel then
            placeStatusLabel:Set("Auto Place: home belum ada. Klik 'Set Home ke Posisi Ini'.")
        end
        return false
    end

    -- Mode home: kalau penggiling home belum termuat (streaming), TP pulang.
    if homeOnly and homePosition and #states == 0 then
        local root = GetCharacterRoot()
        local distance = root and (root.Position - homePosition).Magnitude or nil

        if distance and distance > HOME_TRAVEL_DISTANCE and os.time() >= homeTravelAt then
            homeTravelAt = os.time() + 10
            if placeStatusLabel then
                placeStatusLabel:Set("Auto Place: TP home untuk memuat penggiling...")
            end

            placePrepBusy = true
            task.spawn(function()
                local callOk, ok, err = pcall(TravelHome)
                placePrepBusy = false
                if not running then
                    return
                end

                if not callOk then
                    if placeStatusLabel then
                        placeStatusLabel:Set("Auto Place: error TP home - " .. tostring(ok) .. ".")
                    end
                elseif not ok and placeStatusLabel then
                    placeStatusLabel:Set("Auto Place: " .. tostring(err) .. ".")
                end
                placeCooldownUntil = 0
            end)
            return true
        end
    end

    local target, found, freeCount = FindAutoPlaceTarget(states, os.time())

    if found == 0 then
        if placeStatusLabel then
            placeStatusLabel:Set("Auto Place: penggiling belum termuat. Menunggu...")
        end
        return false
    end

    if freeCount == 0 then
        if placeStatusLabel then
            placeStatusLabel:Set("Auto Place: semua penggiling sudah ada batu.")
        end
        return false
    end

    if autoPlaceCheckStone and not EnsureHeldStone() then
        if placeStatusLabel then
            placeStatusLabel:Set("Auto Place: menunggu batu di tangan...")
        end
        return false
    end

    if not target then
        if placeStatusLabel then
            placeStatusLabel:Set("Auto Place: menunggu cooldown penggiling gagal.")
        end
        return false
    end

    return StartPlaceAttempt(target, false)
end


-- =====================================================================
-- 2d. AUTO SELL
-- =====================================================================
local SELL_CONTAINER_KEYWORDS = {
    "inventory", "backpack", "bag", "hotbar", "slotbar", "slot bar",
    "quickbar", "quickslot", "quickaccess", "itemlist", "itemgrid",
    "itemcontainer",
}

local SELL_SHOP_KEYWORDS = { "shop", "store" }

local SELL_UI_SKIP_KEYWORDS = {
    "action", "actions", "context", "contextmenu", "tooltip", "prompt",
    "dropdown", "confirmation", "dialog",
}

local SELL_ACTION_PREFIXES = {
    "turunkan", "turunin", "giling", "letakkan", "taruh", "pasang",
    "ambil", "pakai", "gunakan", "jual", "buka", "tutup", "kembali",
    "batal", "batalkan", "konfirmasi", "pilih", "simpan", "hapus",
    "lempar", "lepas", "jatuhkan", "jatuhin", "buang", "singkirkan",
    "pindahkan", "naikin", "naikkan", "beli", "kirim", "tukar",
    "upgrade", "equip", "unequip", "use", "sell", "buy", "drop",
    "place", "grind", "open", "close", "cancel", "confirm", "select",
    "remove", "delete", "discard", "preview", "detail", "details", "info",
}

local SELL_BLOCKLIST = {
    "sell", "sell all", "sellall", "sold", "inventory", "item", "items",
    "backpack", "collection", "owned", "storage", "shop", "shop items",
    "close", "closed", "open", "equip", "use", "confirm", "cancel",
    "buy", "coins", "coin", "cash", "money", "gems", "gem",
    "amount", "quantity", "total", "price", "value", "level", "stats",
    "rarity", "common", "uncommon", "rare", "epic", "legendary",
    "galaxy", "mythic", "secret", "penggiling", "home", "loading", "please wait",
    "unknown", "none", "empty", "locked", "unlocked", "yes", "no",
    "ok", "back", "next", "previous", "page", "search", "filter",
    "sort", "select", "selected", "inventory items", "your items",
    "true", "false", "nil", "null", "enabled", "disabled",
    "owneditems", "inventoryitems", "itemdata", "itemsdata",
    "count", "itemid", "itemtype", "itemrarity", "itemkey",
    "new", "hot", "sale", "free", "gift", "reward", "rewards",
    "equipped", "unequipped", "max", "maxed",
    -- Item yang tidak boleh dijual Auto Sell.
    "pumpkin", "pumpkins", "yobux",
}

local SELL_HARD_BLOCKLIST = { "pumpkin", "yobux" }

local SELL_INTERNAL_NAMES = {
    "handle", "mesh", "meshpart", "part", "model", "effect", "effects",
    "attachment", "hitbox", "root", "humanoidrootpart", "primarypart",
    "main", "object", "background", "icon", "image", "itemname",
    "itemlabel", "itemamount", "itemcount", "itemdesc", "itemdescription",
    "slots", "slot", "grid", "content", "list", "name", "text", "title",
    "description", "desc", "textlabel", "textbutton", "imagebutton",
    "frame", "container", "entry", "card", "preview", "template",
    "thumbnail", "display", "visual",
}

local SELL_UI_BLOCK_PARTS = {
    "sell", "buy", "coin", "cash", "price", "owned", "inventory",
    "equip", "confirm", "cancel", "close", "open", "search", "filter",
    "sort", "page", "loading", "button", "label", "frame", "slot",
    "template", "preview", "quantity", "amount", "total", "damage",
    "level", "lvl",
}

local function HasAnyKeyword(lowerName, keywords)
    for _, keyword in ipairs(keywords) do
        if string.find(lowerName, keyword, 1, true) then
            return true
        end
    end
    return false
end

local function IsShopContainer(name)
    return HasAnyKeyword(string.lower(tostring(name or "")), SELL_SHOP_KEYWORDS)
end

-- Hanya container inventory, bag, hotbar/slot bar, dan quickbar.
local function IsSellContainer(name)
    local lower = string.lower(tostring(name or ""))
    if IsShopContainer(lower) then
        return false
    end
    return HasAnyKeyword(lower, SELL_CONTAINER_KEYWORDS)
end

local function IsSkippedUiContainer(name)
    return HasAnyKeyword(
        string.lower(tostring(name or "")),
        SELL_UI_SKIP_KEYWORDS
    )
end

-- Teks seperti "Turunkan Batu" atau "Giling Batu" adalah aksi UI,
-- bukan nama item, jadi tidak boleh ikut dijual.
local function StartsWithAction(value)
    local lower = string.lower(value)
    for _, word in ipairs(SELL_ACTION_PREFIXES) do
        if lower == word or string.sub(lower, 1, #word + 1) == word .. " " then
            return true
        end
    end
    return false
end

local function CleanSellName(name)
    local value = tostring(name or "")
    value = value:gsub("<[^>]*>", "")
    value = value:gsub("^%s+", ""):gsub("%s+$", "")
    value = value:gsub("%s*[xX]%s*%d+%s*$", "")
    value = value:gsub("%s*%(%s*%d+%s*%)%s*$", "")
    value = value:gsub("%s*%(%s*owned%s*%)%s*$", "")
    value = value:gsub("%s*%(%s*equipped%s*%)%s*$", "")
    value = value:gsub("^%d+%s*[xX]%s*", "")
    value = value:gsub("%s+", " ")
    return value
end

local function IsSellCandidate(text, fromUi)
    local value = CleanSellName(text)
    if #value < 3 or #value > 40 then
        return false
    end
    if not string.find(value, "%a") then
        return false
    end
    if string.find(value, "[%$%%]") then
        return false
    end
    if string.find(value, "^[xX]%s*%d+$")
        or string.find(value, "^%d+%s*[xX]$")
    then
        return false
    end
    if string.find(value, ":", 1, true) or string.find(value, "\n", 1, true) then
        return false
    end

    local lower = string.lower(value)
    if string.find(lower, "http", 1, true) or string.find(lower, "rbxasset", 1, true) then
        return false
    end

    if StartsWithAction(value) then
        return false
    end

    -- Batu adalah item untuk penggiling, bukan item jualan. Jangan pernah
    -- mengirim batu yang sedang dipegang ke SellRequest.
    if IsStoneName(value) then
        return false
    end

    for _, blocked in ipairs(SELL_BLOCKLIST) do
        if lower == blocked then
            return false
        end
    end

    for _, blocked in ipairs(SELL_HARD_BLOCKLIST) do
        if string.find(lower, blocked, 1, true) then
            return false
        end
    end

    for _, blocked in ipairs(SELL_INTERNAL_NAMES) do
        if lower == blocked then
            return false
        end
    end

    if fromUi then
        for _, part in ipairs(SELL_UI_BLOCK_PARTS) do
            if string.find(lower, part, 1, true) then
                return false
            end
        end
    end

    return true
end

local function AddSellCandidate(names, seen, name, fromUi)
    local value = CleanSellName(name)
    if not IsSellCandidate(value, fromUi) then
        return
    end

    local key = string.lower(value)
    if seen[key] then
        return
    end

    seen[key] = true
    table.insert(names, value)
end

local function CollectSellNames()
    local names = {}
    local seen = {}

    local function add(value, fromUi)
        if type(value) == "string" then
            AddSellCandidate(names, seen, value, fromUi)
        end
    end

    local function scanAttributes(obj, fromUi)
        local ok, attributes = pcall(function()
            return obj:GetAttributes()
        end)
        if not ok or type(attributes) ~= "table" then
            return
        end

        for _, value in pairs(attributes) do
            if type(value) == "string" then
                add(value, fromUi)
            elseif type(value) == "table" then
                for _, innerValue in pairs(value) do
                    if type(innerValue) == "string" then
                        add(innerValue, fromUi)
                    end
                end
            end
        end
    end

    -- 1. Slot bar / Backpack: hanya Tool yang benar-benar ada di sana.
    for _, container in ipairs({
        LocalPlayer:FindFirstChild("Backpack"),
        LocalPlayer.Character,
    }) do
        if container then
            for _, obj in ipairs(container:GetChildren()) do
                if obj:IsA("Tool") then
                    add(obj.Name, false)
                end
            end
        end
    end

    -- 2. Data item di dalam container inventory/bag/hotbar. Tidak membaca
    -- teks tombol, jadi aksi seperti "Turunkan Batu" tidak ikut.
    local function scanInventoryData(obj, depth, inInventory, inShop)
        if not obj or depth > 6 then
            return
        end

        -- Jangan pernah membaca GUI/shop. Sumber item hanya Backpack,
        -- Character, dan container inventory/bag/hotbar di dalamnya.
        if obj:IsA("PlayerGui") or obj:IsA("ScreenGui")
            or obj:IsA("BillboardGui") or obj:IsA("SurfaceGui")
        then
            return
        end

        local lowerName = string.lower(tostring(obj.Name or ""))
        local containerNode = depth > 0 and IsSellContainer(lowerName)
        local shopNode = depth > 0 and IsShopContainer(lowerName)
        local skipNode = depth > 0 and IsSkippedUiContainer(lowerName)
        local nextShop = inShop
        local nextIn

        if depth == 0 then
            nextIn = false
        elseif shopNode and not containerNode then
            nextShop = true
            nextIn = false
        elseif inShop then
            nextIn = containerNode
            if containerNode then
                nextShop = false
            end
        else
            nextIn = inInventory or containerNode
        end

        if skipNode then
            nextIn = false
        end

        -- Atribut hanya dibaca dari container inventory itu sendiri, bukan
        -- dari metadata di dalam Tool/Model item.
        if containerNode then
            scanAttributes(obj, false)
        end

        for _, child in ipairs(obj:GetChildren()) do
            if child:IsA("Tool") then
                -- Nama Tool adalah item; isi Tool bisa berisi metadata
                -- (Description, Rarity, dsb) yang bukan item.
                if not nextShop or nextIn then
                    add(child.Name, false)
                end
            elseif child:IsA("Model") then
                if nextIn then
                    add(child.Name, false)
                end
            else
                if nextIn then
                    if child:IsA("StringValue") then
                        add(child.Value, false)
                    elseif child:IsA("ObjectValue") then
                        local target = child.Value
                        if target then
                            add(target.Name, false)
                        end
                    end
                end

                scanInventoryData(child, depth + 1, nextIn, nextShop)
            end
        end
    end

    scanInventoryData(LocalPlayer, 0, false, false)

    -- Tidak ada pemindaian teks GUI. Teks shop/tombol seperti "Turunkan Batu"
    -- atau nama item toko tidak boleh masuk ke SellRequest. Sumber item hanya
    -- Tool dan data di dalam container bag/slot bar.
    return names
end

local function FindSellRemote()
    local direct = ReplicatedStorage:FindFirstChild("SellRequest")
    if direct and (direct:IsA("RemoteEvent") or direct:IsA("RemoteFunction")) then
        return direct
    end

    for _, obj in ipairs(ReplicatedStorage:GetDescendants()) do
        if obj.Name == "SellRequest"
            and (obj:IsA("RemoteEvent") or obj:IsA("RemoteFunction"))
        then
            return obj
        end
    end

    -- Cadangan kalau namanya sedikit berbeda.
    for _, obj in ipairs(ReplicatedStorage:GetDescendants()) do
        if obj:IsA("RemoteEvent") or obj:IsA("RemoteFunction") then
            local lowerName = string.lower(obj.Name)
            if string.find(lowerName, "sell", 1, true)
                and not string.find(lowerName, "gui", 1, true)
                and not string.find(lowerName, "button", 1, true)
            then
                return obj
            end
        end
    end

    return nil
end

local function FireSellFor(remote, itemName)
    if remote:IsA("RemoteFunction") then
        return (pcall(function()
            remote:InvokeServer("sellItem", itemName)
        end))
    end

    return (pcall(function()
        remote:FireServer("sellItem", itemName)
    end))
end

local function UpdateSellItemLabel(names)
    if not sellItemsLabel then
        return
    end

    local total = #names
    if total == 0 then
        sellItemsLabel:Set(autoSellOn
            and "Bag/slot bar kosong. Auto Sell berhenti dan menunggu item masuk."
            or "Bag/slot bar kosong.")
        return
    end

    local shown = {}
    for index = 1, math.min(total, 12) do
        shown[index] = names[index]
    end

    sellItemsLabel:Set(string.format(
        "Terbaca %d item di bag/slot bar: %s%s",
        total,
        table.concat(shown, ", "),
        total > 12 and ", ..." or ""
    ))
end

local function StartSellBatch(manual, preNames)
    if sellBusy then
        return false, "sedang menjual item"
    end
    if autoBusy or instantBusy or placeBusy or placePrepBusy then
        return false, "fitur lain sedang berjalan"
    end

    local names = preNames or CollectSellNames()
    UpdateSellItemLabel(names)

    if #names == 0 then
        sellWaiting = autoSellOn
        if sellStatusLabel then
            sellStatusLabel:Set(autoSellOn
                and "Auto Sell: bag/slot bar kosong - berhenti, menunggu item..."
                or "Auto Sell: bag/slot bar kosong.")
        end
        return false, "kosong"
    end

    sellWaiting = false

    local remote = FindSellRemote()
    if not remote then
        if sellStatusLabel then
            sellStatusLabel:Set("Auto Sell: SellRequest tidak ditemukan di ReplicatedStorage.")
        end
        return false, "SellRequest tidak ditemukan"
    end

    local total = #names
    if total > SELL_MAX_ITEMS then
        for index = total, SELL_MAX_ITEMS + 1, -1 do
            names[index] = nil
        end
    end

    sellBusy = true

    if sellStatusLabel then
        sellStatusLabel:Set(string.format(
            "Auto Sell: menjual %d item dari bag/slot bar...",
            #names
        ))
    end

    task.spawn(function()
        local sent = 0

        for _, itemName in ipairs(names) do
            if not running then
                break
            end

            if FireSellFor(remote, itemName) then
                sent = sent + 1
            end

            task.wait(SELL_STEP_DELAY)
        end

        sellBusy = false

        if not running then
            return
        end

        local capText = ""
        if total > #names then
            capText = string.format(" (dibatasi %d dari %d terbaca)", #names, total)
        end

        -- Beri server waktu menghapus item sebelum membandingkan hasil.
        task.wait(0.45)
        local remaining = CollectSellNames()
        UpdateSellItemLabel(remaining)

        local beforeNames = {}
        local remainingNames = {}
        for _, name in ipairs(names) do
            beforeNames[string.lower(name)] = true
        end
        for _, name in ipairs(remaining) do
            remainingNames[string.lower(name)] = true
        end
        local removedAny = false
        for lowerName in pairs(beforeNames) do
            if not remainingNames[lowerName] then
                removedAny = true
                break
            end
        end

        if sent > 0 and not removedAny then
            sellFailStreak = sellFailStreak + 1
        elseif removedAny then
            sellFailStreak = 0
        end

        if #remaining == 0 then
            sellWaiting = autoSellOn
            sellNextAt = 0
            if sellStatusLabel then
                sellStatusLabel:Set(autoSellOn
                    and "Auto Sell: bag/slot bar kosong - berhenti, menunggu item..."
                    or "Auto Sell: bag/slot bar kosong.")
            end
        else
            sellNextAt = os.time()
                + math.max(1, tonumber(autoSellInterval) or SELL_INTERVAL_DEFAULT)
            if sellStatusLabel then
                if sent > 0 and not removedAny then
                    sellStatusLabel:Set(string.format(
                        "Auto Sell: %d item terkirim, inventory belum berubah. Tetap menunggu.%s",
                        sent,
                        capText
                    ))
                else
                    sellStatusLabel:Set(string.format(
                        "Auto Sell: %d item bag/slot bar dikirim%s.",
                        sent,
                        capText
                    ))
                end
            end
        end

        if manual then
            pcall(function()
                UI:Notify({
                    Title = "Auto Sell",
                    Content = string.format("%d item dikirim.", sent),
                    Icon = "coins",
                    Type = sent > 0 and "Success" or "Warning",
                    Duration = 3,
                })
            end)
        end
    end)

    return true
end

local function SellAllNow()
    if sellBusy then
        pcall(function()
            UI:Notify({
                Title = "Auto Sell",
                Content = "Sedang menjual item. Tunggu sebentar.",
                Icon = "clock",
                Type = "Info",
                Duration = 2,
            })
        end)
        return
    end

    if autoBusy or instantBusy or placeBusy or placePrepBusy then
        pcall(function()
            UI:Notify({
                Title = "Auto Sell",
                Content = "Fitur lain sedang berjalan. Tunggu sampai selesai.",
                Icon = "clock",
                Type = "Info",
                Duration = 2,
            })
        end)
        return
    end

    local ok, err = StartSellBatch(true)
    if not ok then
        pcall(function()
            if err == "kosong" then
                UI:Notify({
                    Title = "Auto Sell",
                    Content = "Bag/slot bar kosong. Menunggu item masuk.",
                    Icon = "clock",
                    Type = "Info",
                    Duration = 3,
                })
            else
                UI:Notify({
                    Title = "Auto Sell gagal",
                    Content = tostring(err),
                    Icon = "triangle-alert",
                    Type = "Warning",
                    Duration = 3,
                })
            end
        end)
    end
end

local function RefreshSellCandidates()
    local names = CollectSellNames()
    UpdateSellItemLabel(names)

    if #names == 0 then
        sellWaiting = autoSellOn
        if sellStatusLabel then
            sellStatusLabel:Set(autoSellOn
                and "Auto Sell: bag/slot bar kosong - berhenti, menunggu item..."
                or "Auto Sell: bag/slot bar kosong.")
        end
        return
    end

    sellWaiting = false
    if sellStatusLabel then
        sellStatusLabel:Set(string.format(
            "Auto Sell: %d item ada di bag/slot bar.",
            #names
        ))
    end
end

local function HandleAutoSell()
    if not autoSellOn or sellBusy then
        return false
    end
    if os.time() < sellNextAt then
        return false
    end

    local names = CollectSellNames()
    if #names == 0 then
        if not sellWaiting then
            sellWaiting = true
            UpdateSellItemLabel(names)
            if sellStatusLabel then
                sellStatusLabel:Set(
                    "Auto Sell: bag/slot bar kosong - berhenti, menunggu item..."
                )
            end
        end

        -- Cek ringan tiap detik; tidak ada item yang dikirim saat kosong.
        sellNextAt = os.time() + 1
        return false
    end

    sellWaiting = false
    sellNextAt = os.time() + math.max(1, tonumber(autoSellInterval) or SELL_INTERVAL_DEFAULT)
    return StartSellBatch(false, names)
end


-- =====================================================================
-- 2e. AUTO INSTANT STEAL, PRIORITY & SCHEDULER
-- =====================================================================
local function AnyAutomationBusy()
    return autoBusy or instantBusy or placeBusy or placePrepBusy or sellBusy
end

-- Auto Steal dan Auto Instant Steal memakai satu slot yang sama. Mengaktifkan
-- salah satunya akan mematikan mode lainnya lewat toggle yang sama.
local function SetStealMode(mode)
    autoStealOn = mode == "normal"
    instantStealOn = mode == "instant"

    if AutoStealToggle then
        AutoStealToggle:Set(autoStealOn, true)
    end
    if InstantStealToggle then
        InstantStealToggle:Set(instantStealOn, true)
    end

    if mode == "normal" then
        autoCooldown = {}
    elseif mode == "instant" then
        instantAttempted = {}
    end
end

local function DisableInstantSteal(reason)
    instantStealOn = false
    if InstantStealToggle then
        -- Jangan silent: biarkan Auto Save ikut menyimpan toggle yang mati.
        InstantStealToggle:Set(false)
    end
    if instantStatusLabel then
        instantStatusLabel:Set(reason or "Auto Instant Steal: nonaktif.")
    end
end

local function NormalizeStealModes()
    if autoStealOn and instantStealOn then
        DisableInstantSteal("Auto Instant Steal: nonaktif (Auto Steal diprioritaskan).")
    end
end

-- Instant Steal menyalin cara kerja Auto Steal: TP bawah batu mengikuti
-- jarak/kedalaman Auto TP, spam prompt, lalu kembali ke posisi aman.
local function RunInstantStealCore(candidates)
    if type(fireproximityprompt) ~= "function" then
        DisableInstantSteal("Auto Instant Steal: fireproximityprompt tidak tersedia.")
        return
    end

    table.sort(candidates, function(a, b)
        if a.score ~= b.score then
            return a.score > b.score
        end
        return a.distance < b.distance
    end)

    local deadline = os.time() + INSTANT_STEAL_TIMEOUT
    local success = 0
    local failures = 0
    local lastRarity = nil
    -- Instant mengikuti Auto TP universal. Kalau Auto TP dimatikan atau Ghost
    -- mode aktif, prompt tetap ditembak dari posisi sekarang (jarak jauh).
    local teleport = autoStealTeleport ~= false and not ghostActive

    for _, target in ipairs(candidates) do
        if not running or not instantStealOn or smartSafeMode
            or os.time() >= deadline
        then
            break
        end

        if FindHeldStone and FindHeldStone() then
            if instantStatusLabel then
                instantStatusLabel:Set("Auto Instant Steal: skip - sedang memegang batu.")
            end
            break
        end

        local stone, prompt = target.stone, target.prompt
        local cooldown = instantAttempted[stone]
        if IsTargetValid(stone, prompt)
            and (not cooldown or os.time() >= cooldown)
        then
            -- Jangan tandai permanen; server bisa menerima di putaran berikutnya.
            instantAttempted[stone] = os.time() + INSTANT_STEAL_RETRY_COOLDOWN
            lastRarity = target.rarity

            if instantStatusLabel then
                instantStatusLabel:Set(string.format(
                    "Auto Instant Steal: mengejar [%s]%s...",
                    tostring(target.rarity),
                    teleport and " (TP)" or " (tanpa TP)"
                ))
            end

            local gone = false
            local cycle = 0
            for _ = 1, INSTANT_STEAL_ATTEMPTS do
                if not IsTargetValid(stone, prompt) then
                    gone = true
                    break
                end

                if teleport then
                    cycle = cycle + 1
                    if not StealUtil.TeleportNearStone(stone, prompt, cycle) then
                        break
                    end
                    task.wait(AUTO_STEAL_TP_SETTLE)
                end

                StealUtil.SpamPrompt(
                    prompt,
                    teleport and AUTO_STEAL_SHOTS or 1,
                    teleport and AUTO_STEAL_SHOT_DELAY or INSTANT_STEAL_STEP_DELAY
                )

                if not IsTargetValid(stone, prompt) then
                    gone = true
                    break
                end
                if FindHeldStone and FindHeldStone() then
                    gone = true
                    break
                end
            end

            if gone then
                success = success + 1
                failures = 0
            else
                failures = failures + 1
            end

            if failures >= INSTANT_STEAL_MAX_FAILS then
                break
            end
        end
    end

    if not instantStealOn then
        return success
    end

    if instantStatusLabel and not smartSafeMode then
        if success > 0 then
            instantStatusLabel:Set(string.format(
                "Auto Instant Steal: %d batu berhasil (terakhir: %s).",
                success,
                tostring(lastRarity or "-")
            ))
        elseif failures > 0 then
            instantStatusLabel:Set(string.format(
                "Auto Instant Steal: %d percobaan, belum ada yang berhasil.",
                failures
            ))
        else
            instantStatusLabel:Set("Auto Instant Steal: menunggu batu baru...")
        end
    end

    return success
end

local function RunInstantSteal(candidates)
    local useHold = autoStealTeleport ~= false and not ghostActive
    if useHold and not StealthHold.Begin() then
        if instantStatusLabel and not smartSafeMode then
            instantStatusLabel:Set("Auto Instant Steal: anti-void tidak bisa aktif.")
        end
        return
    end

    local ok, result = pcall(RunInstantStealCore, candidates)
    local keepUnderground = false

    if ok and (tonumber(result) or 0) > 0 then
        task.wait(0.12)
        local held = FindHeldStone and FindHeldStone() or nil
        if not held then
            for _ = 1, 4 do
                task.wait(0.2)
                held = FindHeldStone and FindHeldStone() or nil
                if held then
                    break
                end
            end
        end
        keepUnderground = held ~= nil
    end

    if useHold and not keepUnderground then
        StealthHold.End()
    elseif keepUnderground and instantStatusLabel and not smartSafeMode then
        instantStatusLabel:Set("Auto Instant Steal: batu didapat - tetap di bawah tanah, menunggu Auto Place.")
    end

    if not ok then
        error(result, 0)
    end
end

local function TryStartAutoSteal(candidates, origin)
    if not autoStealOn or instantStealOn or smartSafeMode then
        return false
    end
    if AnyAutomationBusy() then
        return false
    end
    if not origin or #candidates == 0 then
        return false
    end

    if FindHeldStone and FindHeldStone() then
        if StatusLabel then
            StatusLabel:Set("Status: Auto Steal skip - sedang memegang batu.")
        end
        return false
    end

    table.sort(candidates, function(a, b)
        if a.score ~= b.score then
            return a.score > b.score
        end
        return a.distance < b.distance
    end)

    -- Tanpa TP, prompt hanya dibatasi kalau Paksa Jarak mati. Dengan Paksa
    -- Jarak, semua batu di map boleh dipilih dan ditembak dari home/base.
    local noTeleport = autoStealTeleport == false or ghostActive
    local reachable = forcePromptRange and math.huge or (PROMPT_MAX_DISTANCE - 0.25)

    local target = nil
    for _, candidate in ipairs(candidates) do
        local cooldown = autoCooldown[candidate.stone]
        local inRange = true

        if noTeleport then
            -- Tidak ada validasi jarak di game ini. Semua batu di map boleh
            -- ditembak dari home/spawn tanpa perlu mendekat sama sekali.
            inRange = true
        end

        if inRange and (not cooldown or os.time() >= cooldown) then
            target = candidate
            break
        end
    end

    if not target then
        if noTeleport and StatusLabel then
            if forcePromptRange then
                StatusLabel:Set("Status: Auto Steal tanpa TP - belum ada batu aktif yang cocok.")
            else
                StatusLabel:Set(string.format(
                    "Status: Auto Steal tanpa TP - tidak ada batu dalam %d stud. Aktifkan Paksa Jarak atau Auto TP.",
                    math.floor(reachable)
                ))
            end
        end
        return false
    end

    autoBusy = true

    if StatusLabel then
        StatusLabel:Set(string.format(
            "Status: Auto Steal loop%s -> [%s] %.0f stud",
            autoStealTeleport ~= false and " (TP)" or " (tanpa TP)",
            tostring(target.rarity),
            tonumber(target.distance) or 0
        ))
    end

    task.spawn(function()
        local ok, err = pcall(RunAutoSteal, target)
        autoBusy = false
        if not ok and StatusLabel then
            StatusLabel:Set("Status: Auto Steal error - " .. tostring(err))
        end
    end)

    return true
end

local function TryStartInstantSteal(candidates)
    if not instantStealOn or autoStealOn or smartSafeMode then
        return false
    end
    if AnyAutomationBusy() then
        return false
    end
    if #candidates == 0 then
        return false
    end

    if FindHeldStone and FindHeldStone() then
        if instantStatusLabel then
            instantStatusLabel:Set("Auto Instant Steal: skip - sedang memegang batu.")
        end
        return false
    end

    instantBusy = true
    task.spawn(function()
        local ok, err = pcall(RunInstantSteal, candidates)
        instantBusy = false
        if not ok and instantStatusLabel then
            instantStatusLabel:Set("Auto Instant Steal error - " .. tostring(err))
        end
    end)

    return true
end

-- Hanya satu aksi otomasi yang boleh mulai per giliran. Urutan dari section
-- Priority menentukan fitur mana yang dicoba lebih dulu.
local function RunAutomationScheduler(candidates, grinderStates, origin)
    if not running then
        return
    end

    NormalizeStealModes()

    -- Smart mode: saat ada pemain lain, jangan sentuh batu atau penggiling.
    -- Auto Sell tetap boleh jalan karena tidak memindahkan karakter.
    if smartSafeMode then
        if autoSellOn and not AnyAutomationBusy() and os.time() >= sellNextAt then
            HandleAutoSell()
        end
        return
    end

    if AnyAutomationBusy() then
        return
    end

    -- Jangan biarkan karakter tertahan di bawah tanah kalau Auto Place mati,
    -- atau kalau batu ternyata sudah tidak dipegang.
    if StealthHold.active then
        local held = FindHeldStone and FindHeldStone() or nil
        if not held or not autoPlaceOn then
            pcall(StealthHold.End)
        end
    end

    -- Auto Sell punya jadwal sendiri. Tanpa ini, prioritas Steal > Place > Sell
    -- membuat Auto Sell tidak pernah kebagian giliran saat batu terus muncul.
    if autoSellOn and os.time() >= sellNextAt then
        if HandleAutoSell() then
            return
        end
    end

    local order = featurePriority or PRIORITY_MAP["Steal > Place > Sell"]
    for _, feature in ipairs(order) do
        if feature == "steal" then
            if autoStealOn then
                if TryStartAutoSteal(candidates or {}, origin) then
                    return
                end
            elseif instantStealOn then
                if TryStartInstantSteal(candidates or {}) then
                    return
                end
            end
        elseif feature == "place" then
            if HandleAutoPlace(grinderStates or {}) then
                return
            end
        elseif feature == "sell" then
            if HandleAutoSell() then
                return
            end
        end
    end
end


-- =====================================================================
-- 2f. ANTI-AFK & 3D RENDER
-- =====================================================================
local function UpdateAntiAfkStatus()
    if not antiAfkStatusLabel then
        return
    end

    if antiAfkOn then
        antiAfkStatusLabel:Set(string.format(
            "Anti-AFK: aktif | interval %ds | pulse %d | Idled %d | metode: %s",
            math.floor(antiAfkInterval + 0.5),
            antiAfkPulses,
            antiAfkIdledCount,
            tostring(antiAfkLastMethod)
        ))
    else
        antiAfkStatusLabel:Set(string.format(
            "Anti-AFK: nonaktif | pulse %d | metode terakhir: %s",
            antiAfkPulses,
            tostring(antiAfkLastMethod)
        ))
    end
end

local function AntiAfkPulse(source)
    local method = nil

    -- 1. VirtualUser adalah metode paling umum di executor. Coba beberapa
    -- signature karena ada executor yang tidak menerima parameter camera.
    local virtualUser = nil
    pcall(function()
        virtualUser = game:GetService("VirtualUser")
    end)

    if virtualUser then
        local captured = pcall(function()
            virtualUser:CaptureController()
        end)

        if captured then
            local camera = Workspace.CurrentCamera
            local clicked = pcall(function()
                virtualUser:ClickButton2(Vector2.new(0, 0))
            end)

            if not clicked and camera then
                clicked = pcall(function()
                    virtualUser:ClickButton2(Vector2.new(0, 0), camera.CFrame)
                end)
            end

            if clicked then
                method = "VirtualUser"
            else
                local held = pcall(function()
                    local cameraCFrame = camera and camera.CFrame or CFrame.new()
                    virtualUser:Button2Down(Vector2.new(0, 0), cameraCFrame)
                    task.wait(0.05)
                    virtualUser:Button2Up(Vector2.new(0, 0), cameraCFrame)
                end)
                if held then
                    method = "VirtualUserButton2"
                end
            end
        end
    end

    -- 2. Executor yang menyediakan keypress/keyrelease.
    if not method and type(keypress) == "function" then
        local pressed = pcall(function()
            keypress(Enum.KeyCode.Space)
            task.wait(0.05)
            if type(keyrelease) == "function" then
                keyrelease(Enum.KeyCode.Space)
            end
        end)
        if pressed then
            method = "keypress"
        end
    end

    -- 3. VirtualInputManager untuk client yang mengizinkannya.
    if not method then
        local inputManager = nil
        pcall(function()
            inputManager = game:FindService("VirtualInputManager")
        end)
        if inputManager then
            local sent = pcall(function()
                inputManager:SendKeyEvent(true, Enum.KeyCode.Space, false, game)
                task.wait(0.05)
                inputManager:SendKeyEvent(false, Enum.KeyCode.Space, false, game)
            end)
            if sent then
                method = "VirtualInputManager"
            end
        end
    end

    -- 4. Mouse virtual. Beberapa executor hanya punya API ini.
    if not method and type(mousemoverel) == "function" then
        local moved = pcall(function()
            mousemoverel(1, 0)
            task.wait(0.03)
            mousemoverel(-1, 0)
        end)
        if moved then
            method = "mousemoverel"
        end
    end

    -- 5. Cadangan terakhir: gerakan humanoid. Hanya kalau karakter tidak
    -- sedang di-anchor, supaya tidak merusak anti-void/ghost mode.
    if not method and not ghostActive then
        local character = LocalPlayer.Character
        local humanoid = character and character:FindFirstChildOfClass("Humanoid")
        local root = character and character:FindFirstChild("HumanoidRootPart")
        if humanoid and root and not root.Anchored then
            local moved = pcall(function()
                humanoid.Jump = true
                humanoid:ChangeState(Enum.HumanoidStateType.Jumping)
            end)
            if moved then
                method = "jump"
            end
        end
    end

    if method then
        antiAfkPulses = antiAfkPulses + 1
    end
    antiAfkLastMethod = method or (source or "none")
    UpdateAntiAfkStatus()
    return method ~= nil
end

local function SetAntiAfk(enabled)
    antiAfkOn = enabled == true
    antiAfkGeneration = antiAfkGeneration + 1

    if antiAfkConnection then
        antiAfkConnection:Disconnect()
        antiAfkConnection = nil
    end

    if not antiAfkOn then
        UpdateAntiAfkStatus()
        return
    end

    antiAfkConnection = LocalPlayer.Idled:Connect(function()
        if antiAfkOn and running then
            antiAfkIdledCount = antiAfkIdledCount + 1
            AntiAfkPulse("Idled")
        end
    end)

    local generation = antiAfkGeneration
    task.spawn(function()
        task.wait(0.5)
        while running and antiAfkOn and antiAfkGeneration == generation do
            AntiAfkPulse("timer")

            local waited = 0
            local interval = math.clamp(tonumber(antiAfkInterval) or ANTI_AFK_INTERVAL_DEFAULT, 15, 120)
            while running and antiAfkOn
                and antiAfkGeneration == generation and waited < interval
            do
                task.wait(1)
                waited = waited + 1
            end
        end
    end)

    UpdateAntiAfkStatus()
end

-- =====================================================================
-- 2g. SMART AUTO STEAL (AFK DI BASE SAAT ADA PEMAIN LAIN)
-- =====================================================================
local function CountOtherPlayers()
    local count = 0
    local firstName = nil

    for _, player in ipairs(Players:GetPlayers()) do
        if player ~= LocalPlayer then
            count = count + 1
            if not firstName then
                firstName = player.Name
            end
        end
    end

    return count, firstName
end

local function SetSmartStatus(text)
    if smartStatusLabel and smartLastStatus ~= text then
        smartStatusLabel:Set(text)
        smartLastStatus = text
    end
end

local function GoHomeForSmartMode()
    if smartHomeBusy then
        return
    end

    smartHomeBusy = true
    smartHomeDone = false
    smartNextHomeAt = os.time() + SMART_HOME_RETRY

    task.spawn(function()
        -- Biarkan Auto Steal/Place yang sedang berjalan selesai dulu supaya
        -- CFrame tidak saling menimpa.
        local waitUntil = os.time() + 3
        while running and AnyAutomationBusy() and os.time() < waitUntil do
            task.wait(0.1)
        end

        if not running or not smartAutoStealOn then
            smartHomeBusy = false
            return
        end

        -- Pastikan anti-void tidak menahan karakter saat TP pulang.
        pcall(StealthHold.End)
        pcall(function()
            SafeSellAnchor.Release()
        end)

        local function TryTravelHome()
            local before = GetCharacterRoot()
            local beforePosition = before and before.Position or nil

            if TravelHome() then
                local after = GetCharacterRoot()
                if not beforePosition or not after
                    or (after.Position - beforePosition).Magnitude >= 4
                then
                    return true
                end
            end

            -- Home belum dikenal: pakai tombol Home / marker dulu.
            if not homePosition then
                EnsureHomeReady()
            end

            if homePosition then
                local root = GetCharacterRoot()
                if root then
                    pcall(function()
                        root.CFrame = CFrame.new(homePosition + Vector3.new(0, 3, 0))
                        root.AssemblyLinearVelocity = Vector3.zero
                        root.AssemblyAngularVelocity = Vector3.zero
                    end)
                    return true
                end
            end

            return false
        end

        local callOk, traveled = pcall(TryTravelHome)
        local ok = callOk and traveled == true

        -- Tombol Home tidak tersedia: pakai titik home yang tersimpan.
        if not ok and homePosition then
            local root = GetCharacterRoot()
            if root then
                ok = pcall(function()
                    root.CFrame = CFrame.new(homePosition + Vector3.new(0, 3, 0))
                    root.AssemblyLinearVelocity = Vector3.zero
                    root.AssemblyAngularVelocity = Vector3.zero
                end)
            end
        end

        smartHomeBusy = false

        if not running then
            return
        end

        smartHomeDone = ok == true
        if not smartHomeDone then
            smartNextHomeAt = os.time() + 5
        end
    end)
end

local function UpdateSmartProtection()
    if not smartAutoStealOn then
        if smartSafeMode then
            smartSafeMode = false
            smartHomeDone = false
            smartNextHomeAt = 0
            smartNextAntiAfkAt = 0
        end
        SetSmartStatus("Smart: nonaktif.")
        return
    end

    local otherCount, otherName = CountOtherPlayers()
    smartOtherCount = otherCount
    smartOtherName = otherName

    if otherCount > 0 then
        if not smartSafeMode then
            smartSafeMode = true
            smartHomeDone = false
            smartNextHomeAt = 0
            smartNextAntiAfkAt = 0
            smartLastStatus = nil
        end

        local root = GetCharacterRoot()
        if smartHomeDone and homePosition and root
            and (root.Position - homePosition).Magnitude > HOME_TRAVEL_DISTANCE
        then
            smartHomeDone = false
            smartNextHomeAt = 0
        end

        if not smartHomeDone and not smartHomeBusy
            and os.time() >= smartNextHomeAt
        then
            GoHomeForSmartMode()
        end

        if os.time() >= smartNextAntiAfkAt then
            AntiAfkPulse()
            smartNextAntiAfkAt = os.time() + SMART_AFK_PULSE_INTERVAL
        end

        local who = otherName and (" (" .. tostring(otherName) .. ")") or ""
        if smartHomeDone then
            SetSmartStatus(string.format(
                "Smart: %d pemain lain%s - AFK di base, anti-AFK aktif.",
                otherCount,
                who
            ))
        else
            SetSmartStatus(string.format(
                "Smart: %d pemain lain%s - menuju base...",
                otherCount,
                who
            ))
        end
    else
        if smartSafeMode then
            smartSafeMode = false
            smartHomeDone = false
            smartNextHomeAt = 0
            smartNextAntiAfkAt = 0
            smartLastStatus = nil
        end
        SetSmartStatus("Smart: hanya kamu di server - fitur berjalan normal.")
    end
end

local function Set3dRenderDisabled(disabled)
    disable3dRender = disabled == true

    local ok = pcall(function()
        RunService:Set3dRenderingEnabled(not disable3dRender)
    end)
    if ok then
        return
    end

    local fallbackOk = pcall(function()
        settings().Rendering.QualityLevel = disable3dRender and 1 or 21
    end)

    pcall(function()
        UI:Notify({
            Title = "Disable 3D Render",
            Content = fallbackOk
                and "Executor tidak mendukung Set3dRenderingEnabled; kualitas grafis diturunkan."
                or "Executor tidak mendukung Set3dRenderingEnabled.",
            Icon = "triangle-alert",
            Type = "Warning",
            Duration = 5,
        })
    end)
end

local function CleanupPerformanceSettings()
    pcall(ExitGhostMode)
    pcall(SafeSellAnchor.Release)
    pcall(StealthHold.End)
    RestorePromptRanges()
    smartSafeMode = false
    smartHomeBusy = false
    smartHomeDone = false
    antiAfkOn = false
    antiAfkGeneration = antiAfkGeneration + 1

    if antiAfkConnection then
        antiAfkConnection:Disconnect()
        antiAfkConnection = nil
    end

    if disable3dRender then
        disable3dRender = false
        pcall(function()
            RunService:Set3dRenderingEnabled(true)
        end)
    end
end


-- =====================================================================
-- 3. UI FLUENT-PRO
-- =====================================================================
local function BuildUi()
local function BuildUiBridge(lib)
    local bridge = { Fluent = lib }
    local currentWindow = nil
    local flagCounter = 0
    local usedFlags = {}

    local function resolveFlag(name, explicit)
        local flag = explicit
        if flag == nil or flag == "" then
            local base = string.lower(tostring(name or "flag"))
            base = base:gsub("[^%w]+", "_"):gsub("^_+", ""):gsub("_+$", "")
            if base == "" then
                base = "flag"
            end
            flag = "ui_" .. base
        end

        local unique = flag
        local suffix = 2
        while usedFlags[unique] do
            unique = flag .. "_" .. tostring(suffix)
            suffix = suffix + 1
        end
        usedFlags[unique] = true
        return unique
    end

    local function normalizeSelection(value)
        local out = {}
        if type(value) ~= "table" then
            return out
        end

        for key, item in pairs(value) do
            if type(key) == "number" then
                if type(item) == "string" then
                    table.insert(out, item)
                end
            elseif item == true then
                table.insert(out, tostring(key))
            end
        end

        return out
    end

    local function selectionMap(value)
        local map = {}
        if type(value) == "string" then
            map[value] = true
            return map
        end
        if type(value) ~= "table" then
            return map
        end

        for key, item in pairs(value) do
            if type(key) == "number" then
                if type(item) == "string" then
                    map[item] = true
                end
            elseif item == true then
                map[tostring(key)] = true
            end
        end

        return map
    end

    local function wrapBase(element)
        local wrapper = {
            _element = element,
            Frame = element and element.Frame,
        }

        function wrapper:SetTitle(text)
            local value = tostring(text or "")
            if element and element.TitleLabel and element.TitleLabel.Text == value then
                return
            end
            if element and type(element.SetTitle) == "function" then
                element:SetTitle(value)
            end
        end

        function wrapper:SetDesc(text)
            local value = tostring(text or "")
            if element and element.DescLabel and element.DescLabel.Text == value then
                return
            end
            if element and type(element.SetDesc) == "function" then
                element:SetDesc(value)
            end
        end

        function wrapper:Set(text)
            self:SetDesc(text)
        end

        function wrapper:Get()
            return element and element.Value
        end

        function wrapper:SetVisible(visible)
            if element and element.Frame then
                element.Frame.Visible = visible == true
            end
        end

        function wrapper:Destroy()
            if element and type(element.Destroy) == "function" then
                pcall(function()
                    element:Destroy()
                end)
            end
        end

        return wrapper
    end

    local ContainerApi = {}

    local function newContainer(target)
        return setmetatable({ _target = target }, { __index = ContainerApi })
    end

    function ContainerApi:Set(text)
        local target = self._target
        if target and type(target.SetTitle) == "function" then
            target:SetTitle(tostring(text or ""))
        end
    end

    local function HideEmptyOverlay(target)
        -- Fluent 1.6 menampilkan "This tab is empty" kalau ContainerFrame
        -- dianggap belum punya child Frame. Section kadang sudah ada tetapi
        -- overlay ini tetap muncul. Sembunyikan setiap kali section dibuat.
        if target and target._emptyOverlay then
            target._emptyOverlay.Visible = false
        end
    end

    function ContainerApi:CreateSection(title, icon)
        local section = self._target:AddSection(tostring(title or "Section"), icon)
        HideEmptyOverlay(self._target)
        return newContainer(section)
    end

    function ContainerApi:CreateCollapsibleSection(title, icon, open)
        local section = self._target:AddCollapsibleSection(
            tostring(title or "Section"),
            icon,
            open ~= false
        )
        HideEmptyOverlay(self._target)
        return newContainer(section)
    end

    function ContainerApi:CreateToggle(config)
        config = config or {}
        local flag = resolveFlag(config.Name, config.Flag)
        local suppress = false
        local element

        element = self._target:AddToggle(flag, {
            Title = tostring(config.Name or config.Title or "Toggle"),
            Description = config.Desc,
            Default = config.CurrentValue == true,
            Icon = config.Icon,
            Callback = function(value)
                if suppress then
                    return
                end
                if config.Callback then
                    config.Callback(value)
                end
            end,
        })

        local wrapper = wrapBase(element)

        function wrapper:Set(value, silent)
            suppress = silent == true
            element:SetValue(value == true)
            suppress = false
        end

        function wrapper:Get()
            return element.Value == true
        end

        return wrapper
    end

    function ContainerApi:CreateDropdown(config)
        config = config or {}
        local multi = config.MultipleOptions == true
        local flag = resolveFlag(config.Name, config.Flag)
        local suppress = false
        local default = config.CurrentOption

        if multi then
            default = selectionMap(default)
        end

        local element = self._target:AddDropdown(flag, {
            Title = tostring(config.Name or config.Title or "Dropdown"),
            Description = config.Desc,
            Values = config.Options or {},
            Default = default,
            Multi = multi,
            DropdownOutsideWindow = true,
            Callback = function(value)
                if suppress then
                    return
                end
                if config.Callback then
                    if multi then
                        config.Callback(normalizeSelection(value))
                    else
                        config.Callback(value)
                    end
                end
            end,
        })

        local wrapper = wrapBase(element)

        function wrapper:Get()
            if multi then
                return normalizeSelection(element.Value)
            end
            return element.Value
        end

        function wrapper:Set(value, silent)
            suppress = silent == true
            element:SetValue(multi and selectionMap(value) or value)
            suppress = false
        end

        function wrapper:Refresh(values, preserve)
            element:SetValues(values or {})
            if preserve ~= true then
                return
            end

            local current = self:Get()
            if multi then
                if #current > 0 then
                    suppress = true
                    element:SetValue(selectionMap(current))
                    suppress = false
                end
            elseif current ~= nil then
                suppress = true
                element:SetValue(current)
                suppress = false
            end
        end

        return wrapper
    end

    function ContainerApi:CreateSlider(config)
        config = config or {}
        local range = config.Range or { 0, 100 }
        local increment = tonumber(config.Increment) or 1
        local decimalText = tostring(increment):match("%.(%d+)")
        local rounding = decimalText and #decimalText or 0
        local flag = resolveFlag(config.Name, config.Flag)

        local element = self._target:AddSlider(flag, {
            Title = tostring(config.Name or config.Title or "Slider"),
            Description = config.Desc,
            Min = tonumber(range[1]) or 0,
            Max = tonumber(range[2]) or 100,
            Default = tonumber(config.CurrentValue) or tonumber(range[1]) or 0,
            Rounding = rounding,
            Icon = config.Icon,
            Callback = function(value)
                if config.Callback then
                    config.Callback(value)
                end
            end,
        })

        local wrapper = wrapBase(element)

        function wrapper:Set(value)
            element:SetValue(value)
        end

        function wrapper:Get()
            return element.Value
        end

        return wrapper
    end

    function ContainerApi:CreateButton(config)
        config = config or {}
        local element = self._target:AddButton({
            Title = tostring(config.Name or config.Title or "Button"),
            Description = config.Desc,
            Icon = config.Icon,
            Callback = config.Callback,
        })
        return wrapBase(element)
    end

    function ContainerApi:CreateLabel(text)
        local element = self._target:AddParagraph({
            Title = "",
            Content = tostring(text or ""),
        })
        if element and element.TitleLabel then
            element.TitleLabel.Visible = false
        end
        return wrapBase(element)
    end

    function ContainerApi:CreateParagraph(config)
        config = config or {}
        local element = self._target:AddParagraph({
            Title = tostring(config.Title or ""),
            Content = tostring(config.Content or ""),
        })
        return wrapBase(element)
    end

    function bridge:CreateWindow(config)
        config = config or {}
        local window = lib:CreateWindow({
            Title = tostring(config.Name or "Myshi Hub"),
            SubTitle = tostring(config.LoadingSubtitle or ""),
            TabWidth = 92,
            Acrylic = false,
            Animated = false,
            Size = config.Size or UDim2.fromOffset(560, 400),
            Theme = "Charcoal",
            MinimizeKey = Enum.KeyCode.RightControl,
            ScreenGuiName = "MyshiHub",
            Search = false,
        })

        -- Theme gelap saja masih bisa terlihat putih karena frame background
        -- Fluent memakai transparansi element. Paksa opaque dan gelap.
        if window.AcrylicPaint and window.AcrylicPaint.Frame then
            local background = window.AcrylicPaint.Frame
            background.BackgroundColor3 = Color3.fromRGB(14, 14, 18)
            background.BackgroundTransparency = 0
        end

        currentWindow = window
        local api = newContainer(window)

        -- Tombol X milik Fluent menutup UI tanpa mematikan loop script. Patch
        -- destroy supaya radar dan fitur performa ikut berhenti.
        local originalDestroy = lib.Destroy
        if type(originalDestroy) == "function" then
            lib.Destroy = function(self, ...)
                if bridge.BeforeDestroy then
                    pcall(bridge.BeforeDestroy)
                end
                running = false
                _G.DoubleStealActive = false
                pcall(CleanupPerformanceSettings)
                if _G.DoubleStealWindow == api then
                    _G.DoubleStealWindow = nil
                end
                return originalDestroy(self, ...)
            end
        end

        function api:CreateTab(tabConfig)
            tabConfig = tabConfig or {}
            local tab = window:AddTab({
                Title = tostring(tabConfig.Name or tabConfig.Title or "Tab"),
                Icon = tabConfig.Icon,
            })
            return newContainer(tab)
        end

        function api:IsOpen()
            return window.Root ~= nil
                and window.Root.Visible == true
                and window.Minimized ~= true
        end

        function api:Destroy()
            local ok = pcall(function()
                lib:Destroy()
            end)
            if not ok then
                pcall(function()
                    window:Destroy()
                end)
            end
        end

        return api
    end

    function bridge:Notify(config)
        config = config or {}
        pcall(function()
            lib:Notify({
                Title = tostring(config.Title or "Myshi Hub"),
                Content = tostring(config.Content or ""),
                SubContent = config.SubContent,
                Type = config.Type,
                Icon = config.Icon,
                Duration = tonumber(config.Duration) or 4,
            })
        end)
    end

    function bridge:Confirm(config)
        config = config or {}
        if not currentWindow then
            return
        end

        currentWindow:Dialog({
            Title = tostring(config.Title or "Konfirmasi"),
            Content = tostring(config.Content or ""),
            Buttons = {
                {
                    Title = tostring(config.ConfirmText or "Ya"),
                    Callback = config.Callback,
                },
                {
                    Title = tostring(config.CancelText or "Batal"),
                },
            },
        })
    end

    return bridge
end

UI = BuildUiBridge(Fluent)

Window = UI:CreateWindow({
    Name = UI_NAME,
    LoadingSubtitle = "Ringan - Steal - Place - Sell",
    Theme = "Charcoal",
    Size = UDim2.fromOffset(560, 400),
})

_G.DoubleStealWindow = Window

local RadarTab = Window:CreateTab({
    Name = "Steal",
    Icon = "circle-dot",
})

local PlaceTab = Window:CreateTab({
    Name = "Place",
    Icon = "package",
})

local SellTab = Window:CreateTab({
    Name = "Sell",
    Icon = "coins",
})

local SettingsTab = Window:CreateTab({
    Name = "Setting",
    Icon = "settings",
})

-- =====================================================================
-- 3a. TAB STEAL
-- =====================================================================
local AutoStealSection = RadarTab:CreateSection("Auto Steal", "solar/star-bold")

AutoStealToggle = AutoStealSection:CreateToggle({
    Name = "Auto Steal",
    Desc = "Tembak prompt batu; eksklusif dengan Auto Instant Steal",
    CurrentValue = false,
    Flag = "AutoSteal",
    Callback = function(value)
        if value then
            SetStealMode("normal")
            if StatusLabel then
                StatusLabel:Set("Status: Auto Steal aktif, mencari batu...")
            end
            if instantStatusLabel then
                instantStatusLabel:Set("Auto Instant Steal: nonaktif (Auto Steal aktif).")
            end
        else
            if autoStealOn then
                SetStealMode(nil)
            end
            if StatusLabel then
                StatusLabel:Set("Status: Auto Steal nonaktif.")
            end
            if instantStatusLabel and not instantStealOn then
                instantStatusLabel:Set("Auto Instant Steal: nonaktif.")
            end
        end
    end,
})

AutoStealTeleportToggle = AutoStealSection:CreateToggle({
    Name = "Auto TP Bawah Tanah (Universal)",
    Desc = "Berlaku untuk Auto Steal, Instant, dan Auto Place. Off: semua aksi lewat prompt jarak jauh tanpa pindah",
    CurrentValue = true,
    Flag = "AutoStealTP",
    Callback = function(value)
        autoStealTeleport = value
        autoPlaceTeleport = value
        -- Biarkan batu yang sebelumnya gagal dicoba lagi dengan mode baru.
        autoCooldown = {}
        if StatusLabel and not AnyAutomationBusy() then
            StatusLabel:Set(value
                and "Status: Auto TP universal aktif - TP ke bawah batu dan penggiling."
                or "Status: Auto TP nonaktif - semua aksi tanpa TP, lewat prompt jarak jauh.")
        end
    end,
})

AutoStealSection:CreateParagraph({
    Title = "Paksa Jarak Prompt: Selalu Aktif",
    Content = "Prompt batu, penggiling, dan Sell ditembak tanpa batas jarak. Tidak perlu dekat objek dan tidak ada toggle yang bisa mematikannya. Ini aman karena game tidak memvalidasi jarak prompt di server.",
})

InstantStealToggle = AutoStealSection:CreateToggle({
    Name = "Auto Instant Steal",
    Desc = "Copy Auto Steal, mengikuti Auto TP universal; spam prompt sampai dapat",
    CurrentValue = false,
    Flag = "AutoInstantSteal",
    Callback = function(value)
        if value then
            SetStealMode("instant")
            if instantStatusLabel then
                instantStatusLabel:Set("Auto Instant Steal: aktif, TP bawah batu.")
            end
            if StatusLabel then
                StatusLabel:Set("Status: Auto Instant Steal aktif, TP bawah batu.")
            end
        else
            if instantStealOn then
                SetStealMode(nil)
            end
            if instantStatusLabel then
                instantStatusLabel:Set("Auto Instant Steal: nonaktif.")
            end
            if StatusLabel and not autoStealOn then
                StatusLabel:Set("Status: Memindai batu...")
            end
        end
    end,
})

RarityDropdown = AutoStealSection:CreateDropdown({
    Name = "Rarity",
    Desc = "Dipakai bersama Auto Steal dan Instant; Galaxy didahulukan",
    Options = rarityOptions,
    MultipleOptions = true,
    CurrentOption = { "Galaxy", "Secret" },
    Flag = "AutoStealRarity",
    Callback = function(options)
        selectedRarities = {}
        for _, rarity in ipairs(options or {}) do
            selectedRarities[string.lower(tostring(rarity))] = true
        end
    end,
})

StatusLabel = AutoStealSection:CreateLabel("Status: Memindai batu...")
instantStatusLabel = AutoStealSection:CreateLabel("Auto Instant Steal: nonaktif.")

AutoStealSection:CreateSlider({
    Name = "Jarak Mendatar Auto TP",
    Desc = "Offset mendatar dari batu. Prompt tetap bisa ditembak dari jauh, jadi tidak perlu menempel",
    Range = { 0, AUTO_STEAL_TP_DISTANCE_MAX },
    Increment = 0.5,
    CurrentValue = AUTO_STEAL_TP_DISTANCE_DEFAULT,
    Flag = "AutoStealTPDistance",
    Callback = function(value)
        autoStealTpDistance = value
    end,
})

AutoStealSection:CreateSlider({
    Name = "Kedalaman Auto TP (Universal)",
    Desc = "Stud di bawah lantai. Maksimal 6 supaya jarak ke prompt tetap di bawah 8 stud",
    Range = { 3, 6 },
    Increment = 0.5,
    CurrentValue = AUTO_STEAL_TP_DEPTH_DEFAULT,
    Flag = "AutoStealTPDepth",
    Callback = function(value)
        autoStealTpDepth = math.clamp(
            tonumber(value) or AUTO_STEAL_TP_DEPTH_DEFAULT,
            3,
            6
        )
    end,
})

AutoStealSection:CreateParagraph({
    Title = "Mode Steal",
    Content = "Hanya satu mode yang bisa aktif: Auto Steal atau Auto Instant Steal. Keduanya memakai Rarity, Kedalaman Auto TP, dan Jarak yang sama. Karakter selalu mendarat di bawah lantai, bukan di bawah batu yang melayang. Kalau batu masih dibawa, karakter tetap terkubur sampai Auto Place selesai memasukkan batu ke penggiling.",
})

local GhostSection = RadarTab:CreateSection("Ghost Mode (Invisible)", "ghost")

GhostModeToggle = GhostSection:CreateToggle({
    Name = "Ghost Mode",
    Desc = "Karakter dikubur jauh di bawah map, nama disembunyikan, kamera tetap di base. Steal/Place/Sell lewat prompt jarak jauh",
    CurrentValue = false,
    Flag = "GhostMode",
    Callback = function(value)
        if value then
            ghostWanted = true
            local ok, err = EnterGhostMode()
            if not ok then
                ghostWanted = false
                ghostModeOn = false
                if GhostModeToggle then
                    GhostModeToggle:Set(false, true)
                end
                if ghostStatusLabel then
                    ghostStatusLabel:Set("Ghost: gagal - " .. tostring(err) .. ".")
                end
                return
            end
        else
            ghostWanted = false
            ExitGhostMode()
        end
        UpdateGhostStatus()
    end,
})

ghostStatusLabel = GhostSection:CreateLabel("Ghost: nonaktif.")

GhostSection:CreateSlider({
    Name = "Kedalaman Ghost",
    Desc = "Seberapa jauh karakter dikubur di bawah home. Makin dalam, makin tidak terlihat semua pemain",
    Range = { 100, GHOST_DEPTH_MAX },
    Increment = 50,
    CurrentValue = GHOST_DEPTH_DEFAULT,
    Flag = "GhostDepth",
    Callback = function(value)
        ghostDepth = value
        if ghostActive then
            ExitGhostMode()
            task.wait(0.15)
            local ok, err = EnterGhostMode()
            if not ok and ghostStatusLabel then
                ghostStatusLabel:Set("Ghost: " .. tostring(err) .. ".")
            end
            UpdateGhostStatus()
        end
    end,
})

GhostSection:CreateToggle({
    Name = "Kunci Kamera di Base",
    Desc = "Kamera tetap di posisi awal supaya layar tidak ikut masuk ke bawah map",
    CurrentValue = true,
    Flag = "GhostLockCamera",
    Callback = function(value)
        ghostLockCamera = value == true
        UpdateGhostStatus()
    end,
})

GhostSection:CreateParagraph({
    Title = "Cara Kerja",
    Content = "Karakter di-anchor 100-1500 stud di bawah map, jauh dari jangkauan render pemain lain, nama dan health bar dimatikan. Kamera tetap di base. Auto Steal/Instant/Place/Sell menembak prompt dari posisi terkubur. Ini metode paling aman untuk membuat karaktermu tidak terlihat pemain lain tanpa memodifikasi server.",
})

local SmartSection = RadarTab:CreateSection("Smart Auto Steal", "shield")

SmartSection:CreateToggle({
    Name = "Smart Auto Steal",
    Desc = "Ada pemain lain: berhenti steal/place, TP ke base, lalu AFK",
    CurrentValue = false,
    Flag = "SmartAutoSteal",
    Callback = function(value)
        smartAutoStealOn = value
        if not value then
            smartSafeMode = false
            smartHomeDone = false
            smartNextHomeAt = 0
            smartNextAntiAfkAt = 0
            if smartStatusLabel then
                smartStatusLabel:Set("Smart: nonaktif.")
            end
        end
    end,
})

smartStatusLabel = SmartSection:CreateLabel("Smart: nonaktif.")

SmartSection:CreateParagraph({
    Title = "Cara Kerja",
    Content = "Saat hanya kamu di server, fitur berjalan normal. Begitu ada pemain lain, Auto Steal, Auto Instant Steal, Auto Place, dan Auto TP berhenti; karakter TP ke home lalu AFK dengan anti-AFK internal. Auto Sell tetap mengikuti setelan.",
})

local PlaceSection = PlaceTab:CreateSection("Auto Place", "solar/widget-bold")

PlaceSection:CreateToggle({
    Name = "Auto Place",
    Desc = "Isi otomatis penggiling kosong; penggiling berisi batu di-skip",
    CurrentValue = false,
    Flag = "AutoPlace",
    Callback = function(value)
        autoPlaceOn = value
        placeFailedAt = {}
        placeCooldownUntil = 0
        homeAttemptAt = 0
        homeTravelAt = 0
        if placeStatusLabel then
            if value then
                placeStatusLabel:Set("Auto Place: aktif, mencari penggiling kosong...")
            else
                placeStatusLabel:Set("Auto Place: nonaktif.")
            end
        end
    end,
})

PlaceSection:CreateButton({
    Name = "Place ke Penggiling Kosong",
    Desc = "Coba isi satu penggiling kosong sekarang",
    Icon = "package",
    Callback = ManualPlace,
})

PlaceSection:CreateSlider({
    Name = "Jeda Auto Place",
    Desc = "Jeda antar percobaan place (detik)",
    Range = { 1, 10 },
    Increment = 0.5,
    CurrentValue = AUTO_PLACE_DELAY_DEFAULT,
    Flag = "AutoPlaceDelay",
    Callback = function(value)
        autoPlaceDelay = value
    end,
})

PlaceSection:CreateSlider({
    Name = "Radius Penggiling",
    Desc = "Dipakai hanya saat mode Hanya Penggiling di Home mati (stud)",
    Range = { 20, 400 },
    Increment = 10,
    CurrentValue = GRINDER_RADIUS_DEFAULT,
    Flag = "AutoPlaceRadius",
    Callback = function(value)
        grinderRadius = value
    end,
})

PlaceSection:CreateParagraph({
    Title = "TP Place Universal",
    Content = "Mengikuti toggle dan Kedalaman Auto TP di tab Steal. Karakter turun tepat di bawah lantai penggiling, bukan di bawah prompt yang melayang. Tidak ada slider kedalaman terpisah supaya tidak ada setting yang saling bertentangan.",
})

PlaceSection:CreateToggle({
    Name = "Cek Batu di Tangan",
    Desc = "Hanya tekan prompt kalau ada batu yang sedang dipegang",
    CurrentValue = true,
    Flag = "AutoPlaceCheckStone",
    Callback = function(value)
        autoPlaceCheckStone = value
    end,
})

placeSummaryLabel = PlaceSection:CreateLabel("Penggiling: memindai...")

grinderListParagraph = PlaceSection:CreateParagraph({
    Title = "Penggiling Terdeteksi",
    Content = "Memindai penggiling di sekitar...",
})

placeStatusLabel = PlaceSection:CreateLabel("Auto Place: nonaktif.")

local HomeSection = PlaceTab:CreateSection("Home (Acuan Auto Place)")

HomeSection:CreateToggle({
    Name = "Hanya Penggiling di Home",
    Desc = "Abaikan base orang lain; hanya penggiling di sekitar home yang diisi",
    CurrentValue = true,
    Flag = "AutoPlaceHomeOnly",
    Callback = function(value)
        homeOnly = value
        placeFailedAt = {}
        placeCooldownUntil = 0
        UpdateHomeLabel()
        if placeStatusLabel then
            placeStatusLabel:Set(value
                and "Auto Place: mode home aktif (penggiling terdekat dari home)."
                or "Auto Place: mode bebas (penggiling terdekat dari karakter).")
        end
    end,
})

homeLabel = HomeSection:CreateLabel("Home: belum ditandai.")

HomeSection:CreateButton({
    Name = "Tandai Home (TP Home)",
    Desc = "Klik tombol Home di game lalu simpan posisi mendarat sebagai home",
    Icon = "house",
    Callback = function()
        task.spawn(function()
            if placeStatusLabel then
                placeStatusLabel:Set("Home: menekan tombol Home di game...")
            end

            local ok, err = MarkHomeByTeleport()
            if not running then
                return
            end

            if ok then
                if placeStatusLabel then
                    placeStatusLabel:Set("Home: ditandai dari teleport home.")
                end
                pcall(function()
                    UI:Notify({
                        Title = "Home ditandai",
                        Content = string.format(
                            "X %.1f, Y %.1f, Z %.1f",
                            homePosition.X,
                            homePosition.Y,
                            homePosition.Z
                        ),
                        Icon = "house",
                        Type = "Success",
                        Duration = 3,
                    })
                end)
            else
                if placeStatusLabel then
                    placeStatusLabel:Set("Home: gagal - " .. tostring(err) .. ".")
                end
                pcall(function()
                    UI:Notify({
                        Title = "Gagal menandai home",
                        Content = tostring(err)
                            .. ". Berdiri di home lalu klik 'Set ke Posisi Ini'.",
                        Icon = "triangle-alert",
                        Type = "Warning",
                        Duration = 4,
                    })
                end)
            end
        end)
    end,
})

HomeSection:CreateButton({
    Name = "Set Home ke Posisi Ini",
    Desc = "Simpan posisi karakter sekarang sebagai home",
    Icon = "map-pin",
    Callback = function()
        local ok, err = SetHomeFromPosition("manual")
        if ok then
            if placeStatusLabel then
                placeStatusLabel:Set("Home: diset ke posisi karakter sekarang.")
            end
            pcall(function()
                UI:Notify({
                    Title = "Home ditandai",
                    Content = string.format(
                        "X %.1f, Y %.1f, Z %.1f",
                        homePosition.X,
                        homePosition.Y,
                        homePosition.Z
                    ),
                    Icon = "house",
                    Type = "Success",
                    Duration = 3,
                })
            end)
        elseif placeStatusLabel then
            placeStatusLabel:Set("Home: gagal - " .. tostring(err) .. ".")
        end
    end,
})

HomeSection:CreateSlider({
    Name = "Radius Home",
    Desc = "Hanya penggiling dalam radius ini dari home yang diproses (stud)",
    Range = { 10, 200 },
    Increment = 5,
    CurrentValue = HOME_RADIUS_DEFAULT,
    Flag = "AutoPlaceHomeRadius",
    Callback = function(value)
        homeRadius = value
        UpdateHomeLabel()
    end,
})

UpdateHomeLabel()

local SafePositionSection = PlaceTab:CreateSection("Safe Position (Sell)")

SafePositionSection:CreateToggle({
    Name = "TP ke Sell setelah Place",
    Desc = "Hanya setelah batu benar-benar masuk penggiling dan lepas dari tangan",
    CurrentValue = true,
    Flag = "SafePositionSell",
    Callback = function(value)
        sellTpOnPlace = value == true
        if placeStatusLabel then
            placeStatusLabel:Set(sellTpOnPlace
                and "Safe Position: aktif, akan TP ke Sell setelah place."
                or "Safe Position: nonaktif.")
        end
    end,
})

sellLabel = SafePositionSection:CreateLabel("Sell: belum ditandai.")

SafePositionSection:CreateSlider({
    Name = "Kedalaman Sell",
    Desc = "Karakter turun di bawah lantai toko; tetap di dalam radius prompt Sell",
    Range = { 3, 6 },
    Increment = 0.5,
    CurrentValue = SELL_SAFE_DEPTH_DEFAULT,
    Flag = "SellSafeDepth",
    Callback = function(value)
        sellSafeDepth = math.clamp(
            tonumber(value) or SELL_SAFE_DEPTH_DEFAULT,
            3,
            6
        )
        if sellPosition then
            SaveSellUndergroundFrom(sellPosition, "auto setelah ubah kedalaman")
            SaveSellFile()
        end
        UpdateSellPositionLabel()
    end,
})

SafePositionSection:CreateButton({
    Name = "Set Posisi Sell ke Sini",
    Desc = "Simpan posisi karakter sekarang sebagai titik Sell",
    Icon = "map-pin",
    Callback = function()
        local ok, err = SetSellPositionFromHere()
        if ok then
            if placeStatusLabel then
                placeStatusLabel:Set("Safe Position: titik Sell disimpan.")
            end
            pcall(function()
                UI:Notify({
                    Title = "Titik Sell disimpan",
                    Content = "TP setelah Auto Place akan menuju posisi ini.",
                    Icon = "map-pin",
                    Type = "Success",
                    Duration = 3,
                })
            end)
        else
            if placeStatusLabel then
                placeStatusLabel:Set("Safe Position: gagal - " .. tostring(err) .. ".")
            end
        end
    end,
})

SafePositionSection:CreateButton({
    Name = "TP ke Sell Sekarang",
    Desc = "Langsung ke titik aman bawah tanah; tidak mampir ke permukaan toko",
    Icon = "shopping-cart",
    Callback = function()
        local ok, err = TravelToSell()
        if not ok then
            pcall(function()
                UI:Notify({
                    Title = "TP Sell gagal",
                    Content = tostring(err) .. ". Set posisi Sell manual.",
                    Icon = "triangle-alert",
                    Type = "Warning",
                    Duration = 3,
                })
            end)
        end
    end,
})

SafePositionSection:CreateButton({
    Name = "Deteksi Sell Otomatis",
    Desc = "Cari prompt/part bernama Sell atau Jual di Workspace",
    Icon = "search",
    Callback = function()
        local target = FindSellTarget(true)
        if target then
            sellPosition = target.position
            sellPositionSource = "auto: " .. tostring(target.label or "Sell")
            SaveSellFile()
            UpdateSellPositionLabel()
            if placeStatusLabel then
                placeStatusLabel:Set("Safe Position: Sell terdeteksi di "
                    .. tostring(target.label or "-") .. ".")
            end
            pcall(function()
                UI:Notify({
                    Title = "Sell terdeteksi",
                    Content = tostring(target.label or "Sell"),
                    Icon = "search",
                    Type = "Success",
                    Duration = 3,
                })
            end)
        else
            if placeStatusLabel then
                placeStatusLabel:Set("Safe Position: Sell tidak ditemukan. Set manual.")
            end
        end
    end,
})

SafePositionSection:CreateButton({
    Name = "Set Safe Sell dari Posisi Ini",
    Desc = "Simpan posisi karakter sekarang sebagai titik Sell bawah tanah",
    Icon = "map-pin",
    Callback = function()
        local root = GetCharacterRoot()
        if not root then
            return
        end
        sellUnderground = root.Position
        sellUndergroundSource = "manual"
        SaveSellFile()
        UpdateSellPositionLabel()
        if placeStatusLabel then
            placeStatusLabel:Set("Safe Position: titik aman Sell disimpan.")
        end
    end,
})

SafePositionSection:CreateParagraph({
    Title = "Cara Kerja",
    Content = "Auto Place baru TP ke Sell setelah batu benar-benar lepas dari tangan dan terlihat di penggiling. Titik aman dihitung dari lantai bawah toko, disimpan sekali, lalu dipakai seterusnya. Karakter tidak pernah berdiri di permukaan toko dan tidak TP ke Sell berulang-ulang.",
})

UpdateSellPositionLabel()

local SellSection = SellTab:CreateSection("Auto Sell")

autoSellToggle = SellSection:CreateToggle({
    Name = "Auto Sell",
    Desc = "Jual item di bag/slot bar; berhenti dan menunggu saat kosong",
    CurrentValue = false,
    Flag = "AutoSell",
    Callback = function(value)
        autoSellOn = value
        sellWaiting = false
        sellNextAt = 0
        if not value then
            sellFailStreak = 0
        end
        if MyshiRawSellToggleButton then
            MyshiRawSellToggleButton.Text = value
                and "Auto Sell: ON"
                or "Auto Sell: OFF"
        end
        if sellStatusLabel then
            sellStatusLabel:Set(value
                and "Auto Sell: aktif, menunggu item di bag/slot bar..."
                or "Auto Sell: nonaktif.")
        end
    end,
})

SellSection:CreateButton({
    Name = "Sell Semua Sekarang",
    Desc = "Scan bag/slot bar lalu kirim sellItem untuk semuanya",
    Icon = "coins",
    Callback = SellAllNow,
})

SellSection:CreateButton({
    Name = "Scan Ulang Item",
    Desc = "Baca ulang nama item dari bag/slot bar saja",
    Icon = "refresh-cw",
    Callback = RefreshSellCandidates,
})

SellSection:CreateSlider({
    Name = "Jeda Auto Sell",
    Desc = "Jeda antar putaran Auto Sell (detik)",
    Range = { 2, 30 },
    Increment = 1,
    CurrentValue = SELL_INTERVAL_DEFAULT,
    Flag = "AutoSellDelay",
    Callback = function(value)
        autoSellInterval = value
    end,
})

sellStatusLabel = SellSection:CreateLabel("Auto Sell: nonaktif.")

sellItemsLabel = SellSection:CreateParagraph({
    Title = "Item Terbaca",
    Content = "Belum discan. Klik Scan Ulang Item.",
})

SellSection:CreateParagraph({
    Title = "Dikecualikan",
    Content = "Pumpkin, Pumpkins, dan Yobux tidak pernah dikirim ke SellRequest.",
})

local PrioritySection = RadarTab:CreateSection("Priority")

priorityDropdown = PrioritySection:CreateDropdown({
    Name = "Urutan Prioritas",
    Desc = "Hanya satu fitur otomasi jalan per giliran; urutan atas didahulukan",
    Options = PRIORITY_OPTIONS,
    CurrentOption = "Steal > Place > Sell",
    Flag = "FeaturePriority",
    Callback = function(option)
        featurePriority = PRIORITY_MAP[option]
            or PRIORITY_MAP["Steal > Place > Sell"]
    end,
})

PrioritySection:CreateParagraph({
    Title = "Cara Kerja Priority",
    Content = "Fitur yang tidak siap dilewati. Auto Steal dan Instant berbagi slot Steal. Saat Smart mode aktif dan ada pemain lain, Steal/Place dihentikan.",
})

local StoneSection = RadarTab:CreateCollapsibleSection(
    "Batu Terdeteksi (0)",
    "solar/list-bold",
    true
)

StoneSection:CreateToggle({
    Name = "Auto Refresh",
    Desc = "Pindai daftar batu setiap 1 detik",
    CurrentValue = true,
    Flag = "AutoRefresh",
    Callback = function(value)
        autoRefreshOn = value
        if StatusLabel and not autoStealOn and not instantStealOn then
            StatusLabel:Set(value and "Status: Memindai batu..." or "Status: Auto refresh nonaktif.")
        end
    end,
})

local EmptyLabel = StoneSection:CreateLabel("Belum ada batu terdeteksi.")

local GuideSection = RadarTab:CreateCollapsibleSection("Panduan", nil, false)

GuideSection:CreateParagraph({
    Title = "Deteksi Penggiling",
    Content = "Acuannya home, bukan posisi karakter. Penggiling bernama 'penggiling...' atau yang punya prompt 'Giling Batu' dicari, lalu hanya yang berada dalam Radius Home diproses. Penggiling base orang lain tidak disentuh. Kalau belum termuat karena streaming, Auto Place TP home otomatis.",
})

GuideSection:CreateParagraph({
    Title = "Cara Kerja Auto Sell",
    Content = "Nama item dibaca hanya dari bag/slot bar milikmu. Tombol aksi seperti 'Turunkan Batu' atau 'Giling Batu' disaring. Pumpkin, Pumpkins, dan Yobux dikecualikan. Kalau bag/slot bar kosong, Auto Sell berhenti dan menunggu item masuk. Maksimal 200 item per putaran.",
})

GuideSection:CreateParagraph({
    Title = "Steal",
    Content = "Auto Steal dan Auto Instant Steal memakai dropdown Rarity, Auto TP Universal, Jarak Auto TP, dan Kedalaman Auto TP yang sama. Mengaktifkan salah satunya mematikan yang lain. Instant Steal menyalin cara kerja Auto Steal, termasuk TP bawah batu kalau Auto TP aktif.",
})

-- =====================================================================
-- 3b. TAB TRACKER
-- =====================================================================
local TrackerSection = SellTab:CreateSection("Tracker: Rekam Batu")

trackerStatusLabel = TrackerSection:CreateLabel("Tracker: nonaktif | Terekam: 0 posisi")

TrackerSection:CreateToggle({
    Name = "Rekam Penempatan Batu",
    Desc = "Catat batu baru di sekitar karakter",
    CurrentValue = false,
    Flag = "TrackerRecord",
    Callback = function(value)
        trackerOn = value

        if value then
            trackedInstances = setmetatable({}, { __mode = "k" })
            SnapshotExistingStones()
            if trackerStatusLabel then
                trackerStatusLabel:Set("Tracker: merekam batu baru di dekat karakter...")
            end
        else
            UpdateTrackerLabels()
        end
    end,
})

TrackerSection:CreateSlider({
    Name = "Radius Rekam",
    Desc = "Jarak maksimal batu baru dari karakter (stud)",
    Range = { 20, 200 },
    Increment = 10,
    CurrentValue = TRACKER_RADIUS_DEFAULT,
    Flag = "TrackerRadius",
    Callback = function(value)
        trackerRadius = value
    end,
})

trackerLastLabel = TrackerSection:CreateLabel("Terakhir: -")

TrackerSection:CreateParagraph({
    Title = "Cara pakai",
    Content = "Aktifkan rekaman saat ingin mencatat batu baru di sekitar karakter. Setiap batu bernama 'batu' dalam radius disimpan dengan posisi, CFrame, rarity, dan ukuran. Auto Place memakai titik home, jadi export ini tidak wajib.",
})

local ExportSection = SellTab:CreateSection("Tracker: Export")

trackerExportLabel = ExportSection:CreateLabel("Belum ada export.")

ExportSection:CreateButton({
    Name = "Copy Export JSON",
    Desc = "Salin JSON ke clipboard; file juga ditulis jika executor mendukung",
    Icon = "clipboard-copy",
    Callback = CopyTrackerExport,
})

ExportSection:CreateButton({
    Name = "Clear Data Tracker",
    Desc = "Hapus semua posisi yang sudah direkam",
    Icon = "trash-2",
    Callback = function()
        UI:Confirm({
            Title = "Hapus data tracker?",
            Content = "Semua posisi yang sudah direkam akan dihapus.",
            ConfirmText = "Hapus",
            CancelText = "Batal",
            Callback = ClearTrackerData,
        })
    end,
})

-- =====================================================================
-- 3c. TAB PENGATURAN
-- =====================================================================
local PerformanceSection = SettingsTab:CreateSection("Performa & AFK")

PerformanceSection:CreateToggle({
    Name = "Anti-AFK Universal",
    Desc = "Aktif default: VirtualUser + Idled + timer; cadangan keypress, mouse, VirtualInputManager, jump",
    CurrentValue = true,
    Flag = "AntiAFK",
    Callback = SetAntiAfk,
})

antiAfkStatusLabel = PerformanceSection:CreateLabel("Anti-AFK: nonaktif")

PerformanceSection:CreateSlider({
    Name = "Interval Anti-AFK",
    Desc = "Seberapa sering aktivitas virtual dikirim (detik)",
    Range = { 15, 120 },
    Increment = 5,
    CurrentValue = ANTI_AFK_INTERVAL_DEFAULT,
    Flag = "AntiAFKInterval",
    Callback = function(value)
        antiAfkInterval = value
        if antiAfkOn then
            SetAntiAfk(true)
        else
            UpdateAntiAfkStatus()
        end
    end,
})

PerformanceSection:CreateButton({
    Name = "Test Anti-AFK Sekarang",
    Desc = "Kirim satu pulse dan lihat metode yang dipakai",
    Icon = "activity",
    Callback = function()
        AntiAfkPulse("test")
        pcall(function()
            UI:Notify({
                Title = "Anti-AFK",
                Content = "Pulse dikirim dengan metode: " .. tostring(antiAfkLastMethod),
                Icon = "activity",
                Type = "Info",
                Duration = 3,
            })
        end)
    end,
})

PerformanceSection:CreateToggle({
    Name = "Disable 3D Render",
    Desc = "Matikan render dunia 3D untuk mengurangi beban; UI dan script tetap jalan",
    CurrentValue = false,
    Flag = "Disable3DRender",
    Callback = Set3dRenderDisabled,
})

PerformanceSection:CreateParagraph({
    Title = "Catatan Performa",
    Content = "Anti-AFK memakai VirtualUser (CaptureController + ClickButton2), event Idled, dan timer. Kalau executor tidak mendukung VirtualUser, dicoba keypress, VirtualInputManager, lalu lompat. Interval 30 detik default. Disable 3D Render memakai RunService:Set3dRenderingEnabled; kalau tidak didukung, kualitas grafis diturunkan. Semuanya dikembalikan saat Unload Script.",
})

local SaveManager = Fluent.SaveManager
local saveApiReady = type(writefile) == "function"
    and type(readfile) == "function"
    and type(isfile) == "function"
    and type(listfiles) == "function"
    and type(delfile) == "function"
    and type(makefolder) == "function"
    and type(isfolder) == "function"

if SaveManager and saveApiReady then
    local saveSetupOk = pcall(function()
        SaveManager:SetLibrary(Fluent)
        SaveManager:SetFolder(CONFIG_FOLDER .. "/Config")
        SaveManager:IgnoreThemeSettings()
    end)
    if not saveSetupOk then
        SaveManager = nil
    end
else
    SaveManager = nil
end

local bootstrap = {
    AutoLoad = true,
    AutoSave = true,
    LastConfig = "default",
}

local function LoadBootstrap()
    if type(isfile) ~= "function" or type(readfile) ~= "function" then
        return
    end
    if not isfile(BOOTSTRAP_FILE) then
        return
    end

    local ok, data = pcall(function()
        return HttpService:JSONDecode(readfile(BOOTSTRAP_FILE))
    end)
    if not ok or type(data) ~= "table" then
        return
    end

    bootstrap.AutoLoad = data.AutoLoad ~= false
    bootstrap.AutoSave = data.AutoSave ~= false
    if type(data.LastConfig) == "string" and data.LastConfig ~= "" then
        bootstrap.LastConfig = data.LastConfig
    end
end

local function SaveBootstrap()
    if type(writefile) ~= "function" then
        return
    end

    pcall(function()
        if type(makefolder) == "function"
            and type(isfolder) == "function"
            and not isfolder(CONFIG_FOLDER)
        then
            makefolder(CONFIG_FOLDER)
        end
        writefile(BOOTSTRAP_FILE, HttpService:JSONEncode(bootstrap))
    end)
end

LoadBootstrap()

local autoLoadOn = bootstrap.AutoLoad
local autoSaveOn = bootstrap.AutoSave
local autoSaveStatusLabel
local lastConfigName = bootstrap.LastConfig
local AUTO_SAVE_INTERVAL = 60

local function GetActiveConfigName()
    if not SaveManager then
        return nil
    end

    local listOption = SaveManager.Options
        and SaveManager.Options.SaveManager_ConfigList
    if listOption and type(listOption.Value) == "string" and listOption.Value ~= "" then
        return listOption.Value
    end

    if type(lastConfigName) == "string" and lastConfigName ~= "" then
        local configPath = SaveManager.Folder
            .. "/settings/"
            .. lastConfigName
            .. ".json"
        if type(isfile) == "function" and isfile(configPath) then
            return lastConfigName
        end
    end

    local path = SaveManager.Folder .. "/settings/autoload.txt"
    if type(isfile) == "function" and type(readfile) == "function" and isfile(path) then
        local ok, value = pcall(readfile, path)
        if ok and type(value) == "string" and value ~= "" then
            return value
        end
    end

    return nil
end

local function TryAutoSave()
    if not autoSaveOn then
        return false
    end
    if not SaveManager then
        if autoSaveStatusLabel then
            autoSaveStatusLabel:Set("Auto Save: config manager tidak tersedia di executor ini.")
        end
        return false
    end

    local name = GetActiveConfigName()
    if not name then
        if autoSaveStatusLabel then
            autoSaveStatusLabel:Set("Auto Save: pilih/buat config dulu di Configuration.")
        end
        return false
    end

    local ok, saved, err = pcall(function()
        return SaveManager:Save(name)
    end)
    if ok and saved then
        lastConfigName = name
        if autoSaveStatusLabel then
            autoSaveStatusLabel:Set(string.format(
                "Auto Save: %s tersimpan %s.",
                name,
                os.date("%H:%M:%S")
            ))
        end
        return true
    end

    if autoSaveStatusLabel then
        autoSaveStatusLabel:Set("Auto Save: gagal - " .. tostring(err or saved or "unknown") .. ".")
    end
    return false
end

if UI then
    local previousBeforeDestroy = UI.BeforeDestroy
    UI.BeforeDestroy = function()
        ghostWanted = false
        pcall(ExitGhostMode)
        pcall(StealthHold.End)
        pcall(SafeSellAnchor.Release)
        if type(previousBeforeDestroy) == "function" then
            pcall(previousBeforeDestroy)
        else
            pcall(TryAutoSave)
        end
    end
end

local ConfigSection = SettingsTab:CreateSection("Auto Save")

ConfigSection:CreateToggle({
    Name = "Auto Load Config",
    Desc = "Muat config terakhir atau autoload saat script dijalankan",
    CurrentValue = autoLoadOn,
    Flag = "AutoLoad",
    Callback = function(value)
        autoLoadOn = value
        bootstrap.AutoLoad = value
        SaveBootstrap()
    end,
})

ConfigSection:CreateToggle({
    Name = "Auto Save",
    Desc = "Simpan otomatis ke config aktif setiap 60 detik",
    CurrentValue = autoSaveOn,
    Flag = "AutoSave",
    Callback = function(value)
        autoSaveOn = value
        bootstrap.AutoSave = value
        SaveBootstrap()
        if autoSaveStatusLabel then
            if not SaveManager then
                autoSaveStatusLabel:Set("Auto Save: config manager tidak tersedia di executor ini.")
            else
                autoSaveStatusLabel:Set(value
                    and "Auto Save: aktif. Pilih config di Configuration."
                    or "Auto Save: nonaktif.")
            end
        end
    end,
})

autoSaveStatusLabel = ConfigSection:CreateLabel(
    SaveManager and "Auto Save: menunggu config..."
        or "Auto Save: config manager tidak tersedia di executor ini."
)

ConfigSection:CreateParagraph({
    Title = "Penyimpanan",
    Content = "Config disimpan di folder " .. CONFIG_FOLDER
        .. "/Config. Gunakan Create config, Load, Overwrite, dan Set as autoload di bagian Configuration di bawah.",
})

if SaveManager then
    local originalSave = SaveManager.Save
    local originalLoad = SaveManager.Load

    SaveManager.Save = function(self, name)
        local ok, err = originalSave(self, name)
        if ok and type(name) == "string" and name ~= "" then
            lastConfigName = name
            bootstrap.LastConfig = name
            SaveBootstrap()
        end
        return ok, err
    end

    SaveManager.Load = function(self, name)
        local ok, err = originalLoad(self, name)
        if ok and type(name) == "string" and name ~= "" then
            lastConfigName = name
            bootstrap.LastConfig = name
            SaveBootstrap()
        end
        return ok, err
    end

    local buildOk = pcall(function()
        SaveManager:BuildConfigSection(SettingsTab._target)
    end)
    if not buildOk and autoSaveStatusLabel then
        autoSaveStatusLabel:Set("Auto Save: gagal menyiapkan config manager.")
    end
end

local ControlSection = SettingsTab:CreateSection("Kontrol")

ControlSection:CreateParagraph({
    Title = "Catatan",
    Content = "Tombol minimize (—) menyembunyikan window; tekan RightControl untuk membukanya lagi. Tombol tutup (X) menutup UI sekaligus menghentikan radar.",
})

ControlSection:CreateButton({
    Name = "Unload Script",
    Desc = "Hentikan radar dan tutup UI",
    Icon = "power",
    Callback = function()
        UI:Confirm({
            Title = "Unload Script?",
            Content = "Radar berhenti dan window ditutup.",
            ConfirmText = "Unload",
            CancelText = "Batal",
            Callback = function()
                running = false
                _G.DoubleStealActive = false
                CleanupPerformanceSettings()
                if _G.DoubleStealWindow == Window then
                    _G.DoubleStealWindow = nil
                end
                Window:Destroy()
            end,
        })
    end,
})

if SaveManager then
    local function HasConfigFile(name)
        if type(isfile) ~= "function" then
            return false
        end
        return isfile(SaveManager.Folder .. "/settings/" .. tostring(name) .. ".json")
    end

    if autoLoadOn then
        local autoloadPath = SaveManager.Folder .. "/settings/autoload.txt"
        local hasAutoload = type(isfile) == "function" and isfile(autoloadPath)
        if hasAutoload then
            pcall(function()
                SaveManager:LoadAutoloadConfig()
            end)
        elseif lastConfigName and HasConfigFile(lastConfigName) then
            pcall(function()
                SaveManager:Load(lastConfigName)
            end)
        elseif lastConfigName then
            pcall(function()
                SaveManager:Save(lastConfigName)
            end)
        end
    end

    if autoSaveStatusLabel then
        if not autoSaveOn then
            autoSaveStatusLabel:Set("Auto Save: nonaktif.")
        elseif lastConfigName and HasConfigFile(lastConfigName) then
            autoSaveStatusLabel:Set("Auto Save: siap (" .. tostring(lastConfigName) .. ").")
        else
            autoSaveStatusLabel:Set("Auto Save: pilih/buat config dulu di Configuration.")
        end
    end
end

task.spawn(function()
    local nextAt = os.time() + AUTO_SAVE_INTERVAL
    while running do
        task.wait(5)
        if autoSaveOn and os.time() >= nextAt then
            pcall(TryAutoSave)
            nextAt = os.time() + AUTO_SAVE_INTERVAL
        end
    end
end)

-- Fluent 1.6 terkadang menampilkan overlay "This tab is empty" walau section
-- sudah dibuat, terutama pada tab yang isinya dibuat belakangan. Sembunyikan
-- overlay itu langsung dari teksnya.
local function KillEmptyTabOverlays()
    local roots = MyshiUtil.GetGuiRoots()

    for _, root in ipairs(roots) do
        if root then
            for _, obj in ipairs(root:GetDescendants()) do
                if obj:IsA("TextLabel") then
                    local text = string.lower(tostring(obj.Text or ""))
                    if string.find(text, "this tab is empty", 1, true) then
                        local inner = obj.Parent
                        local overlay = inner and inner.Parent
                        if overlay and overlay:IsA("Frame") then
                            overlay.Visible = false
                        end
                    end
                end
            end
        end
    end
end

local sellTabFallbackBuilt = false

local function FrameHasContent(frame)
    if not frame then
        return false
    end
    for _, child in ipairs(frame:GetChildren()) do
        if child:IsA("Frame") or child:IsA("CanvasGroup")
            or child:IsA("ScrollingFrame") or child:IsA("TextButton")
        then
            return true
        end
    end
    return false
end

local rawSellFallbackBuilt = false

-- Fallback terakhir: GUI Roblox biasa yang dipasang langsung ke body tab.
-- Ini tidak bergantung pada section Fluent, jadi tetap tampil walau Fluent
-- menampilkan overlay "This tab is empty".
local function FrameHasInteractive(frame)
    if not frame then
        return false
    end
    for _, child in ipairs(frame:GetChildren()) do
        if child:IsA("TextButton") or child:IsA("ImageButton") then
            return true
        end
        for _, descendant in ipairs(child:GetDescendants()) do
            if descendant:IsA("TextButton") or descendant:IsA("ImageButton") then
                return true
            end
        end
    end
    return false
end

local function BuildRawSellFallback(parentFrame)
    if rawSellFallbackBuilt or not parentFrame then
        return false
    end

    rawSellFallbackBuilt = true

    local panel = Instance.new("Frame")
    panel.Name = "AutoSellRaw"
    panel.Size = UDim2.new(1, -8, 0, 0)
    panel.AutomaticSize = Enum.AutomaticSize.Y
    panel.BackgroundTransparency = 0.08
    panel.BackgroundColor3 = Color3.fromRGB(22, 22, 29)
    panel.BorderSizePixel = 0
    panel.LayoutOrder = -100
    panel.Parent = parentFrame

    local corner = Instance.new("UICorner")
    corner.CornerRadius = UDim.new(0, 6)
    corner.Parent = panel

    local layout = Instance.new("UIListLayout")
    layout.Padding = UDim.new(0, 5)
    layout.SortOrder = Enum.SortOrder.LayoutOrder
    layout.Parent = panel

    local padding = Instance.new("UIPadding")
    padding.PaddingTop = UDim.new(0, 8)
    padding.PaddingBottom = UDim.new(0, 8)
    padding.PaddingLeft = UDim.new(0, 8)
    padding.PaddingRight = UDim.new(0, 8)
    padding.Parent = panel

    local title = Instance.new("TextLabel")
    title.Size = UDim2.new(1, 0, 0, 22)
    title.BackgroundTransparency = 1
    title.Text = "Auto Sell"
    title.TextSize = 15
    title.TextColor3 = Color3.fromRGB(245, 245, 250)
    title.TextXAlignment = Enum.TextXAlignment.Left
    title.Parent = panel

    local function makeButton(text, order)
        local button = Instance.new("TextButton")
        button.Size = UDim2.new(1, 0, 0, 30)
        button.BackgroundColor3 = Color3.fromRGB(35, 35, 45)
        button.TextColor3 = Color3.fromRGB(240, 240, 245)
        button.TextSize = 13
        button.Text = text
        button.AutoButtonColor = true
        button.LayoutOrder = order or 0
        button.Parent = panel
        local buttonCorner = Instance.new("UICorner")
        buttonCorner.CornerRadius = UDim.new(0, 4)
        buttonCorner.Parent = button
        return button
    end

    local function makeLabel(text, order)
        local label = Instance.new("TextLabel")
        label.Size = UDim2.new(1, 0, 0, 18)
        label.BackgroundTransparency = 1
        label.Text = text
        label.TextSize = 12
        label.TextWrapped = true
        label.TextXAlignment = Enum.TextXAlignment.Left
        label.TextColor3 = Color3.fromRGB(190, 190, 205)
        label.LayoutOrder = order or 0
        label.Parent = panel
        local wrapper = {}
        function wrapper:Set(value)
            label.Text = tostring(value or "")
        end
        return wrapper, label
    end

    local toggle = makeButton("Auto Sell: OFF", 1)
    local sellButton = makeButton("Sell Semua Sekarang", 2)
    local scanButton = makeButton("Scan Ulang Item", 3)
    local status, statusLabel = makeLabel("Auto Sell: siap.", 4)
    local items = makeLabel("Item Terbaca: belum discan.", 5)
    statusLabel.TextColor3 = Color3.fromRGB(235, 210, 120)

    local function refreshToggle()
        toggle.Text = autoSellOn and "Auto Sell: ON" or "Auto Sell: OFF"
    end

    if toggle.MouseButton1Click then
        toggle.MouseButton1Click:Connect(function()
            autoSellOn = not autoSellOn
            sellWaiting = false
            sellNextAt = 0
            if autoSellToggle then
                autoSellToggle:Set(autoSellOn, true)
            end
            refreshToggle()
            status:Set(autoSellOn
                and "Auto Sell: aktif. Hanya item bag/slot bar yang dijual."
                or "Auto Sell: nonaktif.")
        end)
    end

    if sellButton.MouseButton1Click then
        sellButton.MouseButton1Click:Connect(function()
            pcall(SellAllNow)
        end)
    end

    if scanButton.MouseButton1Click then
        scanButton.MouseButton1Click:Connect(function()
            pcall(RefreshSellCandidates)
        end)
    end

    sellStatusLabel = status
    sellItemsLabel = items
    MyshiRawSellToggleButton = toggle
    refreshToggle()

    return true
end

local function BuildSellFallback(tab)
    -- Fallback kalau tab Sell benar-benar kosong di Fluent. Isinya sama
    -- fungsinya, hanya lebih ringkas, dan memakai variabel global yang sama.
    local fallback = tab:CreateSection("Auto Sell")
    fallback:CreateLabel("Tab Sell dipulihkan otomatis. Hanya item di bag/slot bar yang dijual.")

    fallback:CreateToggle({
        Name = "Auto Sell",
        Desc = "Jual item bag/slot bar; berhenti saat kosong",
        CurrentValue = autoSellOn,
        Flag = "AutoSellFallback",
        Callback = function(value)
            autoSellOn = value
            sellWaiting = false
            sellNextAt = 0
            if autoSellToggle then
                autoSellToggle:Set(value, true)
            end
        end,
    })

    fallback:CreateButton({
        Name = "Sell Semua Sekarang",
        Desc = "Kirim sellItem untuk semua item bag/slot bar",
        Icon = "coins",
        Callback = SellAllNow,
    })
    fallback:CreateButton({
        Name = "Scan Ulang Item",
        Desc = "Baca ulang item dari bag/slot bar saja",
        Icon = "refresh-cw",
        Callback = RefreshSellCandidates,
    })

    sellStatusLabel = fallback:CreateLabel("Auto Sell: siap.")
    sellItemsLabel = fallback:CreateParagraph({
        Title = "Item Terbaca",
        Content = "Klik Scan Ulang Item untuk membaca bag/slot bar.",
    })

    local tracker = tab:CreateSection("Tracker: Export")
    tracker:CreateButton({
        Name = "Copy Export JSON",
        Desc = "Salin data tracker ke clipboard/file",
        Icon = "clipboard-copy",
        Callback = CopyTrackerExport,
    })
end

local function ResolveTabFrame(tab)
    local target = tab and (tab._target or tab)
    if not target then
        return nil
    end
    return target.ContainerFrame or target.Container or target.ScrollFrame
end

local function ResolveSectionFrame(section)
    local target = section and (section._target or section)
    if not target then
        return nil
    end
    return target.Container or target.Frame or target.Root
end

local autoSellFallbackBuilt = false

local function EnsureAutoSellControls()
    if autoSellFallbackBuilt or sellTabFallbackBuilt or not SellSection then
        return
    end
    local frame = ResolveSectionFrame(SellSection)
    if frame and FrameHasInteractive(frame) then
        return
    end
    autoSellFallbackBuilt = true

    -- GUI Roblox langsung lebih aman daripada membuat section Fluent baru:
    -- section baru bisa ikut kosong kalau body tab-nya bermasalah. Pasang ke
    -- body tab, bukan ke section, supaya pasti terlihat di paling atas.
    if BuildRawSellFallback(ResolveTabFrame(SellTab) or frame) then
        return
    end
    BuildSellFallback(SellTab or PlaceTab or RadarTab)
end

local function EnsureSellTabUsable()
    if sellTabFallbackBuilt then
        return
    end

    -- Tab wrapper menyimpan objek Fluent asli di _target. Versi Fluent-Pro
    -- tertentu hanya punya .Container, bukan .ContainerFrame; kalau memakai
    -- ContainerFrame saja, fallback tidak pernah jalan dan tab Sell tetap
    -- menampilkan "This tab is empty".
    local frame = ResolveTabFrame(SellTab)
    if not frame then
        if PlaceTab then
            sellTabFallbackBuilt = true
            BuildSellFallback(PlaceTab)
        end
        return
    end
    if FrameHasContent(frame) then
        return
    end

    sellTabFallbackBuilt = true

    -- Fallback pertama: GUI Roblox langsung ke body tab. Ini pasti terlihat
    -- dan tetap berfungsi walau Fluent gagal membuat section.
    if BuildRawSellFallback(frame) then
        return
    end

    BuildSellFallback(SellTab)

    -- Kalau tab Sell tetap tidak punya child (Fluent gagal membuat body tab),
    -- pasang Auto Sell di tab Place/Steal supaya fiturnya tetap bisa dipakai.
    if not FrameHasContent(frame) and PlaceTab then
        BuildSellFallback(PlaceTab)
    end
    if not FrameHasContent(frame) and RadarTab then
        BuildSellFallback(RadarTab)
    end
end

task.spawn(function()
    for _ = 1, 6 do
        task.wait(0.5)
        pcall(KillEmptyTabOverlays)
        pcall(EnsureSellTabUsable)
        pcall(EnsureAutoSellControls)
    end
end)

return StoneSection, EmptyLabel
end

StoneSection, EmptyLabel = BuildUi()

-- Startup: langsung pulang ke home dan simpan titik mendaratnya. Ini membuat
-- penggiling home selalu siap dipakai Auto Place sejak execute pertama.
-- Tidak memakai posisi spawn acak sebagai home.
function StartupGoHome()
    if not running then
        return
    end

    if placeStatusLabel then
        placeStatusLabel:Set("Home: berangkat ke home dan menandai posisi...")
    end

    local callOk, ok, err = pcall(MarkHomeByTeleport)
    if not callOk then
        err = ok
        ok = false
    end

    if not running then
        return
    end

    startupHomePending = false

    if ok then
        if placeStatusLabel then
            placeStatusLabel:Set("Home: siap dipakai Auto Place.")
        end
    else
        -- Jangan pernah menyimpan posisi spawn acak sebagai home. Kalau tombol
        -- Home gagal, pakai home tersimpan; kalau belum ada, minta set manual.
        if homePosition then
            pcall(TravelHome)
        end
        if placeStatusLabel then
            placeStatusLabel:Set("Home: gagal TP ke home - " .. tostring(err)
                .. ". Berdiri di home lalu klik 'Set Home ke Posisi Ini'.")
        end
    end

    return ok
end

task.spawn(function()
    -- Tunggu karakter benar-benar siap sebelum menekan tombol Home.
    for _ = 1, 10 do
        task.wait(0.2)
        local root = GetCharacterRoot()
        if root and root.Parent then
            break
        end
    end
    task.wait(0.3)
    if not running then
        return
    end

    local ok = StartupGoHome()
    if running and not ok then
        task.wait(2)
        if running then
            StartupGoHome()
        end
    end
end)

task.spawn(function()
    task.wait(0.6)
    if running and antiAfkOn then
        SetAntiAfk(true)
    end
end)


-- =====================================================================
-- 4. RADAR BATU
-- =====================================================================
rows = {}

function CreateStoneRow(stone)
    local row = { stone = stone }

    row.button = StoneSection:CreateButton({
        Name = "Batu",
        Desc = "Menyiapkan...",
        Icon = "gem",
        Callback = function()
            if autoBusy or instantBusy or placeBusy or placePrepBusy or sellBusy then
                pcall(function()
                    UI:Notify({
                        Title = "Steal manual",
                        Content = "Fitur lain sedang berjalan. Tunggu sampai selesai.",
                        Icon = "clock",
                        Type = "Info",
                        Duration = 2,
                    })
                end)
                return
            end

            if row.stone and row.prompt then
                -- Tandai busy selama steal manual supaya scheduler tidak
                -- melepas StealthHold di tengah proses.
                autoBusy = true
                local ok, result = pcall(
                    ExecuteSafeDoubleTrySteal,
                    row.stone,
                    row.prompt,
                    autoStealTeleport ~= false and not ghostActive
                )
                autoBusy = false
                if not ok and StatusLabel then
                    StatusLabel:Set("Status: steal manual error - " .. tostring(result))
                end
            end
        end,
    })

    return row
end

function UpdateRadar()
    local seen = {}
    local found = 0
    local candidates = {}
    local allStones = {}
    local root = LocalPlayer.Character and LocalPlayer.Character:FindFirstChild("HumanoidRootPart")
    local origin = root and root.Position or nil

    for _, obj in ipairs(Workspace:GetDescendants()) do
        if obj.Name == "batu" and obj:IsA("BasePart") then
            table.insert(allStones, obj)

            if trackerOn then
                TrackPlacedStone(obj)
            end

            local prompt = obj:FindFirstChild("CustomPromptAttachment")
                and obj.CustomPromptAttachment:FindFirstChild("CustomPrompt")

            if prompt and prompt:IsA("ProximityPrompt") and not seen[obj] then
                seen[obj] = true
                found = found + 1

                local row = rows[obj]
                if not row then
                    row = CreateStoneRow(obj)
                    rows[obj] = row
                end

                row.prompt = prompt

                local position = obj.Position
                local rarityAttr = obj:GetAttribute("Rarity")
                local rarity = rarityAttr or "Moving Batu"

                if rarityAttr ~= nil then
                    RegisterRarity(rarityAttr)
                end

                row.button:SetTitle(string.format("#%d [%s]", found, tostring(rarity)))
                row.button:SetDesc(string.format(
                    "X: %.1f, Y: %.1f, Z: %.1f",
                    position.X,
                    position.Y,
                    position.Z
                ))

                local onCooldown = false
                if autoStealOn then
                    local untilAt = autoCooldown[obj]
                    onCooldown = untilAt ~= nil and os.time() < untilAt
                elseif instantStealOn then
                    local untilAt = instantAttempted[obj]
                    onCooldown = untilAt ~= nil and os.time() < untilAt
                end

                if (autoStealOn or instantStealOn)
                    and rarityAttr ~= nil
                    and IsRaritySelected(rarityAttr)
                    and prompt.Enabled ~= false
                    and not onCooldown
                then
                    table.insert(candidates, {
                        stone = obj,
                        prompt = prompt,
                        rarity = rarity,
                        score = RarityRank(rarity),
                        distance = origin and (position - origin).Magnitude or math.huge,
                    })
                end
            end
        end
    end

    -- Hapus baris yang batunya sudah tidak ada
    for stone, row in pairs(rows) do
        if not seen[stone] then
            row.button:Destroy()
            rows[stone] = nil
        end
    end

    for stone in pairs(autoCooldown) do
        if not seen[stone] then
            autoCooldown[stone] = nil
        end
    end

    for stone in pairs(instantAttempted) do
        if not seen[stone] then
            instantAttempted[stone] = nil
        end
    end

    cachedStoneParts = allStones
    stoneCacheReady = true

    local grinderStates = ComputeGrinderStates(GetNearbyGrinders(), allStones)
    UpdatePlacementStatus(grinderStates)

    StoneSection:Set("Batu Terdeteksi (" .. found .. ")")
    EmptyLabel:SetVisible(found == 0)

    if not AnyAutomationBusy() and not smartSafeMode then
        if found > 0 then
            StatusLabel:Set("Status: Ditemukan " .. found .. " batu aktif!")
        else
            StatusLabel:Set("Status: Tidak ada batu aktif.")
        end
    end

    -- Mode steal yang aktif tidak boleh jalan saat batu dipegang; Auto Place
    -- yang mengambil alih.
    local heldStone = nil
    if autoStealOn or instantStealOn then
        heldStone = FindHeldStone and FindHeldStone() or nil
    end

    if heldStone and not AnyAutomationBusy() and not smartSafeMode then
        if StatusLabel then
            StatusLabel:Set((autoStealOn and "Status: Auto Steal"
                or "Status: Auto Instant Steal")
                .. " skip - sedang memegang batu.")
        end
    end

    -- Fungsi ini hanya memindai dan menyiapkan kandidat. Penentuan fitur mana
    -- yang jalan dilakukan oleh RunAutomationScheduler.
    return candidates, grinderStates, origin
end


-- =====================================================================
-- 5. BACKGROUND REFRESH LOOP
-- =====================================================================
_G.DoubleStealActive = true

task.spawn(function()
    while running and _G.DoubleStealActive do
        -- Cek Smart lebih dulu: saat ada pemain lain, semua aksi batu dihentikan
        -- sebelum radar sempat memulai steal/place baru.
        pcall(UpdateSmartProtection)

        -- Radar tetap memindai walau window disembunyikan. Auto Sell saja tidak
        -- perlu scan batu; scheduler tetap memanggilnya tanpa data radar.
        local candidates, grinderStates, origin
        local needScan = autoStealOn
            or instantStealOn
            or autoPlaceOn
            or trackerOn
            or (autoRefreshOn and Window:IsOpen())

        if needScan then
            local ok, scanCandidates, scanStates, scanOrigin = pcall(UpdateRadar)
            if ok then
                candidates = scanCandidates
                grinderStates = scanStates
                origin = scanOrigin
            end
        end

        pcall(RunAutomationScheduler, candidates, grinderStates, origin)
        task.wait(REFRESH_INTERVAL)
    end
end)

print("[Myshi Hub] Auto Steal + Instant Steal + Smart + Auto Place + Sell Shop + Tracker + Config Ready (Compact UI)!")
