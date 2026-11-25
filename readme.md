Hunter Pet Atlas — minimap spawn pins (Forever / Camelot, Interface 16001)
For: Ragnarson. File: UI\WorldPins.lua (UpdateMinimap / OnUpdate).
Date: 2026-11-25. Local notes from a player (Micheal) + what actually broke.

This file is NOT in the TOC. Reference only.

================================================================
What was wrong
================================================================

1) Pins did not stay on the ground while walking
   UpdateMinimap ran with the world map on a 0.1s timer and used only
   C_Map.GetPlayerMapPosition(mapID, "player").
   On Forever that position is often secret (issecretvalue) or stale while
   moving. Pins froze on the minimap; the terrain kept scrolling.

2) Walk north: minimap texture scrolls down (correct). Pins moved up.
   Map coordinates: y grows south. Frame SetPoint y grows up.
   Old placement:
     fy = (py - y) * spanY / radius
     SetPoint(..., fx * halfW, -fy * halfH)
   Walking north, py drops, -fy goes up. Opposite of the texture.

3) Mixing UnitPosition yards with GetWorldPosFromMapPos as if they were
   the same space hid EVERY pin (failed the on-minimap radius check).
   Do not do that.

4) pcall(C_Minimap.GetViewRadius, C_Minimap) passes self. The API is
   C_Minimap.GetViewRadius() with no arguments. Wrong call → no radius
   → HideMini() → no pins. SexyMap is not the cause: it still uses the
   same Minimap object. (SexyMap HUD mode HIDES Minimap; then pins cannot
   show — that is expected.)

================================================================
How to fix it properly (keep this, do not revert blindly)
================================================================

A. Update minimap pins EVERY FRAME. Keep world-map pins on ~0.1s.

B. Player map 0..1:
   - If GetPlayerMapPosition returns a non-secret x,y, use it and remember
     UnitPosition at the same time.
   - If it is secret/nil, SLIDE from the last good 0..1 using UnitPosition
     (plain numbers while moving). UnitPosition("player") is north, east
     (first return north/south, second east/west).

     lastMx += (east - lastEast) / spanX
     lastMy -= (north - lastNorth) / spanY

     spanX/spanY = map size in yards (C_Map.GetMapWorldSize, or abs of
     GetWorldPosFromMapPos corners  (0,0) and (1,1)).
     pcall those APIs; treat issecretvalue as unusable.

C. Placement (HereBeDragons-style Y, map y south-positive):

     fx = (x - px) * spanX / radius
     fy = (y - py) * spanY / radius     -- NOT (py - y)
     if rotateMinimap:
         fx, fy = fx*cos - fy*sin, fx*sin + fy*cos
     SetPoint("CENTER", Minimap, "CENTER", fx * halfW, -fy * halfH)

   Check: walk north → texture AND dots slide down. Walk east → both slide left.

D. Radius: pcall(C_Minimap.GetViewRadius) with NO extra args. If secret/nil,
   keep last good radius; fallback Minimap:GetZoom() yards table
   (0=466.67 … 5=166.67).

E. Parent pins to Minimap (SexyMap / MoveAny still that frame). FrameLevel
   Minimap+8. Use Minimap:IsShown(), not only IsVisible(). Do not HookScript
   WorldFrame OnMouseDown.

F. Secret-safe: pcall + issecretvalue on GetBestMapForUnit, GetPlayerFacing,
   GetCVar("rotateMinimap"), GetXY. If facing/radius fail, reuse last value;
   do not HideMini() just because one sample was secret.

================================================================
Do not
================================================================

- Do not convert spawn 0..1 through GetWorldPosFromMapPos and subtract
  UnitPosition and hope the axes match. Standing pins vanish.
- Do not throttle minimap updates to 0.1s.
- Do not assume GetPlayerMapPosition works in motion on Forever.

NodeSight (same client) already does UnitPosition + slide for minimap
icons if you want a working reference. HereBeDragons-Pins uses world
east/north and SetPoint(diffX * w, -diffY * h) with player-minus-pin.
