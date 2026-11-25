-- Hunter Pet Atlas: puntos de aparición en el mapa del mundo y el minimapa (translúcidos, un color
-- por bestia, con un brillo que late alrededor).
--
-- El mapa del juego se queda TAL CUAL: solo con las zonas que has explorado (antes el add-on dibujaba
-- encima las zonas sin explorar, y eso chocaba con OpenMap / el Map Pro de Tool Belt Pro).
-- Con el Map Pro de Tool Belt Pro (el mapa continuo de OpenMap): «Seguir» una bestia o «Mostrar en el
-- mapa» abre Map Pro en su zona, y los brillos salen en todo el mapa continuo, también en las zonas de
-- al lado. Sin Tool Belt Pro, se abre el mapa del juego como siempre.
local _, ns = ...
local L, DB, UI = ns.L, ns.DB, ns.UI

local WP = {}
ns.WorldPins = WP

local DOT = "Interface\\CHARACTERFRAME\\TempPortraitAlphaMask"
local GLOW = "Interface\\AddOns\\HunterPetAtlas\\Media\\glow"
local MAX_WORLD_PINS = 600
local PALETTE = {
    { 1, 0.86, 0.15 }, { 0.3, 0.9, 1 }, { 1, 0.4, 0.85 }, { 0.55, 1, 0.35 },
    { 1, 0.55, 0.2 }, { 0.55, 0.65, 1 }, { 1, 1, 1 }, { 0.75, 0.55, 1 },
}
local worldPool, miniPool = {}, {}
local lastKey, elapsed = nil, 0
local spanCache = {}
local lastRadius, lastFacing, lastMx, lastMy, lastEast, lastNorth, lastSlideMap

local function ColorFor(id)
    if DB:IsRare(id) then
        return 0.78, 0.55, 1
    end
    local c = PALETTE[(id % #PALETTE) + 1]
    return c[1], c[2], c[3]
end

-- Bestias a dibujar: las seguidas y la que estás mirando en el bestiario.
local function ActiveIDs()
    local ids = {}
    if ns.db and ns.db.settings.worldPins then
        for id in pairs(ns.db.tracked) do
            if ns.NPCs[id] then
                ids[id] = true
            end
        end
    end
    if WP.focus and ns.NPCs[WP.focus] then
        ids[WP.focus] = true
    end
    return ids
end

local function ShowPinTooltip(self)
    local id = self.npc
    if not id then
        return
    end
    GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
    GameTooltip:AddLine(ns.Color(DB:NameColor(id), DB:NpcName(id)))
    GameTooltip:AddLine(string.format("%s %s - %s", L.LEVEL, DB:LevelText(id), DB:FamilyName(ns.NPCs[id].f)), 1, 1, 1)
    GameTooltip:AddLine(DB:LookName(ns.NPCs[id].lk), 0.8, 0.8, 0.8)
    if self.x then
        GameTooltip:AddLine(string.format("%.1f, %.1f", self.x * 100, self.y * 100), 0.6, 0.8, 1)
    end
    if ns.NPCs[id].r then
        GameTooltip:AddLine(L.RESPAWN .. ": " .. ns.FormatMinutesRange(ns.NPCs[id].r), 0.75, 0.75, 1)
    end
    GameTooltip:AddLine(L.CLICK_OPEN, 0.5, 0.5, 0.5)
    GameTooltip:Show()
end

-- Brillo que late alrededor del punto (del color de la bestia)
local function AddGlow(pin, size)
    local glow = pin:CreateTexture(nil, "BACKGROUND", nil, -1)
    glow:SetTexture(GLOW)
    glow:SetBlendMode("ADD")
    glow:SetSize(size * 3.2, size * 3.2)
    glow:SetPoint("CENTER")
    pin.glow = glow
    local ok, anim = pcall(glow.CreateAnimationGroup, glow)
    if ok and anim and anim.CreateAnimation then
        local fade = anim:CreateAnimation("Alpha")
        if fade and fade.SetFromAlpha then
            fade:SetFromAlpha(0.35)
            fade:SetToAlpha(1)
            fade:SetDuration(1.1)
            if fade.SetSmoothing then
                fade:SetSmoothing("IN_OUT")
            end
        end
        if anim.SetLooping then
            anim:SetLooping("BOUNCE")
        end
        pin.glowAnim = anim
        pin:HookScript("OnShow", function(self)
            if self.glowAnim and not self.glowAnim:IsPlaying() then
                self.glowAnim:Play()
            end
        end)
    end
end

-- Punto translúcido: círculo de color con un borde suave más oscuro y su brillo.
local function MakePin(parent, size)
    local pin = CreateFrame("Button", nil, parent)
    pin:SetSize(size, size)
    AddGlow(pin, size)
    pin.edge = pin:CreateTexture(nil, "BACKGROUND")
    pin.edge:SetTexture(DOT)
    pin.edge:SetPoint("TOPLEFT", -2, 2)
    pin.edge:SetPoint("BOTTOMRIGHT", 2, -2)
    pin.dot = pin:CreateTexture(nil, "ARTWORK")
    pin.dot:SetTexture(DOT)
    pin.dot:SetAllPoints()
    pin:SetScript("OnEnter", ShowPinTooltip)
    pin:SetScript("OnLeave", GameTooltip_Hide)
    pin:SetScript("OnClick", function(self)
        if self.npc then
            ns.SafeCall(ns.SelectNpc, self.npc)
        end
    end)
    function pin:Paint(id, focus)
        local r, g, b = ColorFor(id)
        self.dot:SetVertexColor(r, g, b, focus and 0.7 or 0.55)
        self.edge:SetVertexColor(r * 0.25, g * 0.25, b * 0.25, 0.35)
        if self.glow then
            self.glow:SetVertexColor(r, g, b, focus and 0.9 or 0.7)
        end
        if self.glowAnim and self:IsShown() and not self.glowAnim:IsPlaying() then
            self.glowAnim:Play()
        end
    end
    return pin
end

---------------------------------------------------------------------------
-- Tool Belt Pro: Map Pro (el mapa continuo de OpenMap, dentro de la ventana del mapa del juego)
---------------------------------------------------------------------------
-- ¿Hay Map Pro para abrir? (Tool Belt Pro instalado, con Map Pro encendido y su mapa continuo dentro)
function WP.HasMapPro()
    local fn = rawget(_G, "ToolBelt_MapProAvailable")
    if type(fn) ~= "function" then
        return false
    end
    local ok, on = pcall(fn)
    return ok and on and true or false
end

-- Abre Map Pro en un sitio (un mapa del juego y un punto 0..1 de él). true si se ha abierto Map Pro.
function WP.OpenMapPro(uiMap, x, y)
    local fn = rawget(_G, "ToolBelt_MapProOpenAt")
    if type(fn) ~= "function" or not WP.HasMapPro() then
        return false
    end
    local ok, opened = pcall(fn, uiMap, x, y)
    return ok and opened and true or false
end

-- El mapa del juego enseña ahora el mapa continuo (Map Pro / OpenMap): su API pública, si es así
local function Stitched()
    local api = rawget(_G, "OpenMapAPI")
    if type(api) ~= "table" or type(api.IsStitched) ~= "function" then
        return nil
    end
    local ok, on = pcall(api.IsStitched)
    if ok and on and type(api.WorldFromMap) == "function" and type(api.MapFromWorld) == "function" then
        return api
    end
    return nil
end

-- Un punto (0..1) del mapa de la bestia, en el mapa sobre el que se apoya el mapa continuo (puede salirse de 0..1: el mapa continuo enseña más allá)
local function OnStitched(api, hostMap, uiMap, x, y)
    if uiMap == hostMap then
        return x, y
    end
    local ok, u, v = pcall(api.WorldFromMap, uiMap, x, y)
    if not (ok and u) then
        return nil
    end
    local ok2, cx, cy = pcall(api.MapFromWorld, hostMap, u, v)
    if ok2 and cx then
        return cx, cy
    end
    return nil
end

local function Canvas()
    return WorldMapFrame and WorldMapFrame.GetCanvas and WorldMapFrame:GetCanvas()
end

local function CanvasScale()
    local sc = WorldMapFrame and WorldMapFrame.ScrollContainer
    if sc and sc.GetCanvasScale then
        local ok, s = pcall(sc.GetCanvasScale, sc)
        if ok and s and s > 0 then
            return s
        end
    end
    return 1
end

local function HideWorld()
    for _, p in ipairs(worldPool) do
        p:Hide()
    end
end

-- (Las zonas sin explorar ya NO se dibujan sobre el mapa del juego: el mapa se queda como lo has explorado tú.)

local function UpdateWorld()
    if not (WorldMapFrame and WorldMapFrame:IsShown()) then
        HideWorld()
        lastKey = nil
        return
    end
    local canvas = Canvas()
    local mapID = WorldMapFrame:GetMapID()
    if not canvas or not mapID then
        return
    end
    local w, h = canvas:GetWidth(), canvas:GetHeight()
    local scale = CanvasScale()
    -- con el mapa continuo (Map Pro / OpenMap) se ven también las zonas de al lado: sus puntos se pasan al mapa sobre el que se apoya
    local api = Stitched()
    local key = table.concat({ mapID, math.floor(w), math.floor(h), math.floor(scale * 100), WP.version or 0, api and 1 or 0 }, ":")
    if key == lastKey then
        return
    end
    lastKey = key
    local level = canvas:GetFrameLevel() + 2000
    if api and type(api.ArtTopLevel) == "function" then
        local ok, top = pcall(api.ArtTopLevel)
        if ok and type(top) == "number" and top + 10 > level then
            level = top + 10                      -- por encima del dibujo del mapa continuo
        end
    end
    local used = 0
    for id in pairs(ActiveIDs()) do
        local e = ns.NPCs[id]
        local zoneMap = DB:UiMapForArea(e.z)
        if zoneMap and (zoneMap == mapID or api) then
            local focus = (id == WP.focus)
            for x, y in DB:Points(id) do
                local cx, cy = x, y
                if api then
                    cx, cy = OnStitched(api, mapID, zoneMap, x, y)
                end
                if cx and used < MAX_WORLD_PINS then
                    used = used + 1
                    local pin = worldPool[used]
                    if not pin then
                        pin = MakePin(canvas, 13)
                        worldPool[used] = pin
                    end
                    pin:SetParent(canvas)
                    pin:SetFrameLevel(level)
                    pin.npc, pin.x, pin.y = id, x, y
                    -- tamaño constante en pantalla aunque se haga zoom; los desplazamientos van en la escala del pin
                    local k = (1 / scale) * (focus and 1.2 or 1)
                    pin:SetScale(k)
                    pin:ClearAllPoints()
                    pin:SetPoint("CENTER", canvas, "TOPLEFT", cx * w / k, -cy * h / k)
                    pin:Show()
                    pin:Paint(id, focus)
                end
            end
        end
    end
    for i = used + 1, #worldPool do
        worldPool[i]:Hide()
    end
end

---------------------------------------------------------------------------
-- Minimapa
---------------------------------------------------------------------------
local function Number(v)
    return type(v) == "number" and not (issecretvalue and issecretvalue(v))
end

local function VectorXY(ok, a, b)
    local v = (type(b) == "table" and b) or (type(a) == "table" and a)
    if not v then
        return nil
    end
    local x, y = v.x, v.y
    if v.GetXY then
        x, y = v:GetXY()
    end
    if Number(x) and Number(y) then
        return x, y
    end
end

local function MapSpans(mapID)
    local c = spanCache[mapID]
    if c then
        return c[1], c[2]
    end
    if C_Map.GetMapWorldSize then
        local ok, w, h = pcall(C_Map.GetMapWorldSize, mapID)
        if ok and Number(w) and Number(h) and w > 0 and h > 0 then
            spanCache[mapID] = { w, h }
            return w, h
        end
    end
    if not (C_Map.GetWorldPosFromMapPos and CreateVector2D) then
        return 0, 0
    end
    local tlx, tly = VectorXY(pcall(C_Map.GetWorldPosFromMapPos, mapID, CreateVector2D(0, 0)))
    local brx, bry = VectorXY(pcall(C_Map.GetWorldPosFromMapPos, mapID, CreateVector2D(1, 1)))
    if not tlx then
        return 0, 0
    end
    local w, h = math.abs(brx - tlx), math.abs(bry - tly)
    if w <= 0 or h <= 0 then
        return 0, 0
    end
    spanCache[mapID] = { w, h }
    return w, h
end

local function UnitEastNorth()
    if type(UnitPosition) ~= "function" then
        return nil
    end
    local ok, north, east = pcall(UnitPosition, "player")
    if not ok or not Number(north) or not Number(east) then
        return nil
    end
    return east, north
end

-- Map 0..1. GetPlayerMapPosition while it is usable; while moving (secret/stale) slide with UnitPosition.
local function PlayerMapXY(mapID)
    local ok, pos = pcall(C_Map.GetPlayerMapPosition, mapID, "player")
    if ok and pos and not (issecretvalue and issecretvalue(pos)) then
        local mx, my = pos:GetXY()
        if Number(mx) and Number(my) then
            lastMx, lastMy, lastSlideMap = mx, my, mapID
            local east, north = UnitEastNorth()
            if east then
                lastEast, lastNorth = east, north
            end
            return mx, my
        end
    end
    local east, north = UnitEastNorth()
    local spanX, spanY = MapSpans(mapID)
    if lastSlideMap == mapID and lastMx and east and lastEast and spanX > 0 and spanY > 0 then
        lastMx = lastMx + (east - lastEast) / spanX
        lastMy = lastMy - (north - lastNorth) / spanY
        lastEast, lastNorth = east, north
        return lastMx, lastMy
    end
    if lastSlideMap == mapID then
        return lastMx, lastMy
    end
end

local ZOOM_YARDS = { [0] = 466.666, [1] = 400, [2] = 333.333, [3] = 266.666, [4] = 200, [5] = 166.666 }

local function ViewRadius()
    if C_Minimap and C_Minimap.GetViewRadius then
        local ok, r = pcall(C_Minimap.GetViewRadius)
        if ok and Number(r) and r > 0 then
            lastRadius = r
            return r
        end
    end
    if lastRadius then
        return lastRadius
    end
    if Minimap.GetZoom then
        local ok, z = pcall(Minimap.GetZoom, Minimap)
        if ok and Number(z) and ZOOM_YARDS[z] then
            return ZOOM_YARDS[z]
        end
    end
    return 200
end

local function HideMini()
    for _, p in ipairs(miniPool) do
        p:Hide()
    end
end

local function UpdateMinimap()
    -- SexyMap still uses the same Minimap object; HUD mode hides it (IsShown).
    if not (ns.db and ns.db.settings.miniPins and Minimap and Minimap:IsShown()) then
        HideMini()
        return
    end
    local ok, mapID = pcall(C_Map.GetBestMapForUnit, "player")
    if not ok or not Number(mapID) then
        HideMini()
        return
    end
    local px, py = PlayerMapXY(mapID)
    local radius = ViewRadius()
    local spanX, spanY = MapSpans(mapID)
    if not px or not radius or radius <= 0 or spanX <= 0 then
        HideMini()
        return
    end
    local halfW, halfH = Minimap:GetWidth() / 2, Minimap:GetHeight() / 2
    if halfW <= 0 then
        HideMini()
        return
    end
    local rotate = false
    if GetCVar then
        local cok, cv = pcall(GetCVar, "rotateMinimap")
        rotate = cok and cv == "1"
    end
    local facing = 0
    if rotate and GetPlayerFacing then
        local fok, f = pcall(GetPlayerFacing)
        if fok and Number(f) then
            facing = f
            lastFacing = f
        else
            facing = lastFacing or 0
        end
    end
    local cos, sin = math.cos(facing), math.sin(facing)
    local used = 0
    local level = Minimap:GetFrameLevel() + 8
    for id in pairs(ActiveIDs()) do
        local e = ns.NPCs[id]
        if DB:UiMapForArea(e.z) == mapID then
            for x, y in DB:Points(id) do
                -- Map y grows south; SetPoint y grows up. Match the minimap texture (walk north → dots slide down).
                local fx, fy = (x - px) * spanX / radius, (y - py) * spanY / radius
                if rotate then
                    fx, fy = fx * cos - fy * sin, fx * sin + fy * cos
                end
                if fx * fx + fy * fy <= 0.95 and used < 60 then
                    used = used + 1
                    local pin = miniPool[used]
                    if not pin then
                        pin = MakePin(Minimap, 10)
                        miniPool[used] = pin
                    end
                    pin:SetFrameStrata(Minimap:GetFrameStrata() or "MEDIUM")
                    pin:SetFrameLevel(level)
                    pin:Paint(id, id == WP.focus)
                    pin.npc, pin.x, pin.y = id, x, y
                    pin:ClearAllPoints()
                    pin:SetPoint("CENTER", Minimap, "CENTER", fx * halfW, -fy * halfH)
                    pin:Show()
                end
            end
        end
    end
    for i = used + 1, #miniPool do
        miniPool[i]:Hide()
    end
end

---------------------------------------------------------------------------
function WP:Refresh()
    self.version = (self.version or 0) + 1
    lastKey = nil
end

function WP:SetFocus(id)
    self.focus = id
    self:Refresh()
end

function WP:ShowOnWorldMap(id)
    local e = ns.NPCs[id]
    if not e then
        return
    end
    local uiMap = DB:UiMapForArea(e.z)
    if not uiMap then
        ns.Print(L.NO_MAP)
        return
    end
    self:SetFocus(id)
    if InCombatLockdown() then
        ns.Print(L.COMBAT_LOCKED)
        return
    end
    -- ocultamos nuestra ventana para que se vea el mapa (se vuelve a abrir con /hpa o el botón del minimapa)
    if ns.MainFrame and ns.MainFrame:IsShown() then
        ns.MainFrame:Hide()
    end
    -- con Tool Belt Pro: su Map Pro, en la zona de la bestia (y deslizado hasta donde aparece)
    local x, y = DB:CenterPoint(id)
    if WP.OpenMapPro(uiMap, x, y) then
        self:Refresh()
        return
    end
    if C_Map.OpenWorldMap then
        C_Map.OpenWorldMap(uiMap)
    else
        if not WorldMapFrame:IsShown() then
            ToggleWorldMap()
        end
        WorldMapFrame:SetMapID(uiMap)
    end
end

function WP:SetWaypoint(id)
    local e = ns.NPCs[id]
    local uiMap = e and DB:UiMapForArea(e.z)
    local x, y = DB:CenterPoint(id)
    if not uiMap or not x then
        ns.Print(L.NO_COORDS)
        return
    end
    local title = DB:NpcName(id)
    if TomTom and TomTom.AddWaypoint then
        TomTom:AddWaypoint(uiMap, x, y, { title = title, persistent = false })
    end
    if C_Map.SetUserWaypoint and UiMapPoint and UiMapPoint.CreateFromCoordinates then
        local can = not C_Map.CanSetUserWaypointOnMap or C_Map.CanSetUserWaypointOnMap(uiMap)
        if can then
            C_Map.SetUserWaypoint(UiMapPoint.CreateFromCoordinates(uiMap, x, y))
            if C_SuperTrack and C_SuperTrack.SetSuperTrackedUserWaypoint then
                C_SuperTrack.SetSuperTrackedUserWaypoint(true)
            end
        end
    end
    ns.Print(string.format("%s: %s %.1f, %.1f", title, DB:ZoneName(e.z), x * 100, y * 100))
end

local driver = CreateFrame("Frame")
driver:SetScript("OnUpdate", function(_, dt)
    -- Minimap every frame so dots slide with you. World map can wait.
    ns.SafeCall(UpdateMinimap)
    elapsed = elapsed + dt
    if elapsed < 0.1 then
        return
    end
    elapsed = 0
    ns.SafeCall(UpdateWorld)
end)

ns.On("HPA_TRACKED_CHANGED", function(_, id)
    WP:Refresh()
    -- «Seguir» una bestia con Tool Belt Pro: se abre su Map Pro en la zona de la bestia, con los brillos de dónde aparece
    -- (sin Tool Belt Pro no se abre nada: los puntos salen en el mapa y el minimapa como siempre)
    local e = id and ns.NPCs[id]
    if e and DB:IsTracked(id) and DB:UiMapForArea(e.z) and WP.HasMapPro() and not InCombatLockdown() then
        WP:ShowOnWorldMap(id)
    end
end)
ns.On("MAP_EXPLORATION_UPDATED", function()
    WP:Refresh()
end)
