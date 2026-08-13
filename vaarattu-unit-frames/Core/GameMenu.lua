local _, UUF = ...

local function PositionGameMenuButton()
	if not GameMenuFrame or not GameMenuFrame.UUF then return end
	local height = GameMenuFrame:GetHeight()
	if GameMenuFrame.UUFAdjustedHeight == height then height = height - (GameMenuFrame.UUFAddedHeight or 0) end

	local anchorButton
	for button in GameMenuFrame.buttonPool:EnumerateActive() do
		local text = button:GetText()
		local point, relativeTo, relativePoint, offsetX, offsetY = button:GetPoint()
		if text and (text == LOGOUT or text == LOG_OUT or text == EXIT_GAME or text == RETURN_TO_GAME) then
			if point then
				button:ClearAllPoints()
				button:SetPoint(point, relativeTo, relativePoint, offsetX, (offsetY or 0) - 25)
			end
		else
			if text == MACROS then anchorButton = button end
			if point then
				button:ClearAllPoints()
				button:SetPoint(point, relativeTo, relativePoint, offsetX, (offsetY or 0) + 10)
			end
		end
	end
	if anchorButton then
		GameMenuFrame.UUF:ClearAllPoints()
		GameMenuFrame.UUF:SetPoint("TOPLEFT", anchorButton, "BOTTOMLEFT", 0, 0)
		GameMenuFrame.UUF:SetText(UUF.ADDON_NAME)
		GameMenuFrame.UUF:Show()
		GameMenuFrame.UUFAddedHeight = GameMenuFrame.UUF:GetHeight() + 10
		GameMenuFrame.UUFAdjustedHeight = height + GameMenuFrame.UUFAddedHeight
		GameMenuFrame:SetHeight(GameMenuFrame.UUFAdjustedHeight)
	else
		GameMenuFrame.UUFAddedHeight = 0
		GameMenuFrame.UUFAdjustedHeight = nil
		GameMenuFrame.UUF:Hide()
	end
end

local function OpenUUFConfig()
	PlaySound(SOUNDKIT.IG_MAINMENU_OPTION)
	if not InCombatLockdown() then HideUIPanel(GameMenuFrame) end
	UUF:CreateGUI()
end

local function SetupGameMenu()
	if not GameMenuFrame or GameMenuFrame.UUF then return end
	local button = CreateFrame("Button", "UUF_GameMenuButton", GameMenuFrame, "MainMenuFrameButtonTemplate")
	button:SetSize(200, 35)
	button:SetScript("OnClick", OpenUUFConfig)
	GameMenuFrame.UUF = button
	hooksecurefunc(GameMenuFrame, "Layout", PositionGameMenuButton)
end

SetupGameMenu()

if not GameMenuFrame or not GameMenuFrame.UUF then
	local eventFrame = CreateFrame("Frame")
	eventFrame:RegisterEvent("ADDON_LOADED")
	eventFrame:SetScript("OnEvent", function(self, _, addonName)
		if addonName ~= "Blizzard_GameMenu" then return end
		SetupGameMenu()
		if GameMenuFrame and GameMenuFrame.UUF then self:UnregisterAllEvents() end
	end)
end
