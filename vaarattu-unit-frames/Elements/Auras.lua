local _, UUF = ...
local oUF = UUF.oUF

local AURA_GROUP_KEY = "UUF"

local filterModifiers = {
	RaidPlayerDispellable = "RAID_PLAYER_DISPELLABLE",
	Cancelable = "CANCELABLE",
	CancelablePlayer = "CANCELABLE",
	CrowdControl = "CROWD_CONTROL",
	CrowdControlPlayer = "CROWD_CONTROL",
	BigDefensive = "BIG_DEFENSIVE",
	BigDefensivePlayer = "BIG_DEFENSIVE",
	ExternalDefensive = "EXTERNAL_DEFENSIVE",
	ExternalDefensivePlayer = "EXTERNAL_DEFENSIVE",
	RaidInCombat = "RAID_IN_COMBAT",
	RaidInCombatPlayer = "RAID_IN_COMBAT",
	Raid = "RAID",
	RaidPlayer = "RAID",
}

local playerFilters = {
	Player = true,
	CancelablePlayer = true,
	NotCancelablePlayer = true,
	CrowdControlPlayer = true,
	BigDefensivePlayer = true,
	ExternalDefensivePlayer = true,
	RaidInCombatPlayer = true,
	RaidPlayer = true,
}

local otherFilters = {
	Cancelable = true,
	NotCancelable = true,
	CrowdControl = true,
	BigDefensive = true,
	ExternalDefensive = true,
	RaidInCombat = true,
	Raid = true,
}

local filterOrder = {
	"Player",
	"Typed",
	"RaidPlayerDispellable",
	"CancelablePlayer",
	"Cancelable",
	"NotCancelablePlayer",
	"NotCancelable",
	"CrowdControlPlayer",
	"CrowdControl",
	"BigDefensivePlayer",
	"BigDefensive",
	"ExternalDefensivePlayer",
	"ExternalDefensive",
	"RaidInCombatPlayer",
	"RaidInCombat",
	"RaidPlayer",
	"Raid",
}

local function GetAuraDB(unitFrame, unit, auraDBKey)
	local AurasDB = UUF:GetUnitDB(unitFrame, unit).Auras
	return AurasDB and AurasDB[auraDBKey]
end

local function StyleAuraButton(button, unitFrame, unit, auraDBKey)
	local AuraDB = GetAuraDB(unitFrame, unit, auraDBKey)
	if not AuraDB then return end

	button:SetSize(AuraDB.Size, AuraDB.Size)
	button.Icon:SetTexCoord(0.07, 0.93, 0.07, 0.93)
	button.Border:SetAlpha(AuraDB.ShowType and 1 or 0)

	button.Cooldown:SetDrawEdge(false)
	button.Cooldown:SetDrawSwipe(not AuraDB.DisableCooldown)
	button.Cooldown:SetReverse(true)
	button.Count:SetAlpha(AuraDB.Count.HideStacks and 0 or 1)

	local FontsDB = UUF.db.profile.General.Fonts
	button.Count:ClearAllPoints()
	button.Count:SetFont(UUF.Media.Font, AuraDB.Count.FontSize, FontsDB.FontFlag)
	button.Count:SetPoint(AuraDB.Count.Layout[1], button, AuraDB.Count.Layout[2], AuraDB.Count.Layout[3], AuraDB.Count.Layout[4])
	if FontsDB.Shadow.Enabled then
		button.Count:SetShadowColor(unpack(FontsDB.Shadow.Colour))
		button.Count:SetShadowOffset(FontsDB.Shadow.XPos, FontsDB.Shadow.YPos)
	else
		button.Count:SetShadowColor(0, 0, 0, 0)
		button.Count:SetShadowOffset(0, 0)
	end
	button.Count:SetTextColor(unpack(AuraDB.Count.Colour))
	UUF:ApplyCooldownText(button, button.Duration, unit, unitFrame)
end

local function InitializeAuraButton(button, unitFrame, unit, auraDBKey, auraType)
	button:EnableMouse(true)
	button:SetTooltipAnchorPoint("ANCHOR_CURSOR", 0, 0)
	button:SetHideTooltipInCombat(false)

	local cooldown = CreateFrame("Cooldown", "$parentCooldown", button, "CooldownFrameTemplate")
	cooldown:SetAllPoints()
	button.Cooldown = cooldown
	button:SetDurationCooldown(cooldown)

	local icon = button:CreateTexture(nil, "BORDER")
	icon:SetAllPoints()
	button.Icon = icon
	button:SetIcon(icon)

	local textParent = CreateFrame("Frame", nil, button)
	textParent:SetAllPoints()
	textParent:SetFrameLevel(cooldown:GetFrameLevel() + 1)

	local count = textParent:CreateFontString(nil, "OVERLAY", "NumberFontNormal")
	button.Count = count
	button:SetApplicationCount(count, {})

	local duration = textParent:CreateFontString(nil, "OVERLAY", "NumberFontNormal")
	button.Duration = duration
	button:SetDurationText(duration, {})

	local border = button:CreateTexture(nil, "OVERLAY")
	border:SetAllPoints()
	button.Border = border
	button:AddDispelTypeTexture(border, {
		style = Enum.CustomAuraButtonDispelTypeTextureStyle.Border,
		showWhenHarmful = true,
		showWhenHelpful = true,
		customDispelColorMap = oUF.colors.dispel,
	})

	StyleAuraButton(button, unitFrame, unit, auraDBKey)
end

local function BuildSecureFilter(AuraDB, auraType)
	local candidateFilters = {}
	if AuraDB.Blacklist then
		local excludedSpellIDs = {}
		for key, value in pairs(UUF.AURA_BLACKLIST or {}) do
			if value and type(key) == "number" then excludedSpellIDs[key] = true end
		end
		if next(excludedSpellIDs) then candidateFilters.excludeSpellIDs = excludedSpellIDs end
	end

	if AuraDB.OnlyShowPlayer then
		candidateFilters.isFromPlayerOrPlayerPet = true
		return auraType, candidateFilters
	end

	local selectedFilter
	local selectedCount = 0
	for _, filterKey in ipairs(filterOrder) do
		if AuraDB.Filters and AuraDB.Filters[filterKey] then
			selectedFilter = filterKey
			selectedCount = selectedCount + 1
		end
	end

	-- Secure candidate filters are combined with AND. The legacy options are OR-based,
	-- so showing the base set is the only non-destructive representation of a multi-select.
	if selectedCount ~= 1 then return auraType, candidateFilters end

	if selectedFilter == "Typed" then
		candidateFilters.includeDispelTypes = {
			Magic = true,
			Curse = true,
			Disease = true,
			Poison = true,
			Bleed = true,
		}
		return auraType, candidateFilters
	end

	if playerFilters[selectedFilter] then
		candidateFilters.isFromPlayerOrPlayerPet = true
	elseif otherFilters[selectedFilter] then
		candidateFilters.isFromPlayerOrPlayerPet = false
	end

	local modifier = filterModifiers[selectedFilter]
	if modifier then return auraType .. "|" .. modifier, candidateFilters end
	return auraType, candidateFilters
end

local function GetSortOptions(sorting)
	local reverse = sorting == "BLIZZARD_REVERSED" or sorting == "DURATION_REVERSED"
	local duration = sorting == "DURATION" or sorting == "DURATION_REVERSED"
	return duration and AuraContainerSortMethod.ExpirationOnly or AuraContainerSortMethod.Default,
		reverse and AuraContainerSortDirection.Reverse or AuraContainerSortDirection.Normal
end

local function ConfigureFlowLayout(container, AuraDB)
	local wrap = math.max(AuraDB.Wrap or 1, 1)
	local lineSize = (AuraDB.Size + AuraDB.Layout[5]) * wrap - AuraDB.Layout[5]
	container:SetFlowLayoutAnchorPoint(AuraDB.Layout[1])
	container:SetFlowLayoutAxis(AnchorUtil.FlowLayoutAxis.Horizontal)
	container:SetFlowLayoutMaximumLineSize(math.max(lineSize, 1))
	container:SetFlowLayoutGrowthDirection(AuraDB.GrowthDirection == "LEFT" and -1 or 1, AuraDB.WrapDirection == "DOWN" and -1 or 1)
	container:SetFlowLayoutPadding(0, 0, 0, 0)
end

local function CreateSecureAuraContainer(unitFrame, unit, nameSuffix, auraDBKey, auraType)
	local container = CreateFrame("AuraContainer", UUF:FetchFrameName(unit) .. nameSuffix, unitFrame, "CustomAuraContainerTemplate")
	container.groupKey = AURA_GROUP_KEY
	container.auraDBKey = auraDBKey
	container.auraType = auraType

	local AuraDB = GetAuraDB(unitFrame, unit, auraDBKey)
	ConfigureFlowLayout(container, AuraDB)
	local filter, candidateFilters = BuildSecureFilter(AuraDB, auraType)
	local sortMethod, sortDirection = GetSortOptions(AuraDB.Sorting)
	container:AddAuraGroup(AURA_GROUP_KEY, filter, {
		maxFrameCount = AuraDB.Num,
		candidateFilters = candidateFilters,
		sortMethod = sortMethod,
		sortDirection = sortDirection,
		layout = {
			elementSpacing = AuraDB.Layout[5],
			lineSpacing = AuraDB.Layout[5],
			elementWidth = AuraDB.Size,
			elementHeight = AuraDB.Size,
		},
		initializeFrame = function(button) InitializeAuraButton(button, unitFrame, unit, auraDBKey, auraType) end,
	})
	container:SetUnit(unitFrame.unit or unit)
	return container
end

local function ConfigureSecureAuraContainer(container, unitFrame, unit, AuraDB, anchorParent)
	local filter, candidateFilters = BuildSecureFilter(AuraDB, container.auraType)
	local sortMethod, sortDirection = GetSortOptions(AuraDB.Sorting)

	container:ClearAllPoints()
	container:SetPoint(AuraDB.Layout[1], anchorParent, AuraDB.Layout[2], AuraDB.Layout[3], AuraDB.Layout[4])
	container:SetFrameStrata(UUF:GetUnitDB(unitFrame, unit).Auras.FrameStrata)
	ConfigureFlowLayout(container, AuraDB)
	container:SetAuraGroupFilterString(AURA_GROUP_KEY, filter)
	container:SetAuraGroupCandidateFilters(AURA_GROUP_KEY, candidateFilters)
	container:SetAuraGroupMaxFrameCount(AURA_GROUP_KEY, AuraDB.Num)
	container:SetAuraGroupSortMethod(AURA_GROUP_KEY, sortMethod, sortDirection)
	container:SetAuraGroupLayout(AURA_GROUP_KEY, {
		elementSpacing = AuraDB.Layout[5],
		lineSpacing = AuraDB.Layout[5],
		elementWidth = AuraDB.Size,
		elementHeight = AuraDB.Size,
	})

	for index = 1, container:GetAuraGroupFrameCount(AURA_GROUP_KEY) do
		local button = container:GetAuraGroupFrame(AURA_GROUP_KEY, index)
		if button then StyleAuraButton(button, unitFrame, unit, container.auraDBKey) end
	end

	local unitToken = unitFrame.unit or unit
	if container:GetUnit() ~= unitToken then container:SetUnit(unitToken) end
	local enabled = AuraDB.Enabled and not UUF.AURA_TEST_MODE
	container:SetEnabled(enabled)
	container:SetShown(enabled)
	if enabled then container:UpdateAllAuras() end
end

local function ConfigurePrivateAuras(unitFrame, unit, AurasDB)
	if not AurasDB.PrivateAuras then return end
	local AuraDB = AurasDB.PrivateAuras
	local container = unitFrame.PrivateAuraContainer
	local anchorParent = AuraDB.AnchorParent == "Health" and unitFrame.Health or unitFrame
	local width = AuraDB.Size * AuraDB.Num + AuraDB.Spacing * (AuraDB.Num - 1)

	container:ClearAllPoints()
	container:SetPoint(AuraDB.Layout[1], anchorParent, AuraDB.Layout[2], AuraDB.Layout[3], AuraDB.Layout[4])
	container:SetSize(math.max(width, 1), AuraDB.Size)
	container:SetFrameStrata(AuraDB.FrameStrata)
	container.size = AuraDB.Size
	container.spacing = AuraDB.Spacing
	container.growthX = AuraDB.GrowthX
	container.growthY = AuraDB.GrowthY
	container.initialAnchor = AuraDB.InitialAnchor
	container.num = AuraDB.Num
	container.maxCols = AuraDB.Num
	container.borderScale = AuraDB.BorderScale == -1 and -100 or AuraDB.BorderScale
	container.disableCooldown = AuraDB.DisableCooldown
	container.disableCooldownText = AuraDB.DisableCooldownText

	local enabled = AuraDB.Enabled and not UUF.AURA_TEST_MODE
	if enabled then
		unitFrame.PrivateAuras = container
		container:Show()
		if not unitFrame:IsElementEnabled("PrivateAuras") then unitFrame:EnableElement("PrivateAuras") end
		if container.ForceUpdate then container:ForceUpdate() end
	else
		if unitFrame:IsElementEnabled("PrivateAuras") then unitFrame:DisableElement("PrivateAuras") end
		unitFrame.PrivateAuras = nil
		container:Hide()
	end
end

function UUF:UpdateUnitAuras(unitFrame, unit)
	if not unit or not unitFrame then return end
	local AurasDB = UUF:GetUnitDB(unitFrame, unit).Auras
	if not AurasDB then return end

	local BuffsDB = AurasDB.Buffs
	local DebuffsDB = AurasDB.Debuffs
	local CustomDB = AurasDB.Custom
	ConfigureSecureAuraContainer(unitFrame.BuffContainer, unitFrame, unit, BuffsDB, BuffsDB.AnchorParent == "Health" and unitFrame.Health or unitFrame)
	ConfigureSecureAuraContainer(unitFrame.DebuffContainer, unitFrame, unit, DebuffsDB, DebuffsDB.AnchorParent == "Health" and unitFrame.Health or unitFrame)
	if unitFrame.CustomAuraContainer and CustomDB then
		unitFrame.CustomAuraContainer.auraType = CustomDB.Type == "Debuffs" and "HARMFUL" or "HELPFUL"
		ConfigureSecureAuraContainer(unitFrame.CustomAuraContainer, unitFrame, unit, CustomDB, CustomDB.AnchorParent == "Health" and unitFrame.Health or unitFrame)
	end
	ConfigurePrivateAuras(unitFrame, unit, AurasDB)

	if UUF.AURA_TEST_MODE then UUF:CreateTestAuras(unitFrame, unit) end
end

function UUF:CreateUnitAuras(unitFrame, unit)
	local AurasDB = UUF:GetUnitDB(unitFrame, unit).Auras
	unitFrame.BuffContainer = CreateSecureAuraContainer(unitFrame, unit, "_BuffsContainer", "Buffs", "HELPFUL")
	unitFrame.DebuffContainer = CreateSecureAuraContainer(unitFrame, unit, "_DebuffsContainer", "Debuffs", "HARMFUL")
	if AurasDB.Custom then
		local auraType = AurasDB.Custom.Type == "Debuffs" and "HARMFUL" or "HELPFUL"
		unitFrame.CustomAuraContainer = CreateSecureAuraContainer(unitFrame, unit, "_CustomAurasContainer", "Custom", auraType)
	end
	if AurasDB.PrivateAuras then
		unitFrame.PrivateAuraContainer = CreateFrame("Frame", UUF:FetchFrameName(unit) .. "_PrivateAurasContainer", unitFrame)
	end
	UUF:UpdateUnitAuras(unitFrame, unit)
end

function UUF:UpdateUnitAurasStrata(unit)
	if not unit then return end
	local normalizedUnit = UUF:GetNormalizedUnit(unit)
	local unitFrame = UUF[unit:upper()]
	local unitDB = UUF.db.profile.Units[normalizedUnit]
	if unit == "party" then
		if not unitDB or not unitDB.Auras then return end
		for i = 1, UUF.MAX_PARTY_FRAMES do UUF:UpdateUnitAurasStrata("party" .. i) end
		if UUF.PARTYPLAYER and unitDB.Auras.PrivateAuras and UUF.PARTYPLAYER.PrivateAuraContainer then UUF.PARTYPLAYER.PrivateAuraContainer:SetFrameStrata(unitDB.Auras.PrivateAuras.FrameStrata) end
		return
	end
	if unit == "augmentation" then
		UUF:ForEachAugmentationRaidFrame(function(raidFrame, frameUnit)
			local augmentationDB = UUF:GetUnitDB(raidFrame, frameUnit)
			if raidFrame.BuffContainer then raidFrame.BuffContainer:SetFrameStrata(augmentationDB.Auras.FrameStrata) end
			if raidFrame.DebuffContainer then raidFrame.DebuffContainer:SetFrameStrata(augmentationDB.Auras.FrameStrata) end
			if raidFrame.CustomAuraContainer then raidFrame.CustomAuraContainer:SetFrameStrata(augmentationDB.Auras.FrameStrata) end
			if raidFrame.PrivateAuraContainer and augmentationDB.Auras.PrivateAuras then raidFrame.PrivateAuraContainer:SetFrameStrata(augmentationDB.Auras.PrivateAuras.FrameStrata) end
		end, false)
		return
	end
	if not unitFrame or not unitDB or not unitDB.Auras then return end
	if unitFrame.BuffContainer then unitFrame.BuffContainer:SetFrameStrata(unitDB.Auras.FrameStrata) end
	if unitFrame.DebuffContainer then unitFrame.DebuffContainer:SetFrameStrata(unitDB.Auras.FrameStrata) end
	if unitFrame.CustomAuraContainer then unitFrame.CustomAuraContainer:SetFrameStrata(unitDB.Auras.FrameStrata) end
	if unitFrame.PrivateAuraContainer and unitDB.Auras.PrivateAuras then unitFrame.PrivateAuraContainer:SetFrameStrata(unitDB.Auras.PrivateAuras.FrameStrata) end
end

local function StyleTestButton(button, AuraDB, unitFrame, unit, index, texture)
	local FontsDB = UUF.db.profile.General.Fonts
	button:SetSize(AuraDB.Size, AuraDB.Size)
	button.Icon:SetTexture(texture)
	button.Icon:SetTexCoord(0.07, 0.93, 0.07, 0.93)
	button.Count:ClearAllPoints()
	button.Count:SetPoint(AuraDB.Count.Layout[1], button, AuraDB.Count.Layout[2], AuraDB.Count.Layout[3], AuraDB.Count.Layout[4])
	button.Count:SetFont(UUF.Media.Font, AuraDB.Count.FontSize, FontsDB.FontFlag)
	button.Count:SetTextColor(unpack(AuraDB.Count.Colour))
	button.Count:SetText(index)
	button.Count:SetShown(not AuraDB.Count.HideStacks)
	button.Duration = button.Duration or button:CreateFontString(nil, "OVERLAY")
	UUF:ApplyCooldownText(button, button.Duration, unit, unitFrame)
	button.Duration:SetText("10m")
	button:Show()
end

local function UpdateAuraTestContainer(unitFrame, unit, realContainer, fieldName, AuraDB, texture)
	local testContainer = unitFrame[fieldName]
	if not testContainer then
		testContainer = CreateFrame("Frame", nil, unitFrame)
		unitFrame[fieldName] = testContainer
	end
	local anchorParent = AuraDB.AnchorParent == "Health" and unitFrame.Health or unitFrame
	local wrap = math.max(AuraDB.Wrap or 1, 1)
	local rows = math.ceil(AuraDB.Num / wrap)
	testContainer:ClearAllPoints()
	testContainer:SetPoint(AuraDB.Layout[1], anchorParent, AuraDB.Layout[2], AuraDB.Layout[3], AuraDB.Layout[4])
	testContainer:SetSize(math.max((AuraDB.Size + AuraDB.Layout[5]) * wrap - AuraDB.Layout[5], 1), math.max((AuraDB.Size + AuraDB.Layout[5]) * rows - AuraDB.Layout[5], 1))
	testContainer:SetFrameStrata(UUF:GetUnitDB(unitFrame, unit).Auras.FrameStrata)
	testContainer:SetShown(AuraDB.Enabled)
	if not AuraDB.Enabled then return end

	for index = 1, AuraDB.Num do
		local button = testContainer[index]
		if not button then
			button = CreateFrame("Button", nil, testContainer, "BackdropTemplate")
			button:SetBackdrop(UUF.BACKDROP)
			button:SetBackdropColor(0, 0, 0, 0)
			button:SetBackdropBorderColor(0, 0, 0, 1)
			button.Icon = button:CreateTexture(nil, "BORDER")
			button.Icon:SetPoint("TOPLEFT", 1, -1)
			button.Icon:SetPoint("BOTTOMRIGHT", -1, 1)
			button.Count = button:CreateFontString(nil, "OVERLAY")
			testContainer[index] = button
		end
		local row = math.floor((index - 1) / wrap)
		local column = (index - 1) % wrap
		local x = column * (AuraDB.Size + AuraDB.Layout[5]) * (AuraDB.GrowthDirection == "LEFT" and -1 or 1)
		local y = row * (AuraDB.Size + AuraDB.Layout[5]) * (AuraDB.WrapDirection == "DOWN" and -1 or 1)
		button:ClearAllPoints()
		button:SetPoint(AuraDB.Layout[1], testContainer, AuraDB.Layout[1], x, y)
		StyleTestButton(button, AuraDB, unitFrame, unit, index, texture)
	end
	for index = AuraDB.Num + 1, (testContainer.maxFake or AuraDB.Num) do
		if testContainer[index] then testContainer[index]:Hide() end
	end
	testContainer.maxFake = AuraDB.Num
	realContainer.maxFake = AuraDB.Num
	for index = 1, AuraDB.Num do realContainer["fake" .. index] = testContainer[index] end
end

local function UpdatePrivateAuraTestContainer(unitFrame, unit, AuraDB)
	local testContainer = unitFrame.PrivateAuraTestContainer
	if not testContainer then
		testContainer = CreateFrame("Frame", nil, unitFrame)
		unitFrame.PrivateAuraTestContainer = testContainer
	end
	local anchorParent = AuraDB.AnchorParent == "Health" and unitFrame.Health or unitFrame
	local width = AuraDB.Size * AuraDB.Num + AuraDB.Spacing * (AuraDB.Num - 1)
	testContainer:ClearAllPoints()
	testContainer:SetPoint(AuraDB.Layout[1], anchorParent, AuraDB.Layout[2], AuraDB.Layout[3], AuraDB.Layout[4])
	testContainer:SetSize(math.max(width, 1), AuraDB.Size)
	testContainer:SetFrameStrata(AuraDB.FrameStrata)
	testContainer:SetShown(AuraDB.Enabled)
	if not AuraDB.Enabled then return end
	for index = 1, AuraDB.Num do
		local button = testContainer[index]
		if not button then
			button = CreateFrame("Frame", nil, testContainer, "BackdropTemplate")
			button:SetBackdrop(UUF.BACKDROP)
			button:SetBackdropColor(0, 0, 0, 0)
			button:SetBackdropBorderColor(0, 0, 0, 1)
			button.Icon = button:CreateTexture(nil, "BORDER")
			button.Icon:SetPoint("TOPLEFT", 1, -1)
			button.Icon:SetPoint("BOTTOMRIGHT", -1, 1)
			button.Icon:SetTexture(135768)
			button.Cooldown = CreateFrame("Cooldown", nil, button, "CooldownFrameTemplate")
			button.Cooldown:SetAllPoints()
			button.Cooldown:SetCooldown(GetTime(), 600)
			testContainer[index] = button
		end
		local x = (index - 1) * (AuraDB.Size + AuraDB.Spacing) * (AuraDB.GrowthX == "LEFT" and -1 or 1)
		button:SetSize(AuraDB.Size, AuraDB.Size)
		button:ClearAllPoints()
		button:SetPoint(AuraDB.InitialAnchor, testContainer, AuraDB.InitialAnchor, x, 0)
		button.Cooldown:SetDrawSwipe(not AuraDB.DisableCooldown)
		button.Cooldown:SetHideCountdownNumbers(AuraDB.DisableCooldownText)
		button:Show()
	end
end

function UUF:CreateTestAuras(unitFrame, unit)
	if not unit or not unitFrame then return end
	local AurasDB = UUF:GetUnitDB(unitFrame, unit).Auras
	if not AurasDB then return end

	if UUF.AURA_TEST_MODE then
		unitFrame.BuffContainer:SetEnabled(false)
		unitFrame.DebuffContainer:SetEnabled(false)
		unitFrame.BuffContainer:Hide()
		unitFrame.DebuffContainer:Hide()
		UpdateAuraTestContainer(unitFrame, unit, unitFrame.BuffContainer, "BuffAuraTestContainer", AurasDB.Buffs, 135769)
		UpdateAuraTestContainer(unitFrame, unit, unitFrame.DebuffContainer, "DebuffAuraTestContainer", AurasDB.Debuffs, 135768)
		if unitFrame.CustomAuraContainer and AurasDB.Custom then
			unitFrame.CustomAuraContainer:SetEnabled(false)
			unitFrame.CustomAuraContainer:Hide()
			UpdateAuraTestContainer(unitFrame, unit, unitFrame.CustomAuraContainer, "CustomAuraTestContainer", AurasDB.Custom, AurasDB.Custom.Type == "Debuffs" and 135768 or 135769)
		end
		if unitFrame.PrivateAuraContainer and AurasDB.PrivateAuras then
			if unitFrame:IsElementEnabled("PrivateAuras") then unitFrame:DisableElement("PrivateAuras") end
			unitFrame.PrivateAuraContainer:Hide()
			UpdatePrivateAuraTestContainer(unitFrame, unit, AurasDB.PrivateAuras)
		end
	else
		for _, fieldName in ipairs({"BuffAuraTestContainer", "DebuffAuraTestContainer", "CustomAuraTestContainer", "PrivateAuraTestContainer"}) do
			if unitFrame[fieldName] then unitFrame[fieldName]:Hide() end
		end
		UUF:UpdateUnitAuras(unitFrame, unit)
	end
end
