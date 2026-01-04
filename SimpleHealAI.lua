--[[
    SimpleHealAI - Auto-Target, Auto-Rank Healing Addon
    Vanilla WoW 1.12
    
    Supports: Shaman, Priest, Paladin, Druid
    
    Usage:
        /heal        - Smart heal (lowest HP target, best efficiency)
        /sheal       - (alias) Same as /heal
        /heal config - Open settings (Modes: Efficient/Smart, LOS Toggle, Dispel)
        /heal help   - Show commands
]]

SimpleHealAI = {}
SimpleHealAI.Spells = {}  -- {Wave = {}, Lesser = {}}
SimpleHealAI.Ready = false
SimpleHealAI.ExtendedAPI = nil -- nil = unchecked, true/false after check
SimpleHealAI.LastAnnounce = nil  -- For spam reduction

--[[ ================================================================
    SUPERWOW DETECTION - Enhanced range/LoS when available
================================================================ ]]

function SimpleHealAI:HasExtendedAPI()
    if SimpleHealAI.ExtendedAPI ~= nil then
        return SimpleHealAI.ExtendedAPI
    end
    
    local hasIt = (SUPERWOW_VERSION ~= nil) or 
                  (type(UnitXP) == "function") or 
                  (type(UnitPosition) == "function") or
                  (type(SpellInfo) == "function")
    
    SimpleHealAI.ExtendedAPI = hasIt
    
    if hasIt then
        DEFAULT_CHAT_FRAME:AddMessage("|cff00ff00[SimpleHealAI]|r Extended API (SuperWoW/UnitXP) detected.")
    end
    
    return hasIt
end

function SimpleHealAI:GetUnitDistance(unit)
    if not SimpleHealAI:HasExtendedAPI() then return nil end
    
    -- Try UnitXP first (most accurate, factors in combat reach)
    if type(UnitXP) == "function" then
        local ok, dist = pcall(function() return UnitXP(unit, "range") end)
        if ok and dist and type(dist) == "number" and dist < 500 then
            return dist
        end
    end
    
    -- Fallback to UnitPosition (manual 3D distance)
    if type(UnitPosition) == "function" then
        local x1, y1, z1 = UnitPosition("player")
        local x2, y2, z2 = UnitPosition(unit)
        if x1 and x2 then
            local dx, dy, dz = x1-x2, y1-y2, z1-z2
            return math.sqrt(dx*dx + dy*dy + dz*dz)
        end
    end
    
    return nil
end

function SimpleHealAI:IsInLineOfSight(unit)
    if not SimpleHealAI:HasExtendedAPI() then return nil end
    if type(UnitXP) ~= "function" then return nil end
    
    local ok, los = pcall(function() return UnitXP(unit, "los") end)
    if ok and los ~= nil then
        return los
    end
    return nil
end

--[[ ================================================================
    INITIALIZATION & SETTINGS
================================================================ ]]

function SimpleHealAI:OnLoad()
    SimpleHealAI_Frame:RegisterEvent("PLAYER_ENTERING_WORLD")
    SimpleHealAI_Frame:RegisterEvent("SPELLS_CHANGED")
    SimpleHealAI_Frame:RegisterEvent("VARIABLES_LOADED")
    
    SlashCmdList["SIMPLEHEALAI"] = SimpleHealAI.SlashHandler
    SLASH_SIMPLEHEALAI1 = "/heal"
    SLASH_SIMPLEHEALAI2 = "/sheal"
    SLASH_SIMPLEHEALAI3 = "/healai"
    
    DEFAULT_CHAT_FRAME:AddMessage("|cff00ff00[SimpleHealAI]|r Loaded. /heal config for options.")
end

function SimpleHealAI:OnEvent(event)
    if event == "VARIABLES_LOADED" then
        SimpleHealAI:LoadSettings()
    elseif event == "PLAYER_ENTERING_WORLD" or event == "SPELLS_CHANGED" then
        SimpleHealAI:ScanSpells()
    end
end

function SimpleHealAI:LoadSettings()
    if not SimpleHealAI_Saved then SimpleHealAI_Saved = {} end
    if SimpleHealAI_Saved.MsgMode == nil then SimpleHealAI_Saved.MsgMode = 2 end
    if SimpleHealAI_Saved.Threshold == nil then SimpleHealAI_Saved.Threshold = 90 end
    if SimpleHealAI_Saved.HealMode == nil then SimpleHealAI_Saved.HealMode = 1 end
    if SimpleHealAI_Saved.UseLOS == nil then SimpleHealAI_Saved.UseLOS = true end
end

function SimpleHealAI:Announce(targetName, spellName, rank)
    local mode = SimpleHealAI_Saved and SimpleHealAI_Saved.MsgMode or 2
    if mode == 0 then return end
    
    local announceKey = targetName .. "_" .. (rank or "0")
    if mode == 2 and announceKey == SimpleHealAI.LastAnnounce then return end
    
    SimpleHealAI.LastAnnounce = announceKey
    DEFAULT_CHAT_FRAME:AddMessage("|cff00ff00[SimpleHealAI]|r " .. targetName .. " <- " .. spellName .. (rank and " R" .. rank or ""))
end

function SimpleHealAI.SlashHandler(msg)
    msg = string.lower(msg or "")
    if msg == "help" then
        DEFAULT_CHAT_FRAME:AddMessage("|cff00ff00[SimpleHealAI]|r Commands:")
        DEFAULT_CHAT_FRAME:AddMessage("  /heal - Auto-heal")
        DEFAULT_CHAT_FRAME:AddMessage("  /heal fast - Fast heal")
        DEFAULT_CHAT_FRAME:AddMessage("  /heal config - Settings")
    elseif msg == "fast" then
        SimpleHealAI:DoHeal(true)
    elseif msg == "scan" then
        SimpleHealAI:ScanSpells()
    elseif msg == "config" or msg == "options" then
        SimpleHealAI:ToggleConfig()
    else
        SimpleHealAI:DoHeal(false)
    end
end

--[[ ================================================================
    SPELL SCANNING - Finds all healing spells in spellbook
================================================================ ]]

function SimpleHealAI:ScanSpells()
    SimpleHealAI.Spells = {Wave = {}, Lesser = {}}
    
    local _, class = UnitClass("player")
    local validClasses = {SHAMAN=1, PRIEST=1, PALADIN=1, DRUID=1}
    
    if not validClasses[class] then
        DEFAULT_CHAT_FRAME:AddMessage("|cff00ff00[SimpleHealAI]|r Your class cannot heal.")
        return
    end
    
    local i = 1
    while true do
        local spellName, spellRank = GetSpellName(i, BOOKTYPE_SPELL)
        if not spellName then break end
        
        local spellType = SimpleHealAI:GetSpellType(spellName, class)
        if spellType then
            local mana, minHeal, maxHeal = SimpleHealAI:ParseSpellTooltip(i)
            if mana and minHeal and maxHeal then
                local rankNum = SimpleHealAI:ExtractRank(spellRank)
                local avgHeal = (minHeal + maxHeal) / 2
                
                local spellData = {
                    id = i,
                    name = spellName,
                    rank = rankNum,
                    mana = mana,
                    avg = avgHeal,
                    min = minHeal,
                    max = maxHeal,
                    hpm = avgHeal / mana
                }
                
                spellData.range = 40
                table.insert(SimpleHealAI.Spells[spellType], spellData)
            end
        end
        i = i + 1
    end
    
    table.sort(SimpleHealAI.Spells.Wave, function(a,b) return a.rank < b.rank end)
    table.sort(SimpleHealAI.Spells.Lesser, function(a,b) return a.rank < b.rank end)
    
    local total = table.getn(SimpleHealAI.Spells.Wave) + table.getn(SimpleHealAI.Spells.Lesser)
    -- DEFAULT_CHAT_FRAME:AddMessage("|cff00ff00[SimpleHealAI]|r Found " .. total .. " healing spells.")
    SimpleHealAI.Ready = (total > 0)
end

function SimpleHealAI:GetSpellType(name, class)
    local n = string.lower(name)
    if class == "SHAMAN" then
        if string.find(n, "lesser healing wave") then return "Lesser" end
        if string.find(n, "chain heal") then return "Lesser" end 
        if string.find(n, "healing wave") then return "Wave" end
    elseif class == "PRIEST" then
        if string.find(n, "flash heal") then return "Lesser" end
        if string.find(n, "greater heal") or n == "heal" or string.find(n, "lesser heal") then return "Wave" end
    elseif class == "PALADIN" then
        if string.find(n, "flash of light") then return "Lesser" end
        if string.find(n, "holy shock") then return "Lesser" end 
        if string.find(n, "holy light") then return "Wave" end
    elseif class == "DRUID" then
        if string.find(n, "regrowth") then return "Lesser" end
        if string.find(n, "healing touch") then return "Wave" end
    end
    return nil
end

function SimpleHealAI:ExtractRank(rankStr)
    if not rankStr then return 1 end
    local _, _, num = string.find(rankStr, "(%d+)")
    return tonumber(num) or 1
end

function SimpleHealAI:ParseSpellTooltip(spellID)
    SimpleHealAI_Tooltip:SetOwner(UIParent, "ANCHOR_NONE")
    SimpleHealAI_Tooltip:ClearLines()
    SimpleHealAI_Tooltip:SetSpell(spellID, BOOKTYPE_SPELL)
    
    local mana, minHeal, maxHeal
    local line2 = SimpleHealAI_TooltipTextLeft2
    if line2 then
        local text = line2:GetText()
        if text then
            local _, _, m = string.find(text, "(%d+) Mana")
            mana = tonumber(m)
        end
    end
    
    for j = 3, 8 do
        local line = getglobal("SimpleHealAI_TooltipTextLeft" .. j)
        if line then
            local text = line:GetText()
            if text then
                local _, _, min = string.find(text, "(%d+) to")
                local _, _, max = string.find(text, "to (%d+)")
                if min and max then
                    minHeal = tonumber(min)
                    maxHeal = tonumber(max)
                    break
                end
            end
        end
    end
    
    SimpleHealAI_Tooltip:Hide()
    return mana, minHeal, maxHeal
end

--[[ ================================================================
    HEALING LOGIC - Find target, pick spell, cast
================================================================ ]]

function SimpleHealAI:DoHeal(useFast)
    if not SimpleHealAI.Ready then
        DEFAULT_CHAT_FRAME:AddMessage("|cffff0000[SimpleHealAI]|r No spells found. Try /heal scan")
        return
    end
    
    local target = SimpleHealAI:FindBestTarget()
    if not target then
        DEFAULT_CHAT_FRAME:AddMessage("|cff00ff00[SimpleHealAI]|r No one needs healing.")
        return
    end
    
    local deficit = target.max - target.current
    local spellList = useFast and SimpleHealAI.Spells.Lesser or SimpleHealAI.Spells.Wave
    if table.getn(spellList) == 0 then
        spellList = useFast and SimpleHealAI.Spells.Wave or SimpleHealAI.Spells.Lesser
    end
    
    if table.getn(spellList) == 0 then
        DEFAULT_CHAT_FRAME:AddMessage("|cffff0000[SimpleHealAI]|r No healing spells available!")
        return
    end
    
    local spell = SimpleHealAI:PickBestRank(spellList, deficit)
    if not spell then
        DEFAULT_CHAT_FRAME:AddMessage("|cffff0000[SimpleHealAI]|r Not enough mana!")
        return
    end
    
    -- Cast heal
    if SimpleHealAI:HasExtendedAPI() and type(CastSpellByName) == "function" then
        CastSpellByName(spell.name .. "(Rank " .. spell.rank .. ")", target.unit)
    else
        local hadTarget = UnitExists("target")
        local savedTarget = hadTarget and SimpleHealAI:GetTargetInfo() or nil
        TargetUnit(target.unit)
        CastSpell(spell.id, BOOKTYPE_SPELL)
        if hadTarget and savedTarget then
            SimpleHealAI:RestoreTarget(savedTarget)
        elseif not hadTarget then
            ClearTarget()
        end
    end
    
    SimpleHealAI:Announce(target.name, spell.name, spell.rank)
end

function SimpleHealAI:FindBestTarget()
    local candidates = {}
    local threshold = (SimpleHealAI_Saved and SimpleHealAI_Saved.Threshold or 90) / 100
    
    SimpleHealAI:AddCandidate(candidates, "player")
    
    local numParty = GetNumPartyMembers()
    if numParty > 0 then
        for i = 1, numParty do SimpleHealAI:AddCandidate(candidates, "party" .. i) end
    end
    
    local numRaid = GetNumRaidMembers()
    if numRaid > 0 then
        for i = 1, numRaid do SimpleHealAI:AddCandidate(candidates, "raid" .. i) end
    end
    
    local valid = {}
    for _, c in ipairs(candidates) do
        if c.ratio < threshold then table.insert(valid, c) end
    end
    
    for _, c in ipairs(valid) do
        if SimpleHealAI:CanReach(c.unit) then 
            return c 
        end
    end
    return nil
end

function SimpleHealAI:AddCandidate(list, unit)
    if not UnitExists(unit) or UnitIsDeadOrGhost(unit) then return end
    if UnitIsPlayer(unit) and not UnitIsConnected(unit) then return end
    if not UnitIsFriend("player", unit) then return end

    -- Avoid duplicates
    for _, c in ipairs(list) do
        if UnitIsUnit(c.unit, unit) then return end
    end
    
    local cur, max = UnitHealth(unit), UnitHealthMax(unit)
    if max == 0 then return end
    
    table.insert(list, {
        unit = unit,
        name = UnitName(unit),
        current = cur,
        max = max,
        ratio = cur / max
    })
end

function SimpleHealAI:CanReach(unit)
    if not UnitExists(unit) or UnitIsDeadOrGhost(unit) then return false, "Dead/Invalid" end
    if UnitIsUnit(unit, "player") then return true end
    
    -- Hardcoded 40y Check
    local dist = SimpleHealAI:GetUnitDistance(unit)
    if dist and dist > 40 then return false, "Out of Range ("..math.floor(dist).."y)" end
    
    -- LOS Check if enabled
    if SimpleHealAI_Saved and SimpleHealAI_Saved.UseLOS then
        if SimpleHealAI:IsInLineOfSight(unit) == false then return false, "Line of Sight" end
    end
    
    -- Final Range Safety (CheckInteractDistance 4 is ~28y, check is unreliable but useful as secondary)
    -- But since we want EXACT 40Y, we rely on Extended API or isSpellInRange
    local testSpellID = nil
    if SimpleHealAI.Spells.Wave[1] then testSpellID = SimpleHealAI.Spells.Wave[1].id
    elseif SimpleHealAI.Spells.Lesser[1] then testSpellID = SimpleHealAI.Spells.Lesser[1].id end
    
    if testSpellID and IsSpellInRange then
        if IsSpellInRange(testSpellID, BOOKTYPE_SPELL, unit) ~= 1 then
            return false, "Out of Range"
        end
    elseif not dist then
        if not CheckInteractDistance(unit, 4) then
            return false, "Out of Range (>28y)"
        end
    end

    return true
end

function SimpleHealAI:PickBestRank(spellList, deficit)
    local power, mana = UnitMana("player")
    local playerMana = mana or power
    local mode = SimpleHealAI_Saved and SimpleHealAI_Saved.HealMode or 1
    
    local affordable = {}
    for _, spell in ipairs(spellList) do
        if spell.mana <= playerMana then table.insert(affordable, spell) end
    end
    if table.getn(affordable) == 0 then return nil end
    
    if mode == 1 then
        local bestSpell, bestEfficiency = nil, -1
        for _, spell in ipairs(affordable) do
            local eff = math.min(spell.avg, deficit) / spell.mana
            if eff >= bestEfficiency then
                bestEfficiency = eff
                bestSpell = spell
            end
        end
        return bestSpell
    else
        table.sort(affordable, function(a,b) return a.rank < b.rank end)
        for _, spell in ipairs(affordable) do
            if spell.avg >= deficit then return spell end
        end
        return affordable[table.getn(affordable)]
    end
end

--[[ ================================================================
    TARGET SAVE/RESTORE
================================================================ ]]

function SimpleHealAI:GetTargetInfo()
    if not UnitExists("target") then return nil end
    local info = { name = UnitName("target"), unit = nil }
    if UnitIsUnit("target", "player") then
        info.unit = "player"
    else
        for i = 1, GetNumPartyMembers() do
            if UnitIsUnit("target", "party" .. i) then info.unit = "party" .. i break end
        end
        if not info.unit then
            for i = 1, GetNumRaidMembers() do
                if UnitIsUnit("target", "raid" .. i) then info.unit = "raid" .. i break end
            end
        end
    end
    return info
end

function SimpleHealAI:RestoreTarget(info)
    if not info then return end
    if info.unit and UnitExists(info.unit) then
        TargetUnit(info.unit)
    elseif info.name then
        TargetByName(info.name)
    end
end

--[[ ================================================================
    CONFIG UI
================================================================ ]]

function SimpleHealAI:ShowTooltip(text)
    GameTooltip:SetOwner(this, "ANCHOR_RIGHT")
    GameTooltip:SetText(text, 1, 1, 1, 1, 1)
    GameTooltip:Show()
end

function SimpleHealAI:ToggleConfig()
    if SimpleHealAI_ConfigFrame:IsVisible() then SimpleHealAI_ConfigFrame:Hide() else SimpleHealAI_ConfigFrame:Show() end
end

function SimpleHealAI:RefreshConfig()
    local msgMode = SimpleHealAI_Saved and SimpleHealAI_Saved.MsgMode or 2
    local healMode = SimpleHealAI_Saved and SimpleHealAI_Saved.HealMode or 1
    local thresh = SimpleHealAI_Saved and SimpleHealAI_Saved.Threshold or 90
    local useLOS = SimpleHealAI_Saved and SimpleHealAI_Saved.UseLOS
    
    SimpleHealAI_ModeEff:SetText(healMode == 1 and "|cff00ff00Eff|r" or "Eff")
    SimpleHealAI_ModeSmart:SetText(healMode == 2 and "|cff00ff00Smart|r" or "Smart")
    
    SimpleHealAI_ModeLOSCheck:SetChecked(useLOS)
    
    SimpleHealAI_MsgOff:SetText(msgMode == 0 and "|cff00ff00Off|r" or "Off")
    SimpleHealAI_MsgAll:SetText(msgMode == 1 and "|cff00ff00All|r" or "All")
    SimpleHealAI_MsgNew:SetText(msgMode == 2 and "|cff00ff00New|r" or "New")
    
    SimpleHealAI_ThreshSlider:SetValue(thresh)
    getglobal("SimpleHealAI_ThreshSliderText"):SetText(thresh .. "%")
end

function SimpleHealAI:SetHealMode(mode)
    if not SimpleHealAI_Saved then SimpleHealAI_Saved = {} end
    SimpleHealAI_Saved.HealMode = mode
    SimpleHealAI:RefreshConfig()
    local names = {[1]="Efficient", [2]="Smart"}
    DEFAULT_CHAT_FRAME:AddMessage("|cff00ff00[SimpleHealAI]|r Mode: " .. (names[mode] or "?"))
end

function SimpleHealAI:ToggleLOS()
    if not SimpleHealAI_Saved then SimpleHealAI_Saved = {} end
    SimpleHealAI_Saved.UseLOS = not SimpleHealAI_Saved.UseLOS
    SimpleHealAI:RefreshConfig()
    local status = SimpleHealAI_Saved.UseLOS and "|cff00ff00Enabled|r" or "|cffff0000Disabled|r"
    DEFAULT_CHAT_FRAME:AddMessage("|cff00ff00[SimpleHealAI]|r LOS check: " .. status)
end

function SimpleHealAI:SetMsgMode(mode)
    if not SimpleHealAI_Saved then SimpleHealAI_Saved = {} end
    SimpleHealAI_Saved.MsgMode = mode
    SimpleHealAI:RefreshConfig()
end

function SimpleHealAI:OnThresholdChange(val)
    if not SimpleHealAI_Saved then SimpleHealAI_Saved = {} end
    val = math.floor(val)
    SimpleHealAI_Saved.Threshold = val
    getglobal("SimpleHealAI_ThreshSliderText"):SetText(val .. "%")
end
