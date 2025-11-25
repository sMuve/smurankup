-- SmuRankUp: Automatically upgrade spell ranks on hotbar
-- WoW Classic Anniversary Edition

local ADDON_NAME = "SmuRankUp"
local DEBUG = false

-- Get the character's spell book and track learned spells
local SmuRankUp = CreateFrame("Frame")
SmuRankUp:RegisterEvent("PLAYER_LOGIN")
SmuRankUp:RegisterEvent("SPELLS_CHANGED")
SmuRankUp:RegisterEvent("PLAYER_SPECIALIZATION_CHANGED")

-- Cache: base spell name -> list of { spellID, spellName, rank }

-- Debug output
local function SRU_Debug(message)
    -- Debug output disabled to prevent chat spam
    -- if DEBUG then
    --     print("|cFF00FF00[" .. ADDON_NAME .. "]|r " .. tostring(message))
    -- end
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

-- Utility: Extracts rank from subtext or name
local function SRU_GetRank(spellID)
    local subtext = GetSpellSubtext(spellID)
    if subtext and subtext:find("Rank") then
        return subtext:match("Rank (%d+)") or subtext
    end
    local name = GetSpellInfo(spellID)
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
    local tabIndex = 1
    while true do
        local tabName, _, offset, numSpells = GetSpellTabInfo(tabIndex)
        if not tabName then break end
        for i = 1, numSpells do
            local spellIndex = offset + i
            local spellName = GetSpellBookItemName(spellIndex, BOOKTYPE_SPELL)
            if spellName then
                local _, _, _, _, _, _, spellID = GetSpellInfo(spellName)
                local rankText = GetSpellSubtext(spellIndex)
                local rank = ExtractRank(rankText)
                local baseName = GetBaseSpellName(spellName)
                if baseName and spellID then
                    if not knownSpells[baseName] then knownSpells[baseName] = {} end
                    table.insert(knownSpells[baseName], { spellID = spellID, spellName = spellName, rank = rank })
                    SRU_Debug("Found: [" .. spellIndex .. "] " .. spellName .. " (ID: " .. tostring(spellID) .. ", Rank: " .. rank .. ")")
                end
            end
        end
        tabIndex = tabIndex + 1
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
end

-- Find the highest known rank spell ID by checking sequentially
local function FindHighestKnownRank(baseName, currentRank)
    local maxRank = currentRank
    local maxSpellID = nil
    local maxSpellName = nil
    for rank = currentRank + 1, currentRank + 10 do
        local name, _, _, _, _, _, spellID = GetSpellInfo(baseName, "Rank " .. rank)
        if name and GetBaseSpellName(name) == baseName then
            maxRank = rank
            maxSpellID = spellID
            maxSpellName = name
        else
            break
        end
    end
    if maxRank > currentRank then
        return maxSpellID, maxSpellName, maxRank
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
        SmuRankUpFrame.border = CreateFrame("Frame", nil, SmuRankUpFrame, "DialogBorderDarkTemplate")
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
    for i, data in ipairs(outdatedSpells) do
        local btn = CreateFrame("Button", nil, frame, "UIPanelButtonTemplate")
        btn:SetSize(160, 32)
        btn:SetPoint("TOPLEFT", 20, yOffset)
        btn:SetText(data.newName)
        btn:SetNormalFontObject("GameFontNormal")
        btn:SetHighlightFontObject("GameFontHighlight")
        btn:Enable()
        table.insert(rankUpButtons, btn)
        -- Get the current spellID from the hotbar slot for correct rank display
        local actionType, actionID = GetActionInfo(data.slot)
        local oldRank = actionID and SRU_GetRank(actionID) or "?"
        local newRank = SRU_GetRank(data.upgradeID)
        local infoText = frame:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
        infoText:SetPoint("LEFT", btn, "RIGHT", 24, 0)
    infoText:SetText("Rank " .. oldRank .. " to Rank " .. newRank)
        infoText:SetJustifyH("LEFT")
        infoText:SetWidth(200)
        infoText:SetHeight(32)
        infoText:Show()
        btn:SetScript("OnClick", function()
            PickupSpell(data.upgradeID)
            PlaceAction(data.slot)
            ClearCursor()
            -- print("|cFF00FF00[" .. ADDON_NAME .. "]|r Upgraded slot " .. data.slot .. " to " .. data.newName) -- Disabled to prevent chat spam
            btn:Disable()
            -- Check if all our tracked buttons are now disabled
            local allDisabled = true
            for _, b in ipairs(rankUpButtons) do
                if b:IsEnabled() then
                    allDisabled = false
                    break
                end
            end
            if allDisabled then
                frame:Hide()
            end
        end)
        btn:Show()
        yOffset = yOffset - 40
    end
    frame:SetWidth(520)
    frame:SetHeight(math.abs(yOffset) + 60)
end

-- Scan hotbar and replace outdated spells
local function ScanAndUpgradeHotbar()
    SRU_Debug("Checking hotbar for outdated spell ranks...")
    outdatedSpells = {}
    for slot = 1, 120 do
        local actionType, actionID = GetActionInfo(slot)
        if actionType == "spell" then
            local spellName = GetSpellInfo(actionID)
            if spellName then
                local rankText = GetSpellSubtext(actionID)
                local currentRank = ExtractRank(rankText)
                local baseName = GetBaseSpellName(spellName)
                SRU_Debug("Slot " .. slot .. ": " .. spellName .. " (Rank " .. currentRank .. ", ID: " .. actionID .. ")")
                -- Try to find the highest known rank using GetSpellInfo(baseName, 'Rank X')
                local upgradeID, upgradeName, upgradeRank = FindHighestKnownRank(baseName, currentRank)
                if upgradeID then
                    SRU_Debug("  -> Higher rank available: " .. upgradeName .. " (Rank " .. upgradeRank .. ", ID: " .. upgradeID .. ")")
                    table.insert(outdatedSpells, {
                        slot = slot,
                        baseName = baseName,
                        oldName = spellName,
                        newName = upgradeName,
                        upgradeID = upgradeID
                    })
                else
                    SRU_Debug("  -> No upgrade needed (already highest rank or no higher rank found)")
                end
            end
        end
    end
    if #outdatedSpells > 0 then
        ShowRankUpUI(outdatedSpells)
    else
        if SmuRankUpFrame then SmuRankUpFrame:Hide() end
        if DEBUG then SRU_Debug("No outdated spells found on hotbar.") end
    end
end

-- Main handler
local function CheckAndUpgradeSpells()
	ScanSpellBook()
	ScanAndUpgradeHotbar()
end

-- Event handler
SmuRankUp:SetScript("OnEvent", function(self, event, ...)
    if event == "PLAYER_LOGIN" then
        SRU_Debug("Player logged in. Checking for outdated spells...")
        CheckAndUpgradeSpells()
    elseif event == "SPELLS_CHANGED" then
        SRU_Debug("Spell book changed. Updating hotbar...")
        CheckAndUpgradeSpells()
    elseif event == "PLAYER_SPECIALIZATION_CHANGED" then
        SRU_Debug("Specialization changed. Rechecking spells...")
        CheckAndUpgradeSpells()
    end
end)

-- Commands

SLASH_SMURANKUP1 = "/smurankup"
SLASH_SRU1 = "/sru"

local function SmuRankUp_SlashHandler(msg)
    if msg == "debug" then
        DEBUG = not DEBUG
        print("|cFF00FF00[" .. ADDON_NAME .. "]|r Debug mode: " .. (DEBUG and "|cFF00FF00ON|r" or "|cFFFF0000OFF|r"))
    elseif msg == "test" then
        print("|cFF00FF00[" .. ADDON_NAME .. "]|r Testing GetSpellInfo and GetSpellSubtext...")
        local name, rank, icon, castTime, minRange, maxRange, spellID = GetSpellInfo("Lesser Heal")
        print("  GetSpellInfo('Lesser Heal'): ID=" .. tostring(spellID) .. ", Name=" .. tostring(name))
        local rankText = GetSpellSubtext(spellID)
        print("  GetSpellSubtext(" .. spellID .. "): " .. tostring(rankText))
    else
        print("|cFF00FF00[" .. ADDON_NAME .. "]|r Checking spells...")
        CheckAndUpgradeSpells()
    end
end

SlashCmdList["SMURANKUP"] = SmuRankUp_SlashHandler
SlashCmdList["SRU"] = SmuRankUp_SlashHandler

SRU_Debug(ADDON_NAME .. " v1.0.0 loaded! Use /smurankup to check spells, /smurankup debug to toggle debug mode.")
