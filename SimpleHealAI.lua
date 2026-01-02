--[[
    SimpleHealAI - Auto-Target, Auto-Rank Healing Addon
    Vanilla WoW 1.12
    
    Supports: Shaman, Priest, Paladin, Druid
    
    Usage:
        /heal        - Smart heal (finds lowest HP party/raid member, picks best rank)
        /sheal       - (alias) Same as /heal
        /healai help - Show commands
]]

SimpleHealAI = {}
SimpleHealAI.Spells = {}  -- {Wave = {}, Lesser = {}}
SimpleHealAI.Ready = false
SimpleHealAI.SuperWoW = nil  -- nil = unchecked, true/false after check
SimpleHealAI.LastAnnounce = nil  -- For spam reduction

--[[ ================================================================
    SUPERWOW DETECTION - Enhanced range/LoS when available
================================================================ ]]

function SimpleHealAI:CheckSuperWoW()
    if SimpleHealAI.SuperWoW ~= nil then
        return SimpleHealAI.SuperWoW
    end
    
    -- Check for SuperWoW indicators
    local hasIt = (SUPERWOW_VERSION ~= nil) or 
                  (type(UnitXP) == "function") or 
                  (type(UnitPosition) == "function")
    
    SimpleHealAI.SuperWoW = hasIt
    
    if hasIt then
        DEFAULT_CHAT_FRAME:AddMessage("|cff00ff00[SimpleHealAI]|r SuperWoW detected - enhanced range/LoS active")
    end
    
    return hasIt
end

function SimpleHealAI:GetUnitDistance(unit)
    if not SimpleHealAI:CheckSuperWoW() then return nil end
    if not UnitXP then return nil end
    
    local ok, dist = pcall(function() return UnitXP(unit, "range") end)
    if ok and dist and type(dist) == "number" and dist < 500 then
        return dist
    end
    return nil
end

function SimpleHealAI:IsInLineOfSight(unit)
    if not SimpleHealAI:CheckSuperWoW() then return nil end
    if not UnitXP then return nil end
    
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
    -- MsgMode: 0=off, 1=all, 2=new target only (default)
    if SimpleHealAI_Saved.MsgMode == nil then SimpleHealAI_Saved.MsgMode = 2 end
    if SimpleHealAI_Saved.Threshold == nil then SimpleHealAI_Saved.Threshold = 90 end
    if SimpleHealAI_Saved.HealMode == nil then SimpleHealAI_Saved.HealMode = 1 end  -- 1=efficient, 2=smart
    if SimpleHealAI_Saved.UseLOS == nil then SimpleHealAI_Saved.UseLOS = true end
end

function SimpleHealAI:Announce(targetName, spellName, rank)
    local mode = SimpleHealAI_Saved and SimpleHealAI_Saved.MsgMode or 2
    
    if mode == 0 then return end  -- Silent mode
    if mode == 2 and targetName == SimpleHealAI.LastAnnounce then return end  -- New target only
    
    SimpleHealAI.LastAnnounce = targetName
    DEFAULT_CHAT_FRAME:AddMessage("|cff00ff00[SimpleHealAI]|r " .. targetName .. " <- " .. spellName .. " R" .. rank)
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
                
                table.insert(SimpleHealAI.Spells[spellType], {
                    id = i,
                    name = spellName,
                    rank = rankNum,
                    mana = mana,
                    avg = avgHeal,
                    min = minHeal,
                    max = maxHeal,
                    hpm = avgHeal / mana  -- Heal Per Mana efficiency
                })
            end
        end
        i = i + 1
    end
    
    -- Sort by rank (low to high) so we can pick optimal
    table.sort(SimpleHealAI.Spells.Wave, function(a,b) return a.rank < b.rank end)
    table.sort(SimpleHealAI.Spells.Lesser, function(a,b) return a.rank < b.rank end)
    
    local total = table.getn(SimpleHealAI.Spells.Wave) + table.getn(SimpleHealAI.Spells.Lesser)
    DEFAULT_CHAT_FRAME:AddMessage("|cff00ff00[SimpleHealAI]|r Found " .. total .. " healing spells.")
    SimpleHealAI.Ready = (total > 0)
end

function SimpleHealAI:GetSpellType(name, class)
    local n = string.lower(name)
    
    if class == "SHAMAN" then
        if string.find(n, "lesser healing wave") then return "Lesser" end
        if string.find(n, "chain heal") then return "Lesser" end  -- Fast, multi-target
        if string.find(n, "healing wave") then return "Wave" end
    elseif class == "PRIEST" then
        if string.find(n, "flash heal") then return "Lesser" end
        if string.find(n, "greater heal") or n == "heal" or string.find(n, "lesser heal") then return "Wave" end
    elseif class == "PALADIN" then
        if string.find(n, "flash of light") then return "Lesser" end
        if string.find(n, "holy shock") then return "Lesser" end  -- Instant (talent)
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
    
    -- Line 2 usually has mana cost
    local line2 = SimpleHealAI_TooltipTextLeft2
    if line2 then
        local text = line2:GetText()
        if text then
            local _, _, m = string.find(text, "(%d+) Mana")
            mana = tonumber(m)
        end
    end
    
    -- Scan lines 3-8 for heal values
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
    
    -- Find best target
    local target = SimpleHealAI:FindBestTarget()
    if not target then
        DEFAULT_CHAT_FRAME:AddMessage("|cff00ff00[SimpleHealAI]|r No one needs healing.")
        return
    end
    
    -- Calculate deficit
    local deficit = target.max - target.current
    
    -- Pick spell
    local spellList = useFast and SimpleHealAI.Spells.Lesser or SimpleHealAI.Spells.Wave
    
    -- If no spells in preferred list, fallback to other
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
    
    -- Save current target
    local hadTarget = UnitExists("target")
    local savedTarget = nil
    if hadTarget then
        savedTarget = SimpleHealAI:GetTargetInfo()
    end
    
    -- Target and cast
    TargetUnit(target.unit)
    CastSpell(spell.id, BOOKTYPE_SPELL)
    
    -- Restore target
    if hadTarget and savedTarget then
        SimpleHealAI:RestoreTarget(savedTarget)
    elseif not hadTarget then
        ClearTarget()
    end
    
    SimpleHealAI:Announce(target.name, spell.name, spell.rank)
end

function SimpleHealAI:FindBestTarget()
    local candidates = {}
    local threshold = (SimpleHealAI_Saved and SimpleHealAI_Saved.Threshold or 90) / 100
    
    -- Check player
    SimpleHealAI:AddCandidate(candidates, "player")
    
    -- Check party
    for i = 1, GetNumPartyMembers() do
        SimpleHealAI:AddCandidate(candidates, "party" .. i)
    end
    
    -- Check raid
    for i = 1, GetNumRaidMembers() do
        SimpleHealAI:AddCandidate(candidates, "raid" .. i)
    end
    
    -- Filter and sort - lowest HP% first
    local valid = {}
    for _, c in ipairs(candidates) do
        if c.ratio < threshold then
            table.insert(valid, c)
        end
    end
    
    if table.getn(valid) == 0 then return nil end
    
    table.sort(valid, function(a, b) return a.ratio < b.ratio end)
    
    -- Find first reachable target
    for _, c in ipairs(valid) do
        if SimpleHealAI:CanReach(c.unit) then
            return c
        end
    end
    
    return nil
end

function SimpleHealAI:AddCandidate(list, unit)
    if not UnitExists(unit) then return end
    if UnitIsDeadOrGhost(unit) then return end
    if UnitIsPlayer(unit) and not UnitIsConnected(unit) then return end
    if not UnitIsFriend("player", unit) then return end
    
    local cur = UnitHealth(unit)
    local max = UnitHealthMax(unit)
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
    if UnitIsUnit(unit, "player") then return true end
    if not UnitExists(unit) then return false end
    if not UnitIsVisible(unit) then return false end
    
    -- SuperWoW: precise 40-yard range check
    local dist = SimpleHealAI:GetUnitDistance(unit)
    if dist then
        if dist > 40 then return false end  -- Out of healing range
    end
    
    -- SuperWoW: line-of-sight check
    if SimpleHealAI_Saved and SimpleHealAI_Saved.UseLOS then
        local los = SimpleHealAI:IsInLineOfSight(unit)
        if los == false then return false end  -- Definitely blocked
    end
    
    -- Fallback: CheckInteractDistance(unit, 4) = ~28 yards
    -- Only use if SuperWoW didn't give us distance
    if not dist then
        if not CheckInteractDistance(unit, 4) then return false end
    end
    
    return true
end

function SimpleHealAI:PickBestRank(spellList, deficit)
    local playerMana = UnitMana("player")
    local mode = SimpleHealAI_Saved and SimpleHealAI_Saved.HealMode or 1
    
    -- Build list of affordable spells
    local affordable = {}
    for _, spell in ipairs(spellList) do
        if spell.mana <= playerMana then
            table.insert(affordable, spell)
        end
    end
    
    if table.getn(affordable) == 0 then return nil end
    
    -- MODE 1: Most Efficient (best ratio of effective healing / mana)
    if mode == 1 then
        local bestSpell = nil
        local bestEfficiency = -1
        
        for _, spell in ipairs(affordable) do
            local effectiveHeal = math.min(spell.avg, deficit)
            local efficiency = effectiveHeal / spell.mana
            -- If efficiency is equal, prefer higher rank
            if efficiency >= bestEfficiency then
                bestEfficiency = efficiency
                bestSpell = spell
            end
        end
        return bestSpell
    
    -- MODE 2: Smart Match (smallest spell that covers deficit, avoids overhealing)
    else
        table.sort(affordable, function(a,b) return a.rank < b.rank end)
        for _, spell in ipairs(affordable) do
            if spell.avg >= deficit then
                return spell
            end
        end
        -- Fallback to max rank
        return affordable[table.getn(affordable)]
    end
end

--[[ ================================================================
    TARGET SAVE/RESTORE
================================================================ ]]

function SimpleHealAI:GetTargetInfo()
    if not UnitExists("target") then return nil end
    
    local info = { name = UnitName("target"), unit = nil }
    
    -- Try to find unit ID
    if UnitIsUnit("target", "player") then
        info.unit = "player"
    else
        for i = 1, GetNumPartyMembers() do
            if UnitIsUnit("target", "party" .. i) then
                info.unit = "party" .. i
                return info
            end
        end
        for i = 1, GetNumRaidMembers() do
            if UnitIsUnit("target", "raid" .. i) then
                info.unit = "raid" .. i
                return info
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
    if SimpleHealAI_ConfigFrame:IsVisible() then
        SimpleHealAI_ConfigFrame:Hide()
    else
        SimpleHealAI_ConfigFrame:Show()
    end
end

function SimpleHealAI:RefreshConfig()
    local msgMode = SimpleHealAI_Saved and SimpleHealAI_Saved.MsgMode or 2
    local healMode = SimpleHealAI_Saved and SimpleHealAI_Saved.HealMode or 1
    local thresh = SimpleHealAI_Saved and SimpleHealAI_Saved.Threshold or 90
    
    -- Heal mode buttons
    SimpleHealAI_ModeEff:SetText(healMode == 1 and "|cff00ff00Eff|r" or "Eff")
    SimpleHealAI_ModeSmart:SetText(healMode == 2 and "|cff00ff00Smart|r" or "Smart")
    
    -- LOS button
    local useLOS = SimpleHealAI_Saved and SimpleHealAI_Saved.UseLOS
    SimpleHealAI_ModeLOS:SetText(useLOS and "|cff00ff00LOS: On|r" or "LOS: Off")
    
    -- Msg mode buttons
    SimpleHealAI_MsgOff:SetText(msgMode == 0 and "|cff00ff00Off|r" or "Off")
    SimpleHealAI_MsgAll:SetText(msgMode == 1 and "|cff00ff00All|r" or "All")
    SimpleHealAI_MsgNew:SetText(msgMode == 2 and "|cff00ff00New|r" or "New")
    
    -- Threshold slider
    SimpleHealAI_ThreshSlider:SetValue(thresh)
    getglobal("SimpleHealAI_ThreshSliderText"):SetText(thresh .. "%")
end

function SimpleHealAI:SetHealMode(mode)
    if not SimpleHealAI_Saved then SimpleHealAI_Saved = {} end
    SimpleHealAI_Saved.HealMode = mode
    SimpleHealAI:RefreshConfig()
    
    local names = {[1]="Efficient (best HPM)", [2]="Smart Match"}
    DEFAULT_CHAT_FRAME:AddMessage("|cff00ff00[SimpleHealAI]|r Mode: " .. (names[mode] or "?"))
end

function SimpleHealAI:ToggleLOS()
    if not SimpleHealAI_Saved then SimpleHealAI_Saved = {} end
    SimpleHealAI_Saved.UseLOS = not SimpleHealAI_Saved.UseLOS
    SimpleHealAI:RefreshConfig()
    
    local status = SimpleHealAI_Saved.UseLOS and "|cff00ff00Enabled|r" or "|cffff0000Disabled|r"
    DEFAULT_CHAT_FRAME:AddMessage("|cff00ff00[SimpleHealAI]|r Line of Sight check: " .. status)
end

function SimpleHealAI:SetMsgMode(mode)
    if not SimpleHealAI_Saved then SimpleHealAI_Saved = {} end
    SimpleHealAI_Saved.MsgMode = mode
    SimpleHealAI:RefreshConfig()
    
    local names = {[0]="Off", [1]="All heals", [2]="New target only"}
    DEFAULT_CHAT_FRAME:AddMessage("|cff00ff00[SimpleHealAI]|r Messages: " .. (names[mode] or "?"))
end

function SimpleHealAI:OnThresholdChange(val)
    if not SimpleHealAI_Saved then SimpleHealAI_Saved = {} end
    val = math.floor(val)
    SimpleHealAI_Saved.Threshold = val
    getglobal("SimpleHealAI_ThreshSliderText"):SetText(val .. "%")
end
