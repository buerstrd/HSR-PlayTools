-- Runs only through the game's own Lua VM after a successful main-thread call.
-- Uses the game UI/input APIs; gameplay values and account data are unchanged.
-- Unity/CS bindings are populated after startup; resolve them dynamically.
getfenv(0)
local okCS, UE = pcall(function() return CS.UnityEngine end)
if not okCS or not UE then return nil end
-- The first successful game Lua call can precede the Unity binding bootstrap.
local bindingsReady = pcall(function()
    assert(UE.PlayerPrefs and UE.PlayerPrefs.GetFloat and UE.PlayerPrefs.GetInt)
    assert(UE.Screen and UE.GameObject and typeof)
    local current = UE.EventSystems.EventSystem.current
    assert(current and not current:Equals(nil) and current.currentInputModule)
    assert(CS.RPG.Client.GlobalVars.s_UIManager)
    assert(CS.RPG.Client.MouseInputController.Instance)
end)
if not bindingsReady then return nil end
local desiredScale = 0.8
-- Reviewed exploration controllers using maze HUD components.
local explorationPages = {
    TownMainPage = true,
    MazeMainPage = true,
    ChallengeMainPage = true,
    RaidMainPage = true,
    RaidSpecialMainPage = true,
    ChallengeActivityMainPage = true,
    ChallengeTierceMazeMainPage = true,
    RoleTrialMainPage = true,
    FarmRelicMainPage = true,
    AetherDivideMazeMainPage = true,
    ChessRogueMazeMainPage = true,
    RogueArcadeMazeMainPage = true,
    RogueMagicMazeMainPage = true,
    RogueTournMazeMainPage = true,
    RogueTournRelicMazeMainPage = true,
    TrainMainPage = true,
}

-- ActivityPage hosts many separate requests. Only the selected Currency Wars
-- background is known. Keep the page controller weakly while it is open.
local activityView = setmetatable({}, {__mode = "v"})

local function observeActivityPage()
    local pageClass = require("Ui.Activity.ActivityPage")
    local onLoad = pageClass._on_load
    if type(onLoad) ~= "function" then return end
    pageClass._on_load = function(self, ...)
        activityView.controller = self
        return onLoad(self, ...)
    end
end

local function gyroRequestSource(page)
    if page ~= "ActivityPage" then return page, false end

    local controller = activityView.controller
    if controller then
        local ok, tab = pcall(controller._get_cur_activity_tab_item, controller)
        if ok and type(tab) == "table" then
            if tab.__name then return tostring(tab.__name), tab.__name == "GridFightActivityPanel" end
            local hasID, panelID = pcall(function()
                local data = tab._activity_panel_data or tab._activity_data
                return data and data.PanelID
            end)
            return hasID and panelID and tostring(panelID) or page, false
        end
    end

    -- Handles a page already open before the observer was installed.
    local panel = UE.GameObject.Find("QuestGridFightPanel(Clone)")
    return page, panel and not panel:Equals(nil)
end

-- In the PC layout, light-cone previews can be visible without a gyro request.
local lightConePreviewPages = {
    AvatarMainPage = true,
    LightConeDetailPage = true,
    LightConeReplacePage = true,
    LightConeArchiveDetailPage = true,
    LightConeZoomInPage = true,
    GachaLightConeDetailPage = true,
    NewLightConeDropDialog = true,
}
local lightConePanels = setmetatable({}, {__mode = "k"})
local gyroLightConePanel

local function observeLightConePreviews()
    local panelClass = require("Ui.UI3DSystem.UI3DLightConePanel")
    local setup = panelClass.setup_lightcone
    local swipe = panelClass.swipe_lightcone
    if type(setup) ~= "function" then return end
    panelClass.setup_lightcone = function(panel, ...)
        local results = table.pack(setup(panel, ...))
        lightConePanels[panel] = true
        return table.unpack(results, 1, results.n)
    end
    if type(swipe) == "function" then
        -- Both pointer drag paths and the controller stick dispatch here.
        panelClass.swipe_lightcone = function(panel, ...)
            if panel == gyroLightConePanel then
                local utils = G and G.Utils
                if not (utils and utils.is_gamepad_input and utils.is_gamepad_input()) then return end
            end
            return swipe(panel, ...)
        end
    end
    -- Model collider clicks and page-level taps can both trigger the preview.
    for _, name in ipairs({"_on_click_light_cone", "simple_tap_lightcone"}) do
        local click = panelClass[name]
        if type(click) == "function" then
            panelClass[name] = function(panel, ...)
                if panel == gyroLightConePanel then return end
                return click(panel, ...)
            end
        end
    end
end

local function visibleLightConePreview(page)
    if not page or not lightConePreviewPages[page] then return nil end
    for panel in pairs(lightConePanels) do
        local model = panel._lightcone_material_cmpt
        if model and not model:Equals(nil) and model.isActiveAndEnabled
            and not panel.is_force_hide and not panel._lightcone_need_to_hide then
            return panel
        end
    end
end

local gyroRequestField
local function hasGyroRequest()
    if gyroRequestField == nil then
        local ok, field = pcall(function()
            local flags = CS.System.Enum.Parse(typeof(CS.System.Reflection.BindingFlags), "Instance, NonPublic")
            return typeof(CS.RPG.Client.GyroManager):GetField("_RefCount", flags)
        end)
        gyroRequestField = ok and field or false
    end
    if not gyroRequestField then return false end
    local ok, count = pcall(function()
        local value = gyroRequestField:GetValue(CS.RPG.Client.GyroManager.Instance)
        if type(value) == "number" then return value end
        return value and tonumber(value:ToString())
    end)
    return ok and count ~= nil and count > 0
end

local state = rawget(_G, "__HSR_UI_PLAYTOOLS_V1")
if not state then
    state = {}
    rawset(_G, "__HSR_UI_PLAYTOOLS_V1", state)
end
if state.target == nil then
    state.target = math.max(0.5, math.min(1.5, UE.PlayerPrefs.GetFloat("HSRPlayTools.UIScale", desiredScale)))
end
if state.altToggleMode == nil then
    state.altToggleMode=UE.PlayerPrefs.GetInt("HSRPlayTools.AltToggle",1)==1
end
local gyroPreference = "HSRPlayTools.GyroSimulation"
if state.gyroSimulation == nil then
    state.gyroSimulation = UE.PlayerPrefs.GetInt(gyroPreference, 1) == 1
end
local permissionPreference = "HSRPlayTools.PermissionManagement"
if state.permissionManagement == nil then
    state.permissionManagement = UE.PlayerPrefs.GetInt(permissionPreference, 1) == 1
end
if __HSRMouseCapture then __HSRMouseCapture(state.altToggleMode and -2 or -3) end
if not state.sensitivity then
    state.sensitivity = math.max(0.25, math.min(5, UE.PlayerPrefs.GetFloat("HSRPlayTools.Sensitivity", 3)))
end
if not state.wheelSensitivity then
    state.wheelSensitivity = math.max(0.5, math.min(10, UE.PlayerPrefs.GetFloat("HSRPlayTools.WheelSensitivity", 3)))
end
if __HSRSensitivity then __HSRSensitivity(state.sensitivity, state.wheelSensitivity) end
if __HSRMouseDimensions then __HSRMouseDimensions(UE.Screen.width, UE.Screen.height) end
local function playUISound(buttonType)
    pcall(function()
        local audio = CS.RPG.Client.GlobalVars.s_AudioManager
        local kind = CS.RPG.Client.UIButtonSoundType[buttonType or "CommonClick"]
        local event = audio:GetUIButtonSoundEventByType(kind)
        if event and event ~= "" then audio:PostEvent(event) end
    end)
end

local function syncWindowFocus()
    local application = CS.RPG.Client.RPGApplication.Instance
    if not application then return end

    -- Under PlayCover, Unity can report focus while the macOS window is inactive.
    local focused = __HSRWindowFocused() == 1
    if application.IsFocus ~= focused then application:OnApplicationFocus(focused) end
end

-- Observe Unity's existing output without changing its logger or filter.
state.consoleLines = state.consoleLines or {}
if not state.consoleCallback then
    local callback = function(message)
        table.insert(state.consoleLines, message or "")
        while #state.consoleLines > 40 do table.remove(state.consoleLines, 1) end
        state.consoleDirty = true
    end
    local subscribed = pcall(function() UE.Application.logMessageReceived("+", callback) end)
    if subscribed then state.consoleCallback = callback end
end

local function updateAvatarScrolls(page)
    state.avatarScrollRects=nil
    if page=="AvatarMainPage" then
        local go=UE.GameObject.Find("AvatarMainPage(Clone)")
        if go then state.avatarScrollRects=go:GetComponentsInChildren(typeof(UE.UI.ScrollRect),false) end
    end
end
local function transition(object,visible,finished,fadeOut)
    if not object or object:Equals(nil) then return end
    local group=object:GetComponent(typeof(UE.CanvasGroup))
    if not group then
        group=object:AddComponent(typeof(UE.CanvasGroup))
        group.alpha=object.activeSelf and 1 or 0
    end
    group.interactable=visible
    group.blocksRaycasts=visible
    local wasActive=object.activeSelf
    local transform=object.transform
    local collapsedScale=fadeOut and 0.94 or 0.97
    local scale=wasActive and transform.localScale.x or collapsedScale
    if visible then
        transform.localScale=UE.Vector3(scale,scale,1)
        object:SetActive(true)
    elseif wasActive and not fadeOut then
        group.alpha=1
    end
    state.uiTransitions=state.uiTransitions or {}
    state.uiTransitions[object]={group=group,transform=transform,from=group.alpha,to=visible and 1 or 0,
        scale=scale,collapsedScale=collapsedScale,fadeOut=fadeOut,duration=fadeOut and 0.16 or 0.1,
        started=UE.Time.unscaledTime,finished=finished}
end
local function canvasCamera(object)
    local canvas=object:GetComponentInParent(typeof(UE.Canvas))
    if canvas and canvas.renderMode~=UE.RenderMode.ScreenSpaceOverlay then return canvas.worldCamera end
end
local function updateEntryHover(page,module)
    local image=state.entryHoverImage
    local entry=state.settingsTab
    if not image or image:Equals(nil) or not entry or entry:Equals(nil) then return end
    local hovered=false
    if page=="MobilePhonePage" and UE.Application.isFocused and not state.playtoolsPageOpen and not module.IsShowSDKUI then
        local camera=canvasCamera(entry)
        local pos=UE.Input.mousePosition
        local point=UE.Vector2(pos.x,pos.y)
        local entryRect=entry:GetComponent(typeof(UE.RectTransform))
        hovered=UE.RectTransformUtility.RectangleContainsScreenPoint(entryRect,point,camera)
            and (not state.menuViewport or UE.RectTransformUtility.RectangleContainsScreenPoint(state.menuViewport,point,camera))
    end
    local opacity=hovered and 0.08 or 0
    state.entryHoverAlpha=UE.Mathf.MoveTowards(state.entryHoverAlpha or 0,opacity,
        UE.Time.unscaledDeltaTime*0.08/state.entryHoverDuration)
    image.gameObject:SetActive(true)
    image.color=UE.Color(1,1,1,state.entryHoverAlpha)
end
local function updateTransitions()
    if not state.uiTransitions then return end
    local now=UE.Time.unscaledTime
    local completed
    for object,animation in pairs(state.uiTransitions) do
        if object:Equals(nil) or animation.group:Equals(nil) then
            state.uiTransitions[object]=nil
        else
            local t=math.max(0,math.min(1,(now-animation.started)/animation.duration))
            local eased=t*t*(3-2*t)
            local targetScale=animation.to==1 and 1 or animation.collapsedScale
            local scale=animation.scale+(targetScale-animation.scale)*eased
            animation.transform.localScale=UE.Vector3(scale,scale,1)
            -- Keep the closing surface opaque so overlapping slider graphics
            -- cannot linger through independently blended transparent layers.
            if animation.to==1 or animation.fadeOut then
                animation.group.alpha=animation.from+(animation.to-animation.from)*eased
            end
            if t>=1 then
                if animation.to==0 then
                    object:SetActive(false)
                    animation.group.alpha=0
                    animation.transform.localScale=UE.Vector3(1,1,1)
                end
                state.uiTransitions[object]=nil
                if animation.finished then
                    completed=completed or {}
                    table.insert(completed,animation.finished)
                end
            end
        end
    end
    if not next(state.uiTransitions) then state.uiTransitions=nil end
    if completed then for _,finished in ipairs(completed) do finished() end end
end
local function rect(name, owner, x, y, w, h)
    local go = UE.GameObject(name, typeof(UE.RectTransform))
    go.transform:SetParent(owner, false)
    local r = go:GetComponent(typeof(UE.RectTransform))
    r.anchorMin = UE.Vector2(0.5, 0.5)
    r.anchorMax = UE.Vector2(0.5, 0.5)
    r.sizeDelta = UE.Vector2(w, h)
    r.anchoredPosition = UE.Vector2(x, y)
    return go
end

local function createOverlay(name, sortingOrder)
    local root = UE.GameObject(name, typeof(UE.RectTransform))
    local canvas = root:AddComponent(typeof(UE.Canvas))
    canvas.renderMode = UE.RenderMode.ScreenSpaceOverlay
    canvas.sortingOrder = sortingOrder
    local scaler = root:AddComponent(typeof(UE.UI.CanvasScaler))
    scaler.uiScaleMode = UE.UI.CanvasScaler.ScaleMode.ScaleWithScreenSize
    scaler.referenceResolution = UE.Vector2(1920, 1080)
    root:AddComponent(typeof(UE.UI.GraphicRaycaster))
    return root
end

local function panelFont()
    local font = state.panelFont
    if font and not font:Equals(nil) then return font end
    font = nil
    local texts = UE.Resources.FindObjectsOfTypeAll(typeof(UE.UI.Text))
    for i = 0, texts.Length - 1 do
        if texts[i].font then
            font = font or texts[i].font
            if string.find(texts[i].text or "", "[\228-\233]") then
                font = texts[i].font
                break
            end
        end
    end
    state.panelFont = font or UE.Resources.GetBuiltinResource(typeof(UE.Font), "Arial.ttf")
    return state.panelFont
end

local gyroPromptName = "HSRPlayToolsGyroPrompt"
local gyroPromptSeconds = 5

local function destroyGyroPrompt(prompt)
    if not prompt then return end
    if state.uiTransitions then state.uiTransitions[prompt.card] = nil end
    if not prompt.root:Equals(nil) then
        prompt.root:SetActive(false)
        UE.Object.Destroy(prompt.root)
    end
end

local function hideGyroPrompt(immediate)
    local prompt = state.gyroPrompt
    if not prompt and not immediate then return end
    state.gyroPrompt = nil
    destroyGyroPrompt(state.closingGyroPrompt)
    state.closingGyroPrompt = nil
    if not prompt then return end
    if immediate or prompt.card:Equals(nil) then
        destroyGyroPrompt(prompt)
        return
    end
    state.closingGyroPrompt = prompt
    transition(prompt.card, false, function()
        destroyGyroPrompt(prompt)
        state.closingGyroPrompt = nil
    end, true)
end

local function updateGyroPrompt(source, decision)
    local prompt = state.gyroPrompt
    if source and prompt and source == prompt.source and not prompt.root:Equals(nil) then
        local remaining = math.ceil(prompt.deadline - UE.Time.unscaledTime)
        if remaining <= 0 then
            hideGyroPrompt()
        elseif remaining ~= prompt.remaining then
            prompt.remaining = remaining
            prompt.allowLabel.text = "允许（" .. remaining .. "）"
        end
        return
    end
    hideGyroPrompt()
    if not source or decision ~= 0 then return end

    local root = createOverlay(gyroPromptName, 32690)
    local card = rect("GyroPermission", root.transform, -24, 24, 376, 168)
    prompt = {root = root, card = card, source = source,
        deadline = UE.Time.unscaledTime + gyroPromptSeconds, remaining = gyroPromptSeconds}
    state.gyroPrompt = prompt
    card:SetActive(false)
    card.transform.anchorMin = UE.Vector2(1, 0)
    card.transform.anchorMax = UE.Vector2(1, 0)
    card.transform.pivot = UE.Vector2(1, 0)
    card.transform.anchoredPosition = UE.Vector2(-24, 24)
    card:AddComponent(typeof(UE.UI.Image)).color = UE.Color(0.9, 0.9, 0.9, 1)
    local shadow = card:AddComponent(typeof(UE.UI.Shadow))
    shadow.effectColor = UE.Color(0, 0, 0, 0.3)
    shadow.effectDistance = UE.Vector2(4, -4)

    local font = panelFont()
    local function text(owner, name, value, x, y, width, height, size, alignment)
        local label = rect(name, owner, x, y, width, height):AddComponent(typeof(UE.UI.Text))
        label.font, label.fontSize, label.text = font, size, value
        label.alignment = alignment
        label.color = UE.Color(0.19, 0.19, 0.19, 1)
        label.raycastTarget = false
        return label
    end
    text(card.transform, "Title", "权限申请", 0, 54, 336, 28, 22, UE.TextAnchor.MiddleLeft)
    local message = text(card.transform, "Message", source .. " 想要使用陀螺仪，是否允许？",
        0, 7, 336, 60, 17, UE.TextAnchor.MiddleLeft)
    message.resizeTextForBestFit = true
    message.resizeTextMinSize, message.resizeTextMaxSize = 12, 17

    local function choice(name, x, allow)
        local item = rect(name, card.transform, x, -47, 104, 36)
        local image = item:AddComponent(typeof(UE.UI.Image))
        image.color = UE.Color(1, 1, 1, 1)
        local button = item:AddComponent(typeof(UE.UI.Button))
        button.targetGraphic = image
        local label = text(item.transform, "Label", name, 0, 0, 104, 36, 17, UE.TextAnchor.MiddleCenter)
        button.onClick:AddListener(function()
            if state.gyroPrompt ~= prompt then return end
            if allow then playUISound() else playUISound("CommonCancel") end
            if not allow then __HSRGyroDecision(source, -1) end
            hideGyroPrompt()
        end)
        return label
    end
    choice("禁止", 0, false)
    prompt.allowLabel = choice("允许（" .. prompt.remaining .. "）", 116, true)
    transition(card, true, nil, true)
    __HSRGyroDecision(source, 1)
end

local function updateGyroEffect(page, lightCone)
    local source, known = gyroRequestSource(page)
    local enabled = known == true
    local promptSource, decision
    if source and not enabled and (lightCone or hasGyroRequest()) then
        if state.permissionManagement then
            decision = __HSRGyroDecision(source)
            enabled = decision ~= -1
            if enabled then promptSource = source end
        else
            enabled = true
        end
    end
    __HSRGyroPointer(enabled and 1 or 0)
    updateGyroPrompt(promptSource, decision)
    return enabled
end

-- One owner and one cleanup path for the menu entry and independent overlay.
local function disposeSettings()
    if state.settingsLeave then pcall(state.settingsLeave) end
    if __HSRMouseCapture then __HSRMouseCapture(-15) end
    if state.uiTransitions and state.settingsPanels then
        for _,object in ipairs(state.settingsPanels) do state.uiTransitions[object]=nil end
    end
    state.settingsPanels=nil
    state.consoleRefresh=nil
    state.altModeTap=nil
    state.altModeTapTarget=nil
    state.altModeTapAction=nil
    state.entryHoverImage=nil
    state.entryHoverAlpha=nil
    state.entryHoverDuration=nil
    state.menuViewport=nil
    state.settingsMenu=nil
    for _,key in ipairs({"settingsRoot","settingsTab"}) do
        local object=state[key]
        if object then pcall(function()
            if not object:Equals(nil) then
                object:SetActive(false)
                UE.Object.Destroy(object)
            end
        end) end
        state[key]=nil
    end
    state.settingsLeave,state.settingsOpen=nil,nil
    state.playtoolsPageOpen=false
    state.menuTap=nil
end
if not state.settingsUIInitialized then
    disposeSettings()
    -- Recover UI objects left behind when the Lua environment was recreated.
    local objects=UE.Resources.FindObjectsOfTypeAll(typeof(UE.GameObject))
    for i=0,objects.Length-1 do
        local object=objects[i]
        if (object.name=="HSRPlayToolsSettings" or object.name=="HSRPlayToolsMenuEntry"
            or object.name==gyroPromptName)
            and object.scene:IsValid() and object.scene.isLoaded then
            object:SetActive(false)
            UE.Object.Destroy(object)
        end
    end
    state.settingsFramePage=nil
    state.settingsUIInitialized=true
end
local function updateSettings()
    local manager=CS.RPG.Client.GlobalVars.s_UIManager
    local page=manager and tostring(manager:TopPageDialogName()) or ""
    local menu=UE.GameObject.Find("MobilePhoneMainPage(Clone)")
    local inSettings=page=="MobilePhonePage" and menu and menu.activeInHierarchy
    local rootAlive=state.settingsRoot and not state.settingsRoot:Equals(nil)
    local entryAlive=state.settingsTab and not state.settingsTab:Equals(nil)
    if not inSettings then
        if state.settingsRoot or state.settingsTab then disposeSettings() end
        return
    end
    if rootAlive and entryAlive then return end
    if state.settingsRoot or state.settingsTab then disposeSettings() end
    if UE.GameObject.Find("HSRPlayToolsSettings") then return end
    -- Independent overlay does not require a game-owned canvas.
    local created
    local success, failure = pcall(function()
        created = createOverlay("HSRPlayToolsSettings", 32700)
        local font = panelFont()
        local function label(go, text)
            local child = rect("Label", go.transform, 0, 0, 420, 44)
            local t = child:AddComponent(typeof(UE.UI.Text))
            t.font, t.fontSize, t.text = font, 22, text
            t.alignment = UE.TextAnchor.MiddleCenter
            t.color = UE.Color(0.196, 0.196, 0.196, 1)
            t.raycastTarget = false
            return t
        end
        local function button(owner, name, x, y, action, sound)
            local go = rect(name, owner, x, y, 440, 50)
            local image = go:AddComponent(typeof(UE.UI.Image))
            image.color = UE.Color(1, 1, 1, 1)
            -- Unity uGUI default Selectable palette.
            local b = go:AddComponent(typeof(UE.UI.Button))
            b.targetGraphic = image
            b.transition = UE.UI.Selectable.Transition.ColorTint
            local colors = b.colors
            colors.normalColor = UE.Color(1, 1, 1, 1)
            colors.highlightedColor = UE.Color(0.96, 0.96, 0.96, 1)
            colors.pressedColor = UE.Color(0.78, 0.78, 0.78, 1)
            colors.selectedColor = UE.Color(0.96, 0.96, 0.96, 1)
            colors.disabledColor = UE.Color(0.78, 0.78, 0.78, 0.5)
            colors.colorMultiplier, colors.fadeDuration = 1, 0.1
            b.colors = colors
            local t = label(go, name)
            b.onClick:AddListener(function()
                if sound ~= false then playUISound(sound) end
                action()
            end)
            return t
        end
        local function closeButton(owner,x,y,action)
            local text=button(owner,"×",x,y,action,"CommonCancel")
            text.transform.parent:GetComponent(typeof(UE.RectTransform)).sizeDelta=UE.Vector2(44,44)
            text.rectTransform.sizeDelta=UE.Vector2(44,44)
            text.fontSize=30
            return text
        end
        local function slider(owner, name, y, minimum, maximum, step, value, changed)
            local row = rect(name, owner, 0, y, 440, 104)
            local text = label(rect("Caption", row.transform, 0, 30, 440, 44), "")
            local track = rect("Slider", row.transform, 0, -22, 420, 26)
            local background = track:AddComponent(typeof(UE.UI.Image))
            background.color = UE.Color(0.65, 0.65, 0.65, 1)
            local fillArea = rect("FillArea", track.transform, 0, 0, 400, 8)
            local fill = rect("Fill", fillArea.transform, 0, 0, 0, 0)
            fill.transform.anchorMin = UE.Vector2(0, 0)
            fill.transform.anchorMax = UE.Vector2(1, 1)
            fill:AddComponent(typeof(UE.UI.Image)).color = UE.Color(0.35, 0.35, 0.35, 1)
            local handleArea = rect("HandleArea", track.transform, 0, 0, 400, 26)
            local handle = rect("Handle", handleArea.transform, 0, 0, 20, 30)
            local handleImage = handle:AddComponent(typeof(UE.UI.Image))
            handleImage.color = UE.Color(1, 1, 1, 1)
            local control = track:AddComponent(typeof(UE.UI.Slider))
            control.fillRect = fill.transform
            control.handleRect = handle.transform
            control.targetGraphic = handleImage
            -- Only the panel controls fading; slider state changes are immediate.
            control.transition = UE.UI.Selectable.Transition.None
            control.direction = UE.UI.Slider.Direction.LeftToRight
            control.minValue = 0
            control.maxValue = math.floor((maximum-minimum)/step+0.5)
            control.wholeNumbers = true
            control.value = math.floor((value-minimum)/step+0.5)
            local lastSound = -math.huge
            control.onValueChanged:AddListener(function(v)
                local now = UE.Time.unscaledTime
                if now - lastSound >= 0.08 then
                    playUISound("SlideClick")
                    lastSound = now
                end
                changed(minimum+v*step)
            end)
            return text
        end
        local function panelShadow(object)
            local shadow=object:AddComponent(typeof(UE.UI.Shadow))
            shadow.effectColor=UE.Color(0,0,0,0.3)
            shadow.effectDistance=UE.Vector2(8,-10)
            shadow.useGraphicAlpha=true
        end
        local function switchPanel(previous,nextPanel)
            nextPanel:SetActive(false)
            transition(previous,false,function() transition(nextPanel,true) end)
        end
        local panel = rect("Page", created.transform, 0, 0, 660, 780)
        panel:AddComponent(typeof(UE.UI.Image)).color = UE.Color(0.82, 0.82, 0.82, 1)
        panelShadow(panel)
        label(rect("Title", panel.transform, 0, 350, 440, 50), "HSR PlayTools 设置")
        local scale, sensitivity, wheelSensitivity, altMode, gyroMode, permissionMode
        local function refresh()
            wheelSensitivity.text = "滚轮灵敏度：" .. string.format("%.1f×", state.wheelSensitivity)
            sensitivity.text = "鼠标灵敏度：" .. string.format("%.2f×", state.sensitivity)
            scale.text = "界面缩放：" .. tostring(math.floor(state.target * 100 + 0.5)) .. "%"
            state.altToggleMode=__HSRMouseCapture(-12)==1
            altMode.text = "Alt 释放模式：" .. (state.altToggleMode and "按下切换" or "按住释放")
            gyroMode.text = "陀螺仪模拟：" .. (state.gyroSimulation and "开启" or "关闭")
            permissionMode.text = "权限管理：" .. (state.permissionManagement and "开启" or "关闭")
        end
        wheelSensitivity = slider(panel.transform, "WheelSensitivity", 230, 0.5, 10, 0.5, state.wheelSensitivity, function(value)
            state.wheelSensitivity = value
            if __HSRSensitivity then __HSRSensitivity(state.sensitivity, state.wheelSensitivity) end
            UE.PlayerPrefs.SetFloat("HSRPlayTools.WheelSensitivity", value)
            UE.PlayerPrefs.Save(); refresh()
        end)
        sensitivity = slider(panel.transform, "Sensitivity", 120, 0.25, 5, 0.25, state.sensitivity, function(value)
            state.sensitivity = value
            if __HSRSensitivity then __HSRSensitivity(state.sensitivity, state.wheelSensitivity) end
            UE.PlayerPrefs.SetFloat("HSRPlayTools.Sensitivity", value)
            UE.PlayerPrefs.Save(); refresh()
        end)
        scale = slider(panel.transform, "Scale", 10, 0.5, 1.5, 0.1, state.target, function(value)
            state.target = value
            if state.applyUIScale then state.applyUIScale() end
            UE.PlayerPrefs.SetFloat("HSRPlayTools.UIScale", state.target)
            UE.PlayerPrefs.Save(); refresh()
        end)
        local lastAltRelease,lastAltTime=-1,-1
        local function toggleAltMode()
            local _,release=__HSRMouseCapture(-13)
            local now=UE.Time.unscaledTime
            if release==lastAltRelease and now-lastAltTime<0.15 then return end
            lastAltRelease,lastAltTime=release,now
            playUISound()
            local toggle=__HSRMouseCapture(-12)~=1
            __HSRMouseCapture(toggle and -2 or -3)
            refresh()
            UE.PlayerPrefs.SetInt("HSRPlayTools.AltToggle",state.altToggleMode and 1 or 0)
            UE.PlayerPrefs.Save()
        end
        local firstOptionY, optionSpacing = -100, 70
        altMode = button(panel.transform,"AltReleaseMode",0,firstOptionY,toggleAltMode,false)
        state.altModeTapTarget=altMode.transform.parent:GetComponent(typeof(UE.RectTransform))
        state.altModeTapAction=toggleAltMode
        state.altPressSeen,state.altReleaseSeen=__HSRMouseCapture(-13)
        gyroMode = button(panel.transform, "GyroSimulation", 0, firstOptionY - optionSpacing, function()
            state.gyroSimulation = not state.gyroSimulation
            if not state.gyroSimulation then
                __HSRGyroPointer(0)
                hideGyroPrompt()
            end
            UE.PlayerPrefs.SetInt(gyroPreference, state.gyroSimulation and 1 or 0)
            UE.PlayerPrefs.Save()
            refresh()
        end)
        permissionMode = button(panel.transform, "PermissionManagement", 0, firstOptionY - 2 * optionSpacing, function()
            state.permissionManagement = not state.permissionManagement
            if not state.permissionManagement then hideGyroPrompt(true) end
            UE.PlayerPrefs.SetInt(permissionPreference, state.permissionManagement and 1 or 0)
            UE.PlayerPrefs.Save()
            refresh()
        end)
        local console = rect("UnityConsole", created.transform, 0, 0, 1500, 850)
        console:AddComponent(typeof(UE.UI.Image)).color = UE.Color(0.9, 0.9, 0.9, 1)
        panelShadow(console)
        local consoleTitle=label(rect("Title",console.transform,-490,380,420,44),"Unity控制台")
        consoleTitle.alignment=UE.TextAnchor.MiddleLeft
        local outputArea = rect("Output", console.transform, 0, 10, 1400, 640)
        outputArea:AddComponent(typeof(UE.UI.Image)).color = UE.Color(0.98, 0.98, 0.98, 1)
        outputArea:AddComponent(typeof(UE.UI.RectMask2D))
        local content=rect("Content",outputArea.transform,0,0,1400,640).transform
        content.anchorMin=UE.Vector2(0,1)
        content.anchorMax=UE.Vector2(1,1)
        content.pivot=UE.Vector2(0.5,1)
        content.anchoredPosition=UE.Vector2(0,0)
        content.sizeDelta=UE.Vector2(0,640)
        local output = label(content.gameObject, "")
        output.rectTransform.anchorMin=UE.Vector2(0,1)
        output.rectTransform.anchorMax=UE.Vector2(1,1)
        output.rectTransform.pivot=UE.Vector2(0.5,1)
        output.rectTransform.anchoredPosition=UE.Vector2(0,-12)
        output.rectTransform.sizeDelta=UE.Vector2(-24,616)
        output.alignment = UE.TextAnchor.UpperLeft
        output.fontSize = 17
        output.supportRichText=false
        output.horizontalOverflow = UE.HorizontalWrapMode.Wrap
        output.verticalOverflow = UE.VerticalWrapMode.Overflow
        local scroll=outputArea:AddComponent(typeof(UE.UI.ScrollRect))
        scroll.viewport=outputArea.transform
        scroll.content=content
        scroll.horizontal=false
        scroll.vertical=true
        scroll.movementType=UE.UI.ScrollRect.MovementType.Clamped
        scroll.scrollSensitivity=32
        local function refreshConsole(forceBottom)
            if not console.activeSelf then return end
            local follow=forceBottom or scroll.verticalNormalizedPosition<=0.02
                or content.rect.height<=outputArea.transform.rect.height
            local offset=content.anchoredPosition.y
            output.text = table.concat(state.consoleLines, "\n")
            local height=math.max(outputArea.transform.rect.height,output.preferredHeight+24)
            output.rectTransform.sizeDelta=UE.Vector2(-24,height-24)
            content.sizeDelta=UE.Vector2(0,height)
            if follow then scroll.verticalNormalizedPosition=0
            else content.anchoredPosition=UE.Vector2(0,math.max(0,math.min(offset,height-outputArea.transform.rect.height))) end
            state.consoleDirty=false
        end
        state.consoleRefresh=refreshConsole
        local consoleOpened=false
        local function showConsole()
            local firstOpen=not consoleOpened
            consoleOpened=true
            console:SetActive(true)
            refreshConsole(firstOpen)
            console.transform:SetAsLastSibling()
            switchPanel(panel,console)
        end
        button(panel.transform, "打开 Unity 控制台", 0, firstOptionY - 3 * optionSpacing, showConsole)
        closeButton(console.transform,700,380, function()
            switchPanel(console,panel)
        end)
        button(console.transform, "清空", 0, -365, function()
            state.consoleLines={}
            scroll:StopMovement()
            refreshConsole(true)
        end)
        console:SetActive(false)
        closeButton(panel.transform,290,350,function()
            if state.settingsLeave then state.settingsLeave() end
        end)
        local version=label(rect("Version",panel.transform,210,-360,180,32),__HSRVersion() .. "@Rd")
        version.rectTransform.sizeDelta=UE.Vector2(180,32)
        version.alignment=UE.TextAnchor.MiddleRight
        version.fontSize=16
        version.color=UE.Color(0.35,0.35,0.35,1)
        local menu = UE.GameObject.Find("MobilePhoneMainPage(Clone)")
        local appList = menu and menu.transform:Find("Content/Content/LeftPlane/AppListMask/AppList/Viewport/Content")
        if not appList then error("ESC menu app list unavailable") end
        local template
        for i=0,appList.childCount-1 do
            local candidate=appList:GetChild(i)
            if candidate.name=="PhoneAppIconItem(Clone)" then template=candidate; break end
        end
        if not template then error("ESC menu icon template unavailable") end
        local tab = UE.Object.Instantiate(template.gameObject, appList, false)
        tab.name = "HSRPlayToolsMenuEntry"
        local tr=tab.transform
        tr.anchoredPosition = UE.Vector2(324,-648)
        for i=0,tr.childCount-1 do tr:GetChild(i).gameObject:SetActive(false) end
        local nativeButton=tab:GetComponent(typeof(UE.UI.Button))
        nativeButton.onClick=UE.UI.Button.ButtonClickedEvent()
        local hit=tab:GetComponent(typeof(UE.UI.Image))
        if not hit then hit=tab:AddComponent(typeof(UE.UI.Image)) end
        hit.color=UE.Color(0,0,0,0.01)
        -- Clone the native tile background, including its tint and opacity.
        local templateImages=template:GetComponentsInChildren(typeof(UE.UI.Image),true)
        for i=0,templateImages.Length-1 do
            local background=templateImages[i]
            if background.name=="Image" and background.sprite and background.sprite.name=="WhiteBgV2" then
                local nativeBackground=UE.Object.Instantiate(background.gameObject,tr,false)
                nativeBackground.name="PlayToolsBackground"
                nativeBackground:SetActive(true)
                nativeBackground.transform:SetAsFirstSibling()
                nativeBackground:GetComponent(typeof(UE.UI.Image)).raycastTarget=false
                break
            end
        end
        hit.raycastTarget=true
        nativeButton.targetGraphic=hit
        local hover=rect("PlayToolsHover",tr,0,0,96,96):AddComponent(typeof(UE.UI.Image))
        hover.color=UE.Color(1,1,1,0)
        hover.raycastTarget=false
        state.entryHoverImage=hover
        state.entryHoverAlpha=0
        state.entryHoverDuration=math.max(0.08,nativeButton.colors.fadeDuration)
        state.settingsTab=tab
        -- Keep the native grid outline around the HSRP letter icon.
        local menuImages=menu:GetComponentsInChildren(typeof(UE.UI.Image),true)
        local outlineSprite, outlineColor
        for i=0,menuImages.Length-1 do
            local image=menuImages[i]
            if image.sprite then
                if image.sprite.name=="Outline2px" and not outlineSprite then
                    outlineSprite,outlineColor=image.sprite,image.color
                end
            end
        end
        local icon=label(rect("PlayToolsIcon",tr,0,13,88,48),"HSR+")
        icon.rectTransform.sizeDelta=UE.Vector2(88,48)
        icon.fontSize=28
        icon.fontStyle=UE.FontStyle.Bold
        icon.color=UE.Color(1,1,1,1)
        if outlineSprite then
            local border=rect("PlayToolsBorder",tr,0,0,96,96):AddComponent(typeof(UE.UI.Image))
            border.sprite=outlineSprite
            border.type=UE.UI.Image.Type.Sliced
            border.color=outlineColor
            border.raycastTarget=false
        end
        local caption = label(rect("PlayToolsCaption", tr, 0, -28, 94, 28), "增强工具")
        caption.fontSize = 14
        caption.rectTransform.sizeDelta=UE.Vector2(94,28)
        caption.resizeTextForBestFit=false
        local nativeLabels=template:GetComponentsInChildren(typeof(UE.UI.Text),true)
        for i=0,nativeLabels.Length-1 do
            local native=nativeLabels[i]
            if native.text and native.text~="" then
                caption.font=native.font
                caption.fontSize=native.fontSize
                caption.fontStyle=native.fontStyle
                break
            end
        end
        caption.color = UE.Color(1,1,1,1)
        local scroll=appList:GetComponentInParent(typeof(UE.UI.ScrollRect))
        state.menuViewport=scroll and scroll.viewport or appList.parent
        local blocker = rect("InputBlocker", created.transform, 0, 0, 3840, 2160)
        blocker:AddComponent(typeof(UE.UI.Image)).color = UE.Color(0,0,0,0)
        blocker.transform:SetAsFirstSibling()
        local function leave()
            if not state.playtoolsPageOpen then return end
            transition(panel,false)
            transition(console,false)
            transition(blocker,false,function() __HSRMouseCapture(-15) end)
            state.playtoolsPageOpen = false
        end
        local function openPlayTools()
            if state.playtoolsPageOpen then return end
            playUISound()
            __HSRMouseCapture(-14)
            refresh()
            transition(blocker,true)
            transition(panel,true)
            transition(console,false)
            state.playtoolsPageOpen = true
        end
        nativeButton.onClick:AddListener(openPlayTools)
        state.settingsOpen = openPlayTools
        state.settingsPanels={panel,console,blocker}
        for _,object in ipairs(state.settingsPanels) do
            local group=object:AddComponent(typeof(UE.CanvasGroup))
            group.alpha=0
            group.interactable=false
            group.blocksRaycasts=false
        end
        blocker:SetActive(false)
        state.settingsLeave = leave
        refresh()
        panel:SetActive(false)
        created.transform:SetAsLastSibling()
        state.settingsRoot = created
        state.settingsMenu = menu
    end)
    if not success then
        if created then created:SetActive(false); UE.Object.Destroy(created) end
        disposeSettings()
        error(failure)
    end
end
pcall(updateSettings)

local function invokeHoverButton(button,name,value)
    state.hoverButtonMethods=state.hoverButtonMethods or {}
    local kind=button:GetType()
    local key=tostring(kind.FullName) .. ":" .. name
    local method=state.hoverButtonMethods[key]
    if not method then
        local flags=CS.System.Enum.Parse(typeof(CS.System.Reflection.BindingFlags),"Instance, Public, NonPublic")
        local methods=kind:GetMethods(flags)
        local count=value==nil and 0 or 1
        for j=0,methods.Length-1 do
            if methods[j].Name==name and methods[j]:GetParameters().Length==count then method=methods[j];break end
        end
        if not method then error("Hover method unavailable: " .. key) end
        state.hoverButtonMethods[key]=method
    end
    local count=value==nil and 0 or 1
    state.hoverInvokeArgs=state.hoverInvokeArgs or {}
    local args=state.hoverInvokeArgs[count]
    if not args then
        args=CS.System.Array.CreateInstance(typeof(CS.System.Object),count)
        state.hoverInvokeArgs[count]=args
    end
    if value~=nil then args[0]=value end
    local result=method:Invoke(button,CS.System.Reflection.BindingFlags.Default,nil,args,nil)
    if count==1 then args[0]=nil end
    return result
end

local function applyUIScale()
local okFind, scalers = pcall(function()
    return UE.Resources.FindObjectsOfTypeAll(typeof(UE.UI.CanvasScaler))
end)
if okFind and scalers then
    for i = 0, scalers.Length - 1 do
        local scaler = scalers[i]
        pcall(function()
            if not scaler.isActiveAndEnabled then return end
            local scene = scaler.gameObject.scene
            if not scene:IsValid() or not scene.isLoaded then return end
            local canvas = scaler:GetComponent(typeof(UE.Canvas))
            -- Exclude world-space labels and nested canvas scalers.
            if not canvas or not canvas.isRootCanvas or canvas.renderMode == UE.RenderMode.WorldSpace then return end
            -- Plugin overlays keep the same layout whether created before or after this pass.
            local name = scaler.gameObject.name
            if name == "HSRPlayToolsSettings" or name == gyroPromptName then return end
            local id = scaler:GetInstanceID()
            local mode
            if scaler.uiScaleMode == UE.UI.CanvasScaler.ScaleMode.ConstantPixelSize then mode = 0
            elseif scaler.uiScaleMode == UE.UI.CanvasScaler.ScaleMode.ScaleWithScreenSize then mode = 1 end
            if mode ~= 0 and mode ~= 1 then return end
            if not __HSRScaleBaseline then return end
            local reference = scaler.referenceResolution
            local bx, by, bf = __HSRScaleBaseline(id, mode, reference.x, reference.y, scaler.scaleFactor)
            if not bx then return end
            local baseline = {x = bx, y = by, factor = bf}
            if mode == 1 then
                scaler.referenceResolution = UE.Vector2(baseline.x / state.target,
                                                       baseline.y / state.target)
            else
                scaler.scaleFactor = baseline.factor * state.target
            end
        end)
    end
end

end
state.applyUIScale=applyUIScale
applyUIScale()

-- Use the native cursor controller for Alt/UI state; macOS capture supplies
-- relative movement where iOS Cursor.lockState is ineffective.
if type(rawget(_G,"__HSRNativeInputFrame"))~="function" then
    pcall(observeActivityPage)
    pcall(observeLightConePreviews)
    rawset(_G, "__HSRNativeInputFrame", function()
        if not __HSRMouseCapture then
            gyroLightConePanel = nil
            return
        end
        pcall(syncWindowFocus)
        local ok = pcall(function()
            local alt = __HSRMouseCapture(-1) == 1
            local tabWheel = UE.Input.GetKey(UE.KeyCode.Tab)
            local ui = CS.RPG.Client.GlobalVars.s_UIManager
            local cursor = CS.RPG.Client.MouseInputController.Instance
            local current = UE.EventSystems.EventSystem.current
            if current and current:Equals(nil) then current=nil end
            if ui and ui:Equals(nil) then ui=nil end
            if cursor and cursor:Equals(nil) then cursor=nil end
            local module = current and current.currentInputModule
            if module and module:Equals(nil) then module=nil end
            local page = ui and tostring(ui:TopPageDialogName())
            local loginPage = page and string.find(page,"GameStartup",1,true)==1 or false
            local sessionChanged = page and state.runtimeLoginPage~=nil and state.runtimeLoginPage~=loginPage
            if sessionChanged or state.runtimeUI~=ui or state.runtimeEvents~=current or state.runtimeModule~=module or state.runtimeCursor~=cursor then
                -- Login can reuse the manager and EventSystem. Balance our force-show
                -- request before discarding its owner and rebuilding session caches.
                if state.playtoolsAlt then
                    pcall(function()
                        local previous=state.runtimeCursor or cursor
                        if previous and not previous:Equals(nil) then previous:CloseForceShowCursor() end
                        if ui then ui:UpdateCursorState() end
                    end)
                end
                __HSRMouseCapture(-10)
                pcall(function()
                    if state.activeHoverAnimator and not state.activeHoverAnimator:Equals(nil) and state.cursorEvent then
                        invokeHoverButton(state.activeHoverAnimator,"OnPointerExit",state.cursorEvent)
                    end
                end)
                disposeSettings()
                hideGyroPrompt(true)
                state.cursorEvent=nil
                state.cursorHits=nil
                state.pointerHoverMethod=nil
                state.pointerHoverArgs=nil
                state.pendingHoverAnimator=nil
                state.activeHoverAnimator=nil
                state.hoverSelectedObject=nil
                state.hoverPreviousSelection=nil
                state.uiPointerGesture=false
                state.uiGesturePage=nil
                state.avatarRotationBlocked=false
                state.avatarScrollRects=nil
                state.layoutPage=nil
                state.settingsFramePage=nil
                state.playtoolsAlt=false
                state.gameCursorVisible=nil
                state.nativeCursorReady=nil
                state.cursorStyleRequested=nil
                state.cursorAssetLoadAttempted=nil
                state.hoverButtonMethods=nil
                state.hoverInvokeArgs=nil
                state.runtimeUI,state.runtimeEvents,state.runtimeModule,state.runtimeCursor=ui,current,module,cursor
                if state.consoleCallback then
                    pcall(function() UE.Application.logMessageReceived("-",state.consoleCallback) end)
                    pcall(function() UE.Application.logMessageReceived("+",state.consoleCallback) end)
                end
            end
            if page then state.runtimeLoginPage=loginPage end
            if not ui or not cursor or not current or not module then
                gyroLightConePanel = nil
                updateGyroEffect(nil)
                updateTransitions()
                __HSRMouseCapture(0)
                __HSRMouseCapture(-8)
                return
            end
            local gyroEligible = state.gyroSimulation and page and page~="" and not loginPage and not explorationPages[page]
                and not module.IsShowSDKUI and not state.playtoolsPageOpen
            local gyroPage = gyroEligible and page or nil
            local lightConePreview = visibleLightConePreview(gyroPage)
            gyroLightConePanel = updateGyroEffect(gyroPage, lightConePreview) and lightConePreview or nil
            if gyroLightConePanel then
                pcall(function()
                    -- The stock gyro callback takes the horizontal tilt in card coordinates.
                    local gravity = CS.RPG.Client.GyroManager.Instance.Gravity
                    gyroLightConePanel:set_lightcone_rot(-gravity.x)
                end)
            end
            if __HSRMouseDimensions then __HSRMouseDimensions(UE.Screen.width,UE.Screen.height) end
            if __HSRMouseCapture(-16)==1 and state.playtoolsPageOpen and state.settingsLeave then
                playUISound("CommonCancel")
                state.settingsLeave()
            end
            updateTransitions()
            if state.consoleDirty and state.consoleRefresh and not state.uiTransitions then pcall(state.consoleRefresh) end
            if state.layoutPage~=page or state.layoutWidth~=UE.Screen.width or state.layoutHeight~=UE.Screen.height then
                applyUIScale()
                updateAvatarScrolls(page)
                state.layoutPage,state.layoutWidth,state.layoutHeight=page,UE.Screen.width,UE.Screen.height
            elseif page=="AvatarMainPage" and not state.avatarScrollRects then
                updateAvatarScrolls(page)
            end

            -- Create and release the entry when the menu changes.
            local missingMenuEntry = page=="MobilePhonePage" and
                (not state.settingsTab or state.settingsTab:Equals(nil))
            local menuHidden=false
            if state.settingsRoot then
                local menu=state.settingsMenu
                menuHidden=not menu or menu:Equals(nil) or not menu.activeInHierarchy
            end
            if state.settingsFramePage~=page or missingMenuEntry or menuHidden then
                local ready,reason=pcall(updateSettings)
                if ready then state.settingsFramePage=page
                else
                    error("settings UI: " .. tostring(reason))
                end
            end
            updateEntryHover(page,module)
            local press,release=__HSRMouseCapture(-13)
            local target=state.altModeTapTarget
            if state.playtoolsPageOpen and target and not target:Equals(nil)
                and target.gameObject.activeInHierarchy and not module.IsShowSDKUI then
                local position=UE.Input.mousePosition
                local point=UE.Vector2(position.x,position.y)
                if press~=state.altPressSeen then
                    state.altModeTap=nil
                    if UE.RectTransformUtility.RectangleContainsScreenPoint(target,point,nil) then
                        state.altModeTap={x=point.x,y=point.y}
                    end
                end
                local tap=state.altModeTap
                if tap and (point.x-tap.x)^2+(point.y-tap.y)^2>400 then state.altModeTap=nil end
                if release~=state.altReleaseSeen then
                    if state.altModeTap and UE.RectTransformUtility.RectangleContainsScreenPoint(target,point,nil)
                        and state.altModeTapAction then state.altModeTapAction() end
                    state.altModeTap=nil
                end
            else state.altModeTap=nil end
            state.altPressSeen,state.altReleaseSeen=press,release
            local world = explorationPages[page] == true
            if world and not module.IsShowSDKUI and not state.firstWorldEntered then
                state.firstWorldEntered=__HSRMouseCapture(-11)==1
                alt=__HSRMouseCapture(-1)==1
            end
            __HSRMouseCapture(world and -6 or -5)
            -- Real taps on PlayTools-owned tiles; drag gestures remain scrolling.
            if page=="MobilePhonePage" and not state.playtoolsPageOpen and state.settingsTab
                and not state.settingsTab:Equals(nil) and not (module and module.IsShowSDKUI) then
                local entry=state.settingsTab.transform
                local camera=canvasCamera(entry)
                local function contains(rect,point)
                    return rect and not rect:Equals(nil)
                        and UE.RectTransformUtility.RectangleContainsScreenPoint(rect,point,camera)
                end
                for i=0,UE.Input.touchCount-1 do
                    local touch=UE.Input.GetTouch(i)
                    local point=touch.position
                    if touch.phase==UE.TouchPhase.Began then
                        state.menuTap=nil
                        if contains(state.menuViewport,point) then
                            if contains(entry,point) then
                                state.menuTap={id=touch.fingerId,x=point.x,y=point.y,target=entry,action=state.settingsOpen}
                            end
                        end
                    elseif state.menuTap and state.menuTap.id==touch.fingerId then
                        local tap=state.menuTap
                        if (point.x-tap.x)^2+(point.y-tap.y)^2>400 or touch.phase==UE.TouchPhase.Canceled then
                            state.menuTap=nil
                        elseif touch.phase==UE.TouchPhase.Ended then
                            state.menuTap=nil
                            if contains(tap.target,point) and contains(state.menuViewport,point) and tap.action then tap.action() end
                        end
                    end
                end
            else state.menuTap=nil end

            -- Suppress model rotation while the pointer owns a scroll gesture.
            local overScroll=false
            local touches=UE.Input.touchCount
            local point=UE.Input.mousePosition
            if touches>0 then point=UE.Input.GetTouch(0).position end
            if page=="AvatarMainPage" and state.avatarScrollRects then
                for i=0,state.avatarScrollRects.Length-1 do
                    local scroll=state.avatarScrollRects[i]
                    if scroll and scroll.isActiveAndEnabled then
                        local rect=scroll.viewport or scroll.transform
                        local camera=canvasCamera(scroll)
                        if UE.RectTransformUtility.RectangleContainsScreenPoint(rect,UE.Vector2(point.x,point.y),camera) then overScroll=true;break end
                    end
                end
            end
            -- A gesture starting on an interactive UI element owns the pointer
            -- until release, even when dragged beyond the original element.
            local pointerHeld = UE.Input.GetMouseButton(0)
            local pointerBegan = UE.Input.GetMouseButtonDown(0)
            for i=0,touches-1 do
                local touch=UE.Input.GetTouch(i)
                if touch.phase==UE.TouchPhase.Began then pointerBegan=true end
                if touch.phase~=UE.TouchPhase.Ended and touch.phase~=UE.TouchPhase.Canceled then pointerHeld=true end
            end
            if state.uiGesturePage~=page then
                state.uiPointerGesture=false
                state.uiGesturePage=page
            end
            if pointerBegan and current then
                local hitUI=false
                local function hitControl(position)
                    local event=UE.EventSystems.PointerEventData(current)
                    event.position=UE.Vector2(position.x,position.y)
                    local hits=CS.System.Collections.Generic.List(typeof(UE.EventSystems.RaycastResult))()
                    current:RaycastAll(event,hits)
                    if hits.Count>0 then
                        local object=hits[0].gameObject
                        local selectable=object:GetComponentInParent(typeof(UE.UI.Selectable))
                        local scroll=object:GetComponentInParent(typeof(UE.UI.ScrollRect))
                        return (selectable and selectable.isActiveAndEnabled) or
                            (scroll and scroll.isActiveAndEnabled) or false
                    end
                    return false
                end
                if touches>0 then
                    for i=0,touches-1 do
                        local touch=UE.Input.GetTouch(i)
                        if touch.phase==UE.TouchPhase.Began and hitControl(touch.position) then hitUI=true end
                    end
                else hitUI=hitControl(point) end
                state.uiPointerGesture=state.uiPointerGesture or hitUI
            end
            if not pointerHeld and not pointerBegan then state.uiPointerGesture=false end
            local blocked=state.uiPointerGesture or overScroll or __HSRMouseCapture(-9)==1 or false
            if blocked~=state.avatarRotationBlocked then
                require("Logic.NotifyManager").notify(CS.RPG.Client.NotifyType.UIUnLockCameraRotation,not blocked)
                state.avatarRotationBlocked=blocked
            end
            if cursor then
                if alt and world and not tabWheel and not state.playtoolsAlt then
                    cursor:ForceShowCursor()
                    state.playtoolsAlt = true
                elseif not alt and not tabWheel and state.playtoolsAlt then
                    cursor:CloseForceShowCursor()
                    if ui then ui:UpdateCursorState() end
                    state.playtoolsAlt = false
                end
            end
            if not world or (module and module.IsShowSDKUI) then
                __HSRMouseCapture(-4)
            end
            local immersive = world and cursor and not cursor.UseCursorMode
                and not alt and not tabWheel and not (state.uiPointerGesture or overScroll) and module and not module.IsShowSDKUI
            -- Lock before capture can recenter, rather than one frame later.
            local _,wasCaptured=__HSRMouseCapture(-1)
            if immersive and wasCaptured~=1 and not state.avatarRotationBlocked then
                require("Logic.NotifyManager").notify(CS.RPG.Client.NotifyType.UIUnLockCameraRotation,false)
                state.avatarRotationBlocked=true
            end
            local _, captured = __HSRMouseCapture(immersive and 1 or 0)
            -- The retained NSCursor survives game asset and Lua context teardown.
            -- Query that owner before attempting another texture conversion.
            if not state.nativeCursorReady and __HSRCursorImage then
                state.nativeCursorReady=__HSRCursorImage()==1
            end
            -- Pointer events belong to the EventSystem, independently of artwork.
            if not state.cursorEvent then
                state.cursorEvent=UE.EventSystems.PointerEventData(current)
                state.cursorHits=CS.System.Collections.Generic.List(typeof(UE.EventSystems.RaycastResult))()
            end
            -- Artwork failure must never stop hover dispatch or other input work.
            if not state.nativeCursorReady and __HSRCursorImage then
                pcall(function()
                    local flags=CS.System.Enum.Parse(typeof(CS.System.Reflection.BindingFlags),"Instance, Static, Public, NonPublic")
                    if not state.cursorStyleRequested then cursor:SetCursorSprite();state.cursorStyleRequested=true end
                    local field=cursor:GetType():GetField("_Mouse64IconSharedAsset",flags)
                    local asset=field and field:GetValue(cursor)
                    local texture=asset and asset:Get()
                    if asset and (not texture or texture:Equals(nil)) and not state.cursorAssetLoadAttempted then
                        state.cursorAssetLoadAttempted=true
                        texture=asset:Load()
                    end
                    if texture and not texture:Equals(nil) then
                        local active=UE.RenderTexture.active
                        local rt=UE.RenderTexture.GetTemporary(texture.width,texture.height,0)
                        local copy=nil
                        local converted,png=pcall(function()
                            UE.Graphics.Blit(texture,rt)
                            UE.RenderTexture.active=rt
                            copy=UE.Texture2D(texture.width,texture.height,UE.TextureFormat.RGBA32,false)
                            copy:ReadPixels(UE.Rect(0,0,texture.width,texture.height),0,0)
                            copy:Apply()
                            return CS.System.Convert.ToBase64String(UE.ImageConversion.EncodeToPNG(copy))
                        end)
                        UE.RenderTexture.active=active
                        UE.RenderTexture.ReleaseTemporary(rt)
                        if copy then UE.Object.Destroy(copy) end
                        if not converted then error(png) end
                        state.nativeCursorReady=__HSRCursorImage(png)==1
                    end
                end)
            end
            state.pendingHoverAnimator=nil
            do
                local pos=UE.Input.mousePosition
                local visible=captured~=1 and UE.Application.isFocused and pos.x>=0 and pos.y>=0
                    and pos.x<UE.Screen.width and pos.y<UE.Screen.height
                __HSRMouseCapture(visible and state.nativeCursorReady and -7 or -8)
                local target=nil
                local nativeHoverButton=false
                if current and visible then
                    state.cursorEvent.position=UE.Vector2(pos.x,pos.y)
                    state.cursorHits:Clear()
                    current:RaycastAll(state.cursorEvent,state.cursorHits)
                    if state.cursorHits.Count>0 then
                        local hit=state.cursorHits[0]
                        state.cursorEvent.pointerCurrentRaycast=hit
                        target=hit.gameObject
                        local buttons=target:GetComponentsInParent(typeof(CS.RPG.Client.AnimatorButton))
                        for j=0,buttons.Length-1 do
                            if buttons[j].isActiveAndEnabled and buttons[j]:IsInteractable() then
                                invokeHoverButton(buttons[j],"SetMobileHoverEnable",true)
                                nativeHoverButton=true
                                if not state.pendingHoverAnimator then state.pendingHoverAnimator=buttons[j] end
                            end
                        end
                    end
                end
                if module and state.cursorEvent then
                    if not state.pointerHoverMethod then
                        local flags=CS.System.Enum.Parse(typeof(CS.System.Reflection.BindingFlags),"Instance, Public, NonPublic")
                        local methods=typeof(UE.EventSystems.BaseInputModule):GetMethods(flags)
                        for j=0,methods.Length-1 do
                            if methods[j].Name=="HandlePointerExitAndEnter" and methods[j]:GetParameters().Length==2 then
                                state.pointerHoverMethod=methods[j];break
                            end
                        end
                        state.pointerHoverArgs=CS.System.Array.CreateInstance(typeof(CS.System.Object),2)
                        if not state.pointerHoverMethod then error("UI hover dispatch method unavailable") end
                    end
                    -- Unity maintains the hovered hierarchy and sends balanced
                    -- pointer-exit/enter events, including custom game handlers.
                    state.pointerHoverArgs[0]=state.cursorEvent
                    state.pointerHoverArgs[1]=target
                    state.pointerHoverMethod:Invoke(module,CS.System.Reflection.BindingFlags.Default,nil,state.pointerHoverArgs,nil)

                end
                -- Bridge only scrolling. Re-running ProcessMouseEvent also
                -- dispatches button edges already handled by the game's input.
                local wheel=UE.Input.mouseScrollDelta
                if target and module and module.isActiveAndEnabled and (wheel.x~=0 or wheel.y~=0) then
                    local contract=typeof(UE.EventSystems.IScrollHandler)
                    if not state.scrollMethod then
                        state.scrollMethod=contract:GetMethod("OnScroll")
                        state.scrollArgs=CS.System.Array.CreateInstance(typeof(CS.System.Object),1)
                    end
                    state.cursorEvent.scrollDelta=wheel
                    state.scrollArgs[0]=state.cursorEvent
                    local node=target.transform
                    while node do
                        local handled=false
                        local handlers=node:GetComponents(typeof(UE.Component))
                        for j=0,handlers.Length-1 do
                            local handler=handlers[j]
                            if handler and contract:IsAssignableFrom(handler:GetType())
                                and (not typeof(UE.Behaviour):IsAssignableFrom(handler:GetType()) or handler.isActiveAndEnabled) then
                                state.scrollMethod:Invoke(handler,CS.System.Reflection.BindingFlags.Default,nil,state.scrollArgs,nil)
                                handled=true
                            end
                        end
                        if handled then break end
                        node=node.parent
                    end
                    state.scrollArgs[0]=nil
                end
                if current then
                    local candidate=nil
                    if target and visible and not nativeHoverButton then
                        local handlers=target:GetComponentsInParent(typeof(UE.Component))
                        local contract=typeof(UE.EventSystems.ISelectHandler)
                        for j=0,handlers.Length-1 do
                            local handler=handlers[j]
                            if handler and contract:IsAssignableFrom(handler:GetType()) then
                                local object=handler.gameObject
                                local selectable=object:GetComponent(typeof(UE.UI.Selectable))
                                if not selectable or (selectable.isActiveAndEnabled and selectable:IsInteractable()) then
                                    candidate=object;break
                                end
                            end
                        end
                    end
                    if candidate~=state.hoverSelectedObject then
                        if state.hoverSelectedObject and not state.hoverSelectedObject:Equals(nil)
                            and current.currentSelectedGameObject==state.hoverSelectedObject then
                            local previous=state.hoverPreviousSelection
                            if previous and previous:Equals(nil) then previous=nil end
                            current:SetSelectedGameObject(previous)
                        end
                        state.hoverSelectedObject=nil
                        state.hoverPreviousSelection=nil
                        if candidate then
                            state.hoverPreviousSelection=current.currentSelectedGameObject
                            current:SetSelectedGameObject(candidate)
                            state.hoverSelectedObject=candidate
                        end
                    end
                end
            end
            -- Let the game own cursor styling; synchronize visibility only on
            -- capture transitions instead of overriding its visible getter.
            local showGameCursor=captured~=1
            if state.gameCursorVisible~=showGameCursor then
                if ui then ui:UpdateCursorState() end
                UE.Cursor.visible=showGameCursor
                state.gameCursorVisible=showGameCursor
            end
            pcall(function()
                local button=state.pendingHoverAnimator
                local previous=state.activeHoverAnimator
                if previous~=button and previous and not previous:Equals(nil) then
                    invokeHoverButton(previous,"OnPointerExit",state.cursorEvent)
                end
                state.activeHoverAnimator=button
                if button and not button:Equals(nil) then
                    local before=invokeHoverButton(button,"IsPointerInside")
                    invokeHoverButton(button,"SetMobileHoverEnable",true)
                    if not before then invokeHoverButton(button,"OnPointerEnter",state.cursorEvent) end
                    invokeHoverButton(button,"UpdateSelectState")

                end
            end)
        end)
        if not ok then
            gyroLightConePanel = nil
            __HSRGyroPointer(0)
            pcall(hideGyroPrompt,true)
            __HSRMouseCapture(0)
            __HSRMouseCapture(-8)
        end
    end)
end
return nil
