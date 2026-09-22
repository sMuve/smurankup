-- SmuRankUp: Automatically upgrade spell ranks on hotbar
-- Supports WoW Classic Anniversary (legacy API) and WoW Forever / Midnight backend (C_Spell / C_SpellBook API)

local ADDON_NAME = "SmuRankUp"
local DEBUG = false

-- ---------------------------------------------------------------------------
-- API compatibility layer (legacy globals vs. C_Spell / C_SpellBook)
-- ---------------------------------------------------------------------------
local HAS_C_SPELLBOOK = (C_SpellBook and C_SpellBook.GetSpellBookItemInfo) and true or false
local SPELL_BANK = (Enum and Enum.SpellBookSpellBank and Enum.SpellBookSpellBank.Player) or BOOKTYPE_SPELL or "spell"
local SPELL_ITEM_TYPE = (Enum and Enum.SpellBookItemType and Enum.SpellBookItemType.Spell) or "SPELL"

-- Returns spell name, spellID
local function Compat_GetSpellInfo(spell)
    if C_Spell and C_Spell.GetSpellInfo then
        local info = C_Spell.GetSpellInfo(spell)
        if info then return info.name, info.spellID end
        return nil
    end
    local name, _, _, _, _, _, id = GetSpellInfo(spell)
    return name, id
end

local function Compat_GetSpellSubtext(spellID)
    if C_Spell and C_Spell.GetSpellSubtext then return C_Spell.GetSpellSubtext(spellID) end
    if GetSpellSubtext then return GetSpellSubtext(spellID) end
    return nil
end

local function Compat_PickupSpell(spellID)
    if C_Spell and C_Spell.PickupSpell then return C_Spell.PickupSpell(spellID) end
    return PickupSpell(spellID)
end

-- Returns a list of { offset, numSpells } for every spell book tab
local function Compat_GetSpellTabs()
    local tabs = {}
    if C_SpellBook and C_SpellBook.GetNumSpellBookSkillLines then
        for i = 1, C_SpellBook.GetNumSpellBookSkillLines() do
            local info = C_SpellBook.GetSpellBookSkillLineInfo(i)
            if info then
                table.insert(tabs, { offset = info.itemIndexOffset, numSpells = info.numSpellBookItems })
            end
        end
    else
        local i = 1
        while true do
            local tabName, _, offset, numSpells = GetSpellTabInfo(i)
            if not tabName then break end
            table.insert(tabs, { offset = offset, numSpells = numSpells })
            i = i + 1
        end
    end
    return tabs
end

-- Get the character's spell book and track learned spells
local SmuRankUp = CreateFrame("Frame")
SmuRankUp:RegisterEvent("PLAYER_LOGIN")
SmuRankUp:RegisterEvent("SPELLS_CHANGED")

-- Cache: base spell name -> list of { spellID, spellName, rank }
local knownSpells = {}
local lastSpellSignature
local ignoredRanks -- saved variable cache
local playerReady = false
local spellIdToInfo = {}

local function ExtractSpellIDFromLink(link)
    if not link then return nil end
    local id = link:match("Hspell:(%d+):")
    return id and tonumber(id) or nil
end

local function GetSpellDataFromBookSlot(spellIndex)
    if not spellIndex then return nil end
    if HAS_C_SPELLBOOK then
        local spellName, subSpellName = C_SpellBook.GetSpellBookItemName(spellIndex, SPELL_BANK)
        if not spellName then return nil end
        local info = C_SpellBook.GetSpellBookItemInfo(spellIndex, SPELL_BANK)
        if not info or info.itemType ~= SPELL_ITEM_TYPE then return nil end
        return spellName, subSpellName, info.spellID or info.actionID
    end
    local spellName, subSpellName = GetSpellBookItemName(spellIndex, SPELL_BANK)
    if not spellName then return nil end
    local spellType, fallbackSpellID = GetSpellBookItemInfo(spellIndex, SPELL_BANK)
    if spellType ~= "SPELL" then return nil end
    local spellLink = GetSpellLink(spellIndex, SPELL_BANK)
    local spellID = ExtractSpellIDFromLink(spellLink) or fallbackSpellID
    return spellName, subSpellName, spellID
end

local function BuildSpellSignature()
    local keys = {}
    for baseName in pairs(knownSpells) do
        table.insert(keys, baseName)
    end
    table.sort(keys)
    local parts = {}
    for _, baseName in ipairs(keys) do
        local ranks = knownSpells[baseName]
        local highestRank = (ranks and ranks[#ranks] and ranks[#ranks].rank) or 0
        table.insert(parts, baseName .. ":" .. tostring(highestRank))
    end
    return table.concat(parts, "|")
end

local function EnsureIgnoredRanks()
    SmuRankUpIgnoredRanks = SmuRankUpIgnoredRanks or {}
    ignoredRanks = SmuRankUpIgnoredRanks
end

local function IsUpgradeIgnored(baseName, upgradeRank)
    if not ignoredRanks then return false end
    local highestIgnored = ignoredRanks[baseName]
    return highestIgnored and upgradeRank <= highestIgnored
end

local function IgnoreUpgrade(baseName, upgradeRank)
    EnsureIgnoredRanks()
    local current = ignoredRanks[baseName]
    if not current or upgradeRank > current then
        ignoredRanks[baseName] = upgradeRank
    end
end

-- Debug output
local function SRU_Debug(message)
    if DEBUG then
        print("|cFF00FF00[" .. ADDON_NAME .. "]|r " .. tostring(message))
    end
end

-- Helper function to count table entries
function tablecount(t)
    local count = 0
    for _ in pairs(t) do count = count + 1 end
    return count
end

-- Get the base spell name without rank suffix
local function GetBaseSpellName(spellName)
	if not spellName then return nil end
	local baseName = string.gsub(spellName, "%s+Rank%s+%d+$", "")
	return baseName
end

-- Extract rank number from text like "Rank 3"
local function ExtractRank(rankText)
	if not rankText then return 1 end
	local rank = tonumber(string.match(rankText, "Rank%s+(%d+)")) or 1
	return rank
end

local function GetActionSpellDetails(slot)
    local actionType, actionID = GetActionInfo(slot)
    if actionType ~= "spell" or not actionID then return nil end

    local spellName
    local baseName
    local currentRank

    local cached = spellIdToInfo[actionID]
    if cached then
        spellName = cached.spellName
        baseName = cached.baseName
        currentRank = cached.rank
    else
        spellName = Compat_GetSpellInfo(actionID)
        baseName = GetBaseSpellName(spellName)
    end

    if not currentRank then
        local rankText = Compat_GetSpellSubtext(actionID)
        currentRank = ExtractRank(rankText)
    end

    if spellName then
        return {
            spellName = spellName,
            baseName = baseName,
            currentRank = currentRank,
            spellID = actionID
        }
    end
end

-- Utility: Extracts rank from subtext or name
local function SRU_GetRank(spellID)
    local subtext = Compat_GetSpellSubtext(spellID)
    if subtext and subtext:find("Rank") then
        return subtext:match("Rank (%d+)") or subtext
    end
    local name = Compat_GetSpellInfo(spellID)
    if name then
        local rank = name:match("Rank (%d+)")
        if rank then return rank end
    end
    return "?"
end

-- Scan player's spell book and build cache of all spells
local function ScanSpellBook()
    SRU_Debug("Scanning spell book...")
    knownSpells = {}
    spellIdToInfo = {}
    for _, tab in ipairs(Compat_GetSpellTabs()) do
        for i = 1, tab.numSpells do
            local spellIndex = tab.offset + i
            local spellName, subSpellName, spellID = GetSpellDataFromBookSlot(spellIndex)
            if spellName and spellID then
                local rank = ExtractRank(subSpellName)
                local baseName = GetBaseSpellName(spellName)
                if baseName then
                    if not knownSpells[baseName] then knownSpells[baseName] = {} end
                    local entry = { spellID = spellID, spellName = spellName, rank = rank }
                    table.insert(knownSpells[baseName], entry)
                    spellIdToInfo[spellID] = { spellName = spellName, baseName = baseName, rank = rank }
                    SRU_Debug("Found: [" .. spellIndex .. "] " .. spellName .. " (ID: " .. tostring(spellID) .. ", Rank: " .. rank .. ")")
                end
            end
        end
    end
    -- Sort each spell's ranks by rank ascending
    for baseName, ranks in pairs(knownSpells) do
        table.sort(ranks, function(a, b) return a.rank < b.rank end)
    end
    SRU_Debug("Spell book scan complete. Found " .. tablecount(knownSpells) .. " unique spells.")
    -- Extra debug: print all ranks for Lesser Heal
    if knownSpells["Lesser Heal"] then
        for i, v in ipairs(knownSpells["Lesser Heal"]) do
            SRU_Debug("Lesser Heal rank found: " .. tostring(v.rank) .. ", ID: " .. tostring(v.spellID) .. ", Name: " .. tostring(v.spellName))
        end
    end
    return BuildSpellSignature()
end

-- Find the highest known rank spell ID by checking sequentially
local function FindHighestKnownRank(baseName, currentRank)
    local ranks = knownSpells[baseName]
    if not ranks then return nil, nil, nil end
    for i = #ranks, 1, -1 do
        local data = ranks[i]
        if data.rank > currentRank then
            return data.spellID, data.spellName, data.rank
        end
    end
    return nil, nil, nil
end

local outdatedSpells = {}

local function ShowRankUpUI(outdatedSpells)
    if not SmuRankUpFrame then
        SmuRankUpFrame = CreateFrame("Frame", "SmuRankUpFrame", UIParent)
        SmuRankUpFrame:SetMovable(true)
        SmuRankUpFrame:EnableMouse(true)
        SmuRankUpFrame:RegisterForDrag("LeftButton")
        SmuRankUpFrame:SetScript("OnDragStart", SmuRankUpFrame.StartMoving)
        SmuRankUpFrame:SetScript("OnDragStop", SmuRankUpFrame.StopMovingOrSizing)
        -- Add WoW-like border (edge-to-edge)
        local okBorder, border = pcall(CreateFrame, "Frame", nil, SmuRankUpFrame, "DialogBorderDarkTemplate")
        if not okBorder then
            -- Template missing on this client: fall back to a plain backdrop border
            border = CreateFrame("Frame", nil, SmuRankUpFrame, "BackdropTemplate")
            border:SetBackdrop({ edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border", edgeSize = 16 })
        end
        SmuRankUpFrame.border = border
        SmuRankUpFrame.border:SetPoint("TOPLEFT", SmuRankUpFrame, "TOPLEFT", 0, 0)
        SmuRankUpFrame.border:SetPoint("BOTTOMRIGHT", SmuRankUpFrame, "BOTTOMRIGHT", 0, 0)
        -- Add black background inside border
        SmuRankUpFrame.bg = SmuRankUpFrame:CreateTexture(nil, "BACKGROUND")
        SmuRankUpFrame.bg:SetPoint("TOPLEFT", 4, -4)
        SmuRankUpFrame.bg:SetPoint("BOTTOMRIGHT", -4, 4)
        SmuRankUpFrame.bg:SetColorTexture(0, 0, 0, 0.85)
        -- Add centered headline
        SmuRankUpFrame.headline = SmuRankUpFrame:CreateFontString(nil, "OVERLAY", "GameFontHighlightLarge")
        SmuRankUpFrame.headline:SetPoint("TOP", SmuRankUpFrame, "TOP", 0, -16)
        SmuRankUpFrame.headline:SetText("SmuRankUp")
    end
    local frame = SmuRankUpFrame
    frame:Show()
    frame:SetFrameStrata("DIALOG")
    frame:SetSize(520, 120)
    frame:SetPoint("CENTER")
    if frame.headline then frame.headline:Show() end

    -- Remove all children except border, bg, and headline
    for i, child in ipairs({frame:GetChildren()}) do
        if child ~= frame.border and child ~= frame.headline then child:Hide() end
    end

    -- Also hide previously created FontStrings/regions to avoid overlap
    for _, region in ipairs({frame:GetRegions()}) do
        if region ~= frame.headline and region ~= frame.bg then
            region:Hide()
        end
    end

    -- Add skill-style close button at bottom right
    if not frame.closeButton then
        frame.closeButton = CreateFrame("Button", nil, frame, "UIPanelButtonTemplate")
        frame.closeButton:SetSize(90, 32)
        frame.closeButton:SetText("Close")
        frame.closeButton:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", -16, 12)
        frame.closeButton:SetScript("OnClick", function() frame:Hide() end)
    else
        frame.closeButton:Show()
    end

    local yOffset = -40
    local rankUpButtons = {}
    local function HideFrameIfAllDisabled()
        for _, b in ipairs(rankUpButtons) do
            if b:IsEnabled() then
                return
            end
        end
        frame:Hide()
    end
    local function FormatRank(rankValue, spellID)
        if rankValue then
            return tostring(rankValue)
        end
        if spellID then
            local rankText = SRU_GetRank(spellID)
            if not rankText then
                return "?"
            end
            local numeric = tonumber(rankText)
            return tostring(numeric or rankText)
        end
        return "?"
    end

    for i, data in ipairs(outdatedSpells) do
        local btn = CreateFrame("Button", nil, frame, "UIPanelButtonTemplate")
        btn:SetSize(160, 32)
        btn:SetPoint("TOPLEFT", 20, yOffset)
        btn:SetText(data.newName)
        btn:SetNormalFontObject("GameFontNormal")
        btn:SetHighlightFontObject("GameFontHighlight")
        btn:Enable()
        table.insert(rankUpButtons, btn)
        local oldRank = FormatRank(data.currentRank, data.currentSpellID)
        local newRank = FormatRank(data.upgradeRank, data.upgradeID)
        local infoText = frame:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
        infoText:SetPoint("LEFT", btn, "RIGHT", 24, 0)
        infoText:SetText("Rank " .. oldRank .. " to Rank " .. newRank)
        infoText:SetJustifyH("LEFT")
        infoText:SetWidth(200)
        infoText:SetHeight(32)
        infoText:Show()
        btn:SetScript("OnClick", function()
            Compat_PickupSpell(data.upgradeID)
            PlaceAction(data.slot)
            ClearCursor()
            -- print("|cFF00FF00[" .. ADDON_NAME .. "]|r Upgraded slot " .. data.slot .. " to " .. data.newName) -- Disabled to prevent chat spam
            btn:Disable()
            HideFrameIfAllDisabled()
        end)
        btn:Show()
        local ignoreBtn = CreateFrame("Button", nil, frame, "UIPanelButtonTemplate")
        ignoreBtn:SetSize(80, 32)
        ignoreBtn:SetPoint("LEFT", infoText, "RIGHT", 16, 0)
        ignoreBtn:SetText("Ignore")
        ignoreBtn:SetScript("OnClick", function()
            IgnoreUpgrade(data.baseName, data.upgradeRank)
            btn:Disable()
            ignoreBtn:Disable()
            infoText:SetText("Ignoring until Rank " .. tostring((data.upgradeRank or 0) + 1))
            HideFrameIfAllDisabled()
        end)
        ignoreBtn:Show()
        yOffset = yOffset - 40
    end
    frame:SetWidth(520)
    frame:SetHeight(math.abs(yOffset) + 60)
end

-- Slots 1-120 cover the classic 6 action bars (main + 5 bonus/multibars).
-- WoW Forever/Midnight added bars 6-8, which use slots up to 180.
-- Scanning the extra slots is a no-op on clients that don't have them
-- (GetActionInfo returns nothing for unused slots), so one bound works everywhere.
local MAX_ACTION_SLOT = 180

local function ScanAndUpgradeHotbar(shouldShowUI)
    if shouldShowUI == nil then shouldShowUI = true end
    SRU_Debug("Checking hotbar for outdated spell ranks...")
    outdatedSpells = {}
    local ignoredCount = 0
    for slot = 1, MAX_ACTION_SLOT do
        local spellDetails = GetActionSpellDetails(slot)
        if spellDetails and spellDetails.baseName then
            local baseName = spellDetails.baseName
            local currentRank = spellDetails.currentRank or 1
            SRU_Debug("Slot " .. slot .. ": " .. tostring(spellDetails.spellName) .. " (Rank " .. currentRank .. ", ID: " .. tostring(spellDetails.spellID) .. ")")
            local upgradeID, upgradeName, upgradeRank = FindHighestKnownRank(baseName, currentRank)
            if upgradeID then
                SRU_Debug("  -> Higher rank available: " .. upgradeName .. " (Rank " .. upgradeRank .. ", ID: " .. upgradeID .. ")")
                if not IsUpgradeIgnored(baseName, upgradeRank) then
                    table.insert(outdatedSpells, {
                        slot = slot,
                        baseName = baseName,
                        oldName = spellDetails.spellName,
                        newName = upgradeName,
                        upgradeID = upgradeID,
                        upgradeRank = upgradeRank,
                        currentRank = currentRank,
                        currentSpellID = spellDetails.spellID
                    })
                else
                    SRU_Debug("  -> Upgrade ignored up to rank " .. tostring(upgradeRank))
                    ignoredCount = ignoredCount + 1
                end
            else
                SRU_Debug("  -> No upgrade needed (already highest rank or no higher rank found)")
            end
        end
    end
    local upgradeCount = #outdatedSpells
    if upgradeCount > 0 then
        if shouldShowUI then
            ShowRankUpUI(outdatedSpells)
        end
    else
        if SmuRankUpFrame then SmuRankUpFrame:Hide() end
        if DEBUG then SRU_Debug("No outdated spells found on hotbar.") end
    end
    return upgradeCount, ignoredCount
end

-- Main handler
local function CheckAndUpgradeSpells(shouldShowUI, requireNewSpellLearned)
    if shouldShowUI == nil then shouldShowUI = true end
    if not ignoredRanks then EnsureIgnoredRanks() end
    local newSignature = ScanSpellBook()
    local hasChanged = (newSignature ~= lastSpellSignature)
    lastSpellSignature = newSignature
    if requireNewSpellLearned and not hasChanged then
        return 0, 0, false
    end
    local upgradeCount, ignoredCount = ScanAndUpgradeHotbar(shouldShowUI)
    return upgradeCount, ignoredCount, hasChanged
end

StaticPopupDialogs["SMURANKUP_FOREVER_NOTICE"] = {
    text = "|cFF00FF00SmuRankUp|r\n\nSaving variables is currently not working in WoW Forever, so \"Ignore\" for spell rank ups does not persist.\n\nBlizzard is aware of the issue and working on it.",
    button1 = OKAY or "OK",
    timeout = 0,
    whileDead = true,
    hideOnEscape = true,
    preferredIndex = 3,
}

-- Event handler
SmuRankUp:SetScript("OnEvent", function(self, event, ...)
    if event == "PLAYER_LOGIN" then
        playerReady = true
        EnsureIgnoredRanks()
        if HAS_C_SPELLBOOK then
            -- WoW Forever only: SavedVariables are currently broken
            local function ShowNotice() StaticPopup_Show("SMURANKUP_FOREVER_NOTICE") end
            if C_Timer and C_Timer.After then C_Timer.After(3, ShowNotice) else ShowNotice() end
        end
        SRU_Debug("Player logged in. Checking for outdated spells...")
        CheckAndUpgradeSpells(false)
    elseif event == "SPELLS_CHANGED" then
        if not playerReady then return end
        SRU_Debug("Learned new spell. Checking for outdated spells...")
        CheckAndUpgradeSpells(true, true)
    end
end)

-- Commands

SLASH_SMURANKUP1 = "/smurankup"
SLASH_SRU1 = "/sru"

local function SmuRankUp_SlashHandler(msg)
    if msg == "debug" then
        DEBUG = not DEBUG
        print("|cFF00FF00[" .. ADDON_NAME .. "]|r Debug mode: " .. (DEBUG and "|cFF00FF00ON|r" or "|cFFFF0000OFF|r"))
    elseif msg == "slots" then
        -- Diagnostic: dump every occupied action slot so we can see the real
        -- slot numbers WoW Forever assigns to action bars 6-8.
        print("|cFF00FF00[" .. ADDON_NAME .. "]|r Scanning slots 1-300 for occupied actions...")
        local found = 0
        for slot = 1, 300 do
            local actionType, actionID = GetActionInfo(slot)
            if actionType then
                found = found + 1
                local label
                if actionType == "spell" then
                    local spellName = Compat_GetSpellInfo(actionID)
                    label = tostring(spellName) .. " (spellID " .. tostring(actionID) .. ")"
                else
                    label = actionType .. " " .. tostring(actionID)
                end
                print("  slot " .. slot .. ": " .. label)
            end
        end
        print("|cFF00FF00[" .. ADDON_NAME .. "]|r " .. found .. " occupied slot(s) found.")
    elseif msg == "test" then
        print("|cFF00FF00[" .. ADDON_NAME .. "]|r Testing GetSpellInfo and GetSpellSubtext...")
        local name, spellID = Compat_GetSpellInfo("Lesser Heal")
        print("  GetSpellInfo('Lesser Heal'): ID=" .. tostring(spellID) .. ", Name=" .. tostring(name))
        local rankText = spellID and Compat_GetSpellSubtext(spellID)
        print("  GetSpellSubtext(" .. tostring(spellID) .. "): " .. tostring(rankText))
        print("  API: " .. (HAS_C_SPELLBOOK and "C_SpellBook" or "legacy"))
    else
        print("|cFF00FF00[" .. ADDON_NAME .. "]|r Checking spells...")
        local upgradeCount, ignoredCount = CheckAndUpgradeSpells(true)
        if upgradeCount and upgradeCount > 0 then
            print("|cFF00FF00[" .. ADDON_NAME .. "]|r Found " .. upgradeCount .. " outdated spell" .. (upgradeCount == 1 and "" or "s") .. ".")
        elseif ignoredCount and ignoredCount > 0 then
            print("|cFF00FF00[" .. ADDON_NAME .. "]|r Only ignored upgrades detected (" .. ignoredCount .. ").")
        else
            print("|cFF00FF00[" .. ADDON_NAME .. "]|r No outdated spells found.")
        end
    end
end

SlashCmdList["SMURANKUP"] = SmuRankUp_SlashHandler
SlashCmdList["SRU"] = SmuRankUp_SlashHandler

SRU_Debug(ADDON_NAME .. " v1.0.0 loaded! Use /smurankup to check spells, /smurankup debug to toggle debug mode.")