// conjunction editor mode: the companion app reads the mouse and keys and calls these exec functions over the debugger
// port; the game casts the rays, places, selects, moves, deletes. Changes are reported to the script log (channel
// W3S) as machine-readable lines - the app writes them into the project.

class CjEditor {
    var on : bool;
    var movingSaid : float;             // when the dragged object's pose was last told to the app (cj_move_to)
    var placing : bool;                 // place mode (preview follows the cursor) or select mode
    var preview : CEntity;
    var template : string;
    var look : string;                  // placing: a person's look chosen in the app ("": the game picks one)
    var placed : array<CEntity>;
    var templates : array<string>;      // template of placed[i]
    var homes : array<Vector>;          // placed[i] where the project has it (the game's push or walk while
    var homeRots : array<EulerAngles>;  // playing does not count - MaximdeWinter 08.10.: NPCs placed on one spot)
    var selected : CEntity;
    var fovVertical : bool;
    var place : string;
    var musicOff : bool;
    var musicVolume : string;
    var grid : float;                   // placing: snap to a grid of this many metres (0 = off)
    var align : bool;                   // placing: tilt with the surface under the cursor
    var randomYaw : bool;               // placing: every new object turned at random
    var userRot : EulerAngles;          // the preview's turn as the user set it (aligning adds the tilt)
    var group : array<CEntity>;         // more selected with Shift+click: they move / go / are copied along
    var light : int;                    // 0 as the game has it, 1 morning, 2 midday, 3 evening, 4 night (CjLight)
    var lampOn : bool;                  // the lamp at the camera (H)
    var lampPower : float;              // its strength (H held + wheel): 1 as built, more is brighter and farther
    var lamp : CEntity;
    var toFreeze : array<CActor>;       // placed people, frozen once they stand in their idle pose (CjFreezeDue)
    var freezeAt : array<float>;
    var editExisting : bool;            // select and edit entities already in the world, not only our placed ones
    var hiddenWorld : array<CEntity>;   // objects of the game removed while editing (hidden: they can come back)
    var looks : array<string>;          // placed[i]'s look as cj_appearance gave it ("": its own)
    var renew : array<CEntity>;         // placed things moved: made anew where they stand once still (CjRenewDue)
    var renewAt : array<float>;
    var reportSet : bool;               // the next report says this transform: a teleport takes effect next frame
    var reportAt : Vector;              // (an object the game placed still reads where it was - measured 04.10.)
    var reportRot : EulerAngles;
    var plantSrt : string;              // placing a plant of the foliage library: its tree (.srt) - the preview is a
    var plantRes : CResource;           // ghost: only the tree drawn by the script extender, no entity, no
    var ghost : bool;                   // collision (CjGhostTo); the click makes the real one there
    var ghostAt : Vector;
    var ghostRot : EulerAngles;
    var ghostBorn : float;              // when the newest ghost was drawn (engine time)
    var pending : bool;                 // a place the cursor went to while the newest was too young to move on
    var pendingAt : Vector;
    var pendingRot : EulerAngles;
    var oldAt : array<Vector>;          // earlier ghosts, taken out once they surely stand (CjGhostDue)
    var oldBorn : array<float>;
    var oldRes : array<CResource>;
    var plantedAt : Vector;             // where the last plant was placed: no ghost there (taking it out later would
    var planted : bool;                 // take the planted tree's look along - the remove is by radius)
}

// What the editor may pick. Always our own placed objects; with editExisting on, any world entity too. Never
// the player (deleting or teleporting Geralt breaks the session).
function CjSelectable(ed : CjEditor, ent : CEntity) : bool {
    if (!ent || ent == thePlayer) {
        return false;
    }
    return ed.editExisting || ent.HasTag('cj_placed');
}

// the editor's light: the environment's clock held at an hour (clear sky) - 0 as the game has it, 1 morning,
// 2 midday, 3 evening, 4 night. The engine's unlit debug view would be ideal; its call (EnableDebugOverlayFilter)
// crashes the released game (29.09.).
function CjLight(mode : int) {
    if (mode >= 1 && mode <= 4) {
        if (mode == 1) {
            ForceFakeEnvTime(8.0);
        } else if (mode == 2) {
            ForceFakeEnvTime(12.0);
        } else if (mode == 3) {
            ForceFakeEnvTime(19.5);
        } else {
            ForceFakeEnvTime(0.5);
        }
        RequestWeatherChangeTo('WT_Clear', 1.0, false);
    } else {
        DisableFakeEnvTime();
    }
}

// the editor's lamp (H): a flashlight flying and turning with the camera - caves, interiors, night
function CjLamp(on : bool) {
    var ed : CjEditor;
    var tpl : CEntityTemplate;
    ed = theGame.CjEditorGet();
    if (on && !ed.lamp) {
        tpl = (CEntityTemplate)LoadResource("dlc\dlcconjunctionmeshes\data\entities\cj_editor_lamp.w2ent", true);
        if (tpl) {
            // doNotAdjustPlacement: else the engine puts the spawned lamp down onto the ground
            ed.lamp = theGame.CreateEntity(tpl, thePlayer.w3sFlyPos, thePlayer.w3sFlyRot, true, false, true,
                                           PM_DontPersist);
            CjLampApply();
        }
    } else if (!on && ed.lamp) {
        ed.lamp.Destroy();
        ed.lamp = NULL;
    }
}

// the lamp's strength: brightness with it, reach with its root (built: brightness 25, radius 25). The light's
// fields are script-visible since the remaster; switched off and on so the engine takes the new values.
function CjLampApply() {
    var ed : CjEditor;
    var light : CLightComponent;
    ed = theGame.CjEditorGet();
    if (!ed.lamp) {
        return;
    }
    light = (CLightComponent)ed.lamp.GetComponentByClassName('CSpotLightComponent');
    if (light) {
        light.brightness = 25.0 * ed.lampPower;
        light.radius = 25.0 * SqrtF(ed.lampPower);
        light.SetEnabled(false);
        light.SetEnabled(true);
    }
}

exec function cj_lamp_power(power : float) {
    var ed : CjEditor;
    ed = theGame.CjEditorGet();
    ed.lampPower = power;
    CjLampApply();
    CjOut("lamppower|" + FloatToString(power));
}

exec function cj_lamp(on : bool) {
    var ed : CjEditor;
    ed = theGame.CjEditorGet();
    ed.lampOn = on;
    if (ed.on) {
        CjLamp(on);
    }
    CjOut("lamp|" + CjYesNo(on) + "|" + CjYesNo(ed.lamp));
}

// the lamp goes where the camera goes and shines where it looks (conjunction_cam.ws CjFlyTick)
function CjLampFollow(pos : Vector, rot : EulerAngles) {
    var ed : CjEditor;
    ed = theGame.CjEditorGet();
    if (ed.lamp) {
        ed.lamp.TeleportWithRotation(pos, rot);
    }
}

exec function cj_light(mode : int) {
    var ed : CjEditor;
    ed = theGame.CjEditorGet();
    ed.light = mode;
    if (ed.on) {
        CjLight(mode);
    }
    CjOut("light|" + IntToString(mode));
}

// where the group stands (the app marks them): "group|x,y,z;x,y,z"
function CjReportGroup() {
    var ed : CjEditor;
    var i : int;
    var line : string;
    var p : Vector;
    ed = theGame.CjEditorGet();
    line = "group|";
    for (i = 0; i < ed.group.Size(); i += 1) {
        if (ed.group[i]) {
            p = ed.group[i].GetWorldPosition();
            line += FloatToString(p.X) + "," + FloatToString(p.Y) + "," + FloatToString(p.Z) + ";";
        }
    }
    CjOut(line);
}

@addField(CR4Game)
var w3sEditor : CjEditor;

@addMethod(CR4Game)
function CjEditorGet() : CjEditor {
    if (!w3sEditor) {
        w3sEditor = new CjEditor in this;
        w3sEditor.fovVertical = true;      // checked by clicking (28.09.): the camera fov counts vertically
        w3sEditor.placing = false;              // the editor starts in look mode with nothing chosen
        w3sEditor.template = "";
        w3sEditor.lampPower = 1.0;
    }
    return w3sEditor;
}

function CjTemplateOf(e : CEntity) : string {
    var ed : CjEditor;
    var i : int;
    ed = theGame.CjEditorGet();
    i = ed.placed.FindFirst(e);
    if (i >= 0) {
        return ed.templates[i];
    }
    return "";
}

// an entity teleported now, and the report that follows says where it went (CjReport reads it back otherwise)
function CjPutAndReport(e : CEntity, p : Vector, r : EulerAngles) : CEntity {
    var ed : CjEditor;
    ed = theGame.CjEditorGet();
    e = CjPut(e, p, r);
    ed.reportSet = true;
    ed.reportAt = p;
    ed.reportRot = r;
    return e;
}

// one machine-readable line per change: the companion app writes it into the project (no copy-paste)
function CjReport(what : string, e : CEntity, template : string, optional extra : string) {
    var p : Vector;
    var r : EulerAngles;
    var ed : CjEditor;
    var game : string;
    var i : int;
    ed = theGame.CjEditorGet();
    p = e.GetWorldPosition();
    r = e.GetWorldRotation();
    i = ed.placed.FindFirst(e);
    if (ed.reportSet) {
        p = ed.reportAt;
        r = ed.reportRot;
        ed.reportSet = false;
    } else if (what == "selected" && i >= 0) {
        p = ed.homes[i];                    // the project knows it there (the game may have pushed it since)
        r = ed.homeRots[i];
    }
    if (i >= 0 && what != "selected") {
        ed.homes[i] = p;
        ed.homeRots[i] = r;
    }
    if (!e.HasTag('cj_placed')) {
        game = "|game=1";                   // placed by the game, not by this project: a world change
    }
    CjOut("change|" + what + "|place=" + ed.place + "|world=" + theGame.GetWorld().GetDepotPath()
        + "|template=" + template + "|pos=" + FloatToString(p.X) + "," + FloatToString(p.Y) + "," + FloatToString(p.Z)
        + "|rot=" + FloatToString(r.Roll) + "," + FloatToString(r.Pitch) + "," + FloatToString(r.Yaw)
        + "|guid=" + TW3SE_EntityGuid(e) + "|name=" + e.GetReadableName() + game + extra);
    if (what == "selected" && !e.HasTag('cj_placed')) {
        CjWorldInfo(e);
    }
}

// ray through the screen point (sx, sy: 0..1 from the top left of the game window's client area; aspect = width /
// height): pinhole camera from the camera's own axes and field of view (fov counts vertically). While the editor
// flies, the editor camera's own pose (theCamera still reports the gameplay camera).
function CjRay(sx : float, sy : float, aspect : float, out origin : Vector, out dir : Vector) {
    var f, r, u : Vector;
    var tv, th : float;
    f = theCamera.GetCameraForward();
    r = theCamera.GetCameraRight();
    u = theCamera.GetCameraUp();
    origin = theCamera.GetCameraPosition();
    if (thePlayer.w3sFlyOn) {
        thePlayer.CjFlyAxes(f, r, u);
        origin = thePlayer.w3sFlyPos;
    }
    if (theGame.CjEditorGet().fovVertical) {
        tv = TanF(Deg2Rad(theCamera.GetFov()) * 0.5);
        th = tv * aspect;
    } else {
        th = TanF(Deg2Rad(theCamera.GetFov()) * 0.5);
        tv = th / aspect;
    }
    dir = VecNormalize(f + r * ((2 * sx - 1) * th) + u * ((1 - 2 * sy) * tv));
}

// how far along the line from start (dir normalized) it leaves the box, 0 if it does not cross it
function CjBoxExit(start : Vector, dir : Vector, box : Box) : float {
    var t, a, b, lo, hi, s, d : float;
    var k : int;
    t = 1000000;
    for (k = 0; k < 3; k += 1) {
        if (k == 0) { s = start.X; d = dir.X; lo = box.Min.X; hi = box.Max.X; }
        else if (k == 1) { s = start.Y; d = dir.Y; lo = box.Min.Y; hi = box.Max.Y; }
        else { s = start.Z; d = dir.Z; lo = box.Min.Z; hi = box.Max.Z; }
        if (AbsF(d) > 0.0001) {
            a = (lo - s) / d;
            b = (hi - s) / d;
            t = MinF(t, MaxF(a, b));
        } else if (s < lo || s > hi) {
            return 0;
        }
    }
    return MaxF(t, 0);
}

// first hit along a line that is neither skipA nor skipB (the preview, the object being moved). A skipped one hit:
// on from just inside where the line leaves its bounding box (23.10.: in 5 cm steps a 5.5 m flag pole was never
// passed - the trace gave up and the flag floated on the navmesh)
function CjTraceLine(from : Vector, to : Vector, skipA : CEntity, skipB : CEntity, out hit : Vector,
                      out hitEntity : CEntity) : bool {
    var passed : CEntity;
    return CjTraceLinePassed(from, to, skipA, skipB, hit, hitEntity, passed);
}

// the same; passed: the skipped one the line went through (NULL: none)
function CjTraceLinePassed(from : Vector, to : Vector, skipA : CEntity, skipB : CEntity, out hit : Vector,
                           out hitEntity : CEntity, out passed : CEntity) : bool {
    var normal, dir, start, back : Vector;
    var material : name;
    var comp : CComponent;
    var backEnt : CEntity;
    var i : int;
    dir = VecNormalize(to - from);
    start = from;
    passed = NULL;
    for (i = 0; i < 30; i += 1) {         // (a moved thing's old collision lies outside its box: 5 cm steps)
        if (!theGame.GetWorld().StaticTraceWithAdditionalInfo(start, to, hit, normal, material, comp)) {
            return false;
        }
        hitEntity = NULL;
        if (comp) {
            hitEntity = comp.GetEntity();
        }
        if (!hitEntity || (hitEntity != skipA && hitEntity != skipB)) {
            return true;
        }
        passed = hitEntity;
        if (CjSkip(hitEntity, hit, dir, start, back, backEnt) && backEnt != skipA && backEnt != skipB) {
            hit = back;
            hitEntity = backEnt;
            return true;
        }
        if (VecDot(to - start, dir) <= 0) {
            return false;
        }
    }
    return false;
}

// where a line that hit e at hit goes on: from just inside where it leaves e's bounding box, at least 5 cm on
function CjPast(e : CEntity, hit : Vector, dir : Vector) : Vector {
    var box : Box;
    var p : Vector;
    e.CalcBoundingBox(box);
    p = hit + dir * MaxF(CjBoxExit(hit, dir, box) - 0.02, 0.05);
    p.W = 1;
    return p;
}

// a line that hit e (to be passed) at hit goes on at onward (CjPast). Something else inside e's box on the way (the
// ground under a sunk or tilted object) would be passed with it: a trace back from onward finds it -> true, there
function CjSkip(e : CEntity, hit : Vector, dir : Vector, out onward : Vector, out back : Vector,
                out backEnt : CEntity) : bool {
    var normal, to : Vector;
    var material : name;
    var comp : CComponent;
    onward = CjPast(e, hit, dir);
    backEnt = NULL;
    if (VecDistance(onward, hit) < 0.06) {
        return false;
    }
    to = hit + dir * 0.01;
    to.W = 1;
    if (!theGame.GetWorld().StaticTraceWithAdditionalInfo(onward, to, back, normal, material, comp)) {
        return false;
    }
    if (comp) {
        backEnt = comp.GetEntity();
    }
    return backEnt != e;
}

// the highest surface below p (above p + up): what a straight trace hits (objects, the ground) and the physics'
// ground (PhysicsCorrectZ) - 06.10.: a trace down alone found the objects but not the ground, Drop did nothing over
// plain ground. The walkable ground (NavigationComputeZ) only when neither found anything: the navmesh lies up to 30 cm
// above the real ground (measured 23.10. at the camp: ground 32.70, navmesh 32.99) - everything moved floated on it
function CjSurfaceBelow(p : Vector, up : float, skipA : CEntity, skipB : CEntity, out z : float) : bool {
    var hit, normal, at, c : Vector;
    var ent, passed : CEntity;
    var terrain : array<name>;
    var box : Box;
    var gz, top : float;
    var k : int;
    var found : bool;
    found = false;
    top = p.Z + up;
    if (CjTraceLinePassed(Vector(p.X, p.Y, top, 1), Vector(p.X, p.Y, p.Z - 100, 1), skipA, skipB, hit, ent, passed)) {
        z = hit.Z;
        found = true;
    }
    // the ground alone: no thing is in the group Terrain, the moved one neither (23.10.: a flag pole standing on the
    // ground - the line through the pole came out under the ground and found a cave 27 m down)
    terrain.PushBack('Terrain');
    if (theGame.GetWorld().StaticTrace(Vector(p.X, p.Y, top, 1), Vector(p.X, p.Y, p.Z - 100, 1), hit, normal, terrain)
            && (!found || hit.Z > z)) {
        z = hit.Z;
        found = true;
    }
    // the line went through the moved thing (its foot stands on what holds it - a floor, a table - and the line came
    // out below that): what it stands on, just outside its footprint on four sides - no higher than 10 cm above its
    // foot (a wall or a fence beside it is not what holds it)
    if (passed) {
        passed.CalcBoundingBox(box);
        c = passed.GetWorldPosition();
        for (k = 0; k < 4; k += 1) {
            at = p;
            if (k == 0) {
                at.X = p.X + box.Min.X - c.X - 0.03;
            } else if (k == 1) {
                at.X = p.X + box.Max.X - c.X + 0.03;
            } else if (k == 2) {
                at.Y = p.Y + box.Min.Y - c.Y - 0.03;
            } else {
                at.Y = p.Y + box.Max.Y - c.Y + 0.03;
            }
            if (CjTraceLine(Vector(at.X, at.Y, top, 1), Vector(at.X, at.Y, p.Z - 100, 1), skipA, skipB, hit, ent)
                    && hit.Z <= top - up + 0.1 + MaxF(up - 1.5, 0) && (!found || hit.Z > z)) {
                z = hit.Z;
                found = true;
            }
        }
    }
    // the physics' ground: when the trace found nothing, or found less high - but never above p's foot, there it is
    // the moved thing itself (the physics cannot leave it out). 23.10.: a flag pole 5 mm in the ground - the trace
    // went past the pole into the ground and found a cave 27 m down; the physics had the ground
    if (theGame.GetWorld().PhysicsCorrectZ(Vector(p.X, p.Y, p.Z + up, 1), gz) && gz <= p.Z + up
            && (!found || (gz > z && gz <= p.Z + 0.05))) {
        z = gz;
        found = true;
    }
    if (!found && theGame.GetWorld().NavigationComputeZ(Vector(p.X, p.Y, p.Z, 1), p.Z - 100, p.Z + up, gz)) {
        z = gz;
        found = true;
    }
    return found;
}

function CjTrace(sx : float, sy : float, aspect : float, out hit : Vector, out hitEntity : CEntity) : bool {
    var origin, dir : Vector;
    var ed : CjEditor;
    ed = theGame.CjEditorGet();
    CjRay(sx, sy, aspect, origin, dir);
    return CjTraceLine(origin, origin + dir * 400, ed.preview, NULL, hit, hitEntity);
}

// creatures in the editor (preview, copies) stand still and leave Geralt alone: friendly, invulnerable, pose frozen
function CjCalm(e : CEntity) {
    var a : CActor;
    var ed : CjEditor;
    a = (CActor)e;
    if (!a) {
        return;
    }
    a.SetTemporaryAttitudeGroup('friendly_to_player', AGP_Default);
    a.SetImmortalityMode(AIM_Invulnerable, AIC_Default);
    // frozen at once it keeps the pose it has before its first frame: arms out (T-pose) - so a moment later
    ed = theGame.CjEditorGet();
    ed.toFreeze.PushBack(a);
    ed.freezeAt.PushBack(EngineTimeToFloat(theGame.GetEngineTime()) + 1.5);
}

// the editor's frame (CjFlyTick): people placed a moment ago stop where they stand, in their idle pose
// Every move of the editor's own things. A plant of the foliage library is teleported too, but its tree stays drawn
// where it was made (MaximdeWinter 04.10.) - moving a placed one is still to come (moving the drawn tree through the script
// extender froze the game). Placing one goes through the ghost below. -> the entity.
function CjPut(e : CEntity, pos : Vector, rot : EulerAngles) : CEntity {
    if (e) {
        if (e == thePlayer) {
            CjOffHorse();
        }
        e.TeleportWithRotation(pos, rot);
        CjSetHome(e, pos, rot);
    }
    return e;
}

// a placed one's place in the project: where the editor put it
function CjSetHome(e : CEntity, pos : Vector, rot : EulerAngles) {
    var ed : CjEditor;
    var person : CActor;
    var i : int;
    ed = theGame.CjEditorGet();
    i = ed.placed.FindFirst(e);
    if (i >= 0) {
        ed.homes[i] = pos;
        ed.homeRots[i] = rot;
        person = (CActor)e;
        if (!person) {
            CjRenewLater(e);
        }
    }
}

function CjAddPlaced(e : CEntity, template : string, pos : Vector, rot : EulerAngles) {
    var ed : CjEditor;
    ed = theGame.CjEditorGet();
    ed.placed.PushBack(e);
    ed.templates.PushBack(template);
    ed.homes.PushBack(pos);
    ed.homeRots.PushBack(rot);
    while (ed.looks.Size() < ed.placed.Size()) {   // (one per placed - after a live reload it starts empty)
        ed.looks.PushBack("");
    }
}

function CjForgetPlaced(i : int) {
    var ed : CjEditor;
    ed = theGame.CjEditorGet();
    ed.placed.Erase(i);
    ed.templates.Erase(i);
    ed.homes.Erase(i);
    ed.homeRots.Erase(i);
    if (i < ed.looks.Size()) {              // (after a live reload of the scripts it starts empty)
        ed.looks.Erase(i);
    }
}

// A thing's collision stays where it was made: a teleport moves only what is drawn (measured 23.10. with a chest:
// spawned at x 678, teleported to 681 - the traces still hit it at 678, 3 s later too; SetEnabled and
// SetHideInGame left it there as well, Destroy took it away). MaximdeWinter: a chest moved back to where it was made stood on
// an invisible chest. So a placed thing that was moved is made anew where it stands, 0.3 s after its last move (not
// on every step of a drag or of the wheel). People are not: their collision moves with them.
function CjRenewLater(e : CEntity) {
    var ed : CjEditor;
    var k : int;
    var at : float;
    ed = theGame.CjEditorGet();
    at = EngineTimeToFloat(theGame.GetEngineTime()) + 0.3;
    k = ed.renew.FindFirst(e);
    if (k >= 0) {
        ed.renewAt[k] = at;
    } else {
        ed.renew.PushBack(e);
        ed.renewAt.PushBack(at);
    }
}

function CjRenewDue() {
    var ed : CjEditor;
    var now : float;
    var k : int;
    var e : CEntity;
    ed = theGame.CjEditorGet();
    now = EngineTimeToFloat(theGame.GetEngineTime());
    for (k = ed.renew.Size() - 1; k >= 0; k -= 1) {
        if (ed.renewAt[k] <= now) {
            e = ed.renew[k];
            ed.renew.Erase(k);
            ed.renewAt.Erase(k);
            if (e) {
                CjRenew(e);
            }
        }
    }
}

// placed[i] made anew from its template where the project has it: its tags, its look and what is in it go along;
// the selection and the group hold the new one
function CjRenew(e : CEntity) : CEntity {
    var ed : CjEditor;
    var tpl : CEntityTemplate;
    var n : CEntity;
    var tags : array<name>;
    var items : array<SItemUniqueId>;
    var from, to : CInventoryComponent;
    var ge, gn : CGameplayEntity;
    var i, k : int;
    ed = theGame.CjEditorGet();
    i = ed.placed.FindFirst(e);
    if (i < 0) {
        return e;
    }
    tpl = (CEntityTemplate)LoadResource(ed.templates[i], true);
    if (!tpl) {
        return e;
    }
    n = theGame.CreateEntity(tpl, ed.homes[i], ed.homeRots[i]);
    if (!n) {
        return e;
    }
    tags = e.GetTags();
    for (k = 0; k < tags.Size(); k += 1) {
        n.AddTag(tags[k]);
    }
    CjShowClue(n);
    if (i < ed.looks.Size() && ed.looks[i] != "") {
        n.ApplyAppearance(ed.looks[i]);
    }
    ge = (CGameplayEntity)e;
    gn = (CGameplayEntity)n;
    if (ge && gn) {
        from = ge.GetInventory();
        to = gn.GetInventory();
        if (from && to) {
            to.GetAllItems(items);
            for (k = items.Size() - 1; k >= 0; k -= 1) {
                to.RemoveItem(items[k], to.GetItemQuantity(items[k]));
            }
            items.Clear();
            from.GetAllItems(items);
            for (k = 0; k < items.Size(); k += 1) {
                to.AddAnItem(from.GetItemName(items[k]), from.GetItemQuantity(items[k]), true, true);
            }
        }
    }
    ed.placed[i] = n;
    if (ed.selected == e) {
        ed.selected = n;
    }
    k = ed.group.FindFirst(e);
    if (k >= 0) {
        ed.group[k] = n;
    }
    CjDestroy(e);
    return n;
}

// back to editing: every placed one where the project has it (while playing the game pushed people apart that stood
// on one spot, or they walked - the editor shows what is saved, and a click finds them there)
function CjBackHome() {
    var ed : CjEditor;
    var i : int;
    ed = theGame.CjEditorGet();
    for (i = 0; i < ed.placed.Size(); i += 1) {
        if (ed.placed[i] && VecDistance(ed.placed[i].GetWorldPosition(), ed.homes[i]) > 0.05) {
            ed.placed[i].TeleportWithRotation(ed.homes[i], ed.homeRots[i]);
        }
    }
}

function CjDestroy(e : CEntity) {
    if (e) {
        e.Destroy();
    }
}

// The ghost of a plant being placed: the tree alone, drawn by the script extender (TW3SE_FoliagePlant /
// TW3SE_FoliageRemoveAt - MaximdeWinter's idea, 04.10.: move only the look while placing, the click plants the real one).
// Its tree resource is loaded from the .srt (a tree read out of an entity's component made the game freeze).
// A tree taken out right after it was drawn stays (MaximdeWinter 04.10.: moving the ghost left one every half second) - the
// render thread has not put it in yet. So a ghost is taken out only once it surely stands (0.3 s), and a new one is
// drawn at most every 0.08 s; in between the cursor's place waits (CjGhostDue draws it).
function CjGhostTo(pos : Vector, rot : EulerAngles) {
    var ed : CjEditor;
    var now : float;
    ed = theGame.CjEditorGet();
    if (!ed.plantRes) {
        return;
    }
    if (ed.ghost && VecDistance(ed.ghostAt, pos) < 0.03 && AbsF(AngleDistance(ed.ghostRot.Yaw, rot.Yaw)) < 0.1) {
        ed.pending = false;
        return;
    }
    if (!ed.ghost && ed.planted) {
        if (VecDistance(pos, ed.plantedAt) < 0.5) {
            return;
        }
        ed.planted = false;
    }
    now = theGame.GetEngineTimeAsSeconds();
    if (ed.ghost && now - ed.ghostBorn < 0.08) {
        ed.pending = true;
        ed.pendingAt = pos;
        ed.pendingRot = rot;
        return;
    }
    if (ed.ghost) {
        CjGhostRetire();
    }
    ed.pending = false;
    ed.ghost = TW3SE_FoliagePlant(ed.plantRes, pos.X, pos.Y, pos.Z, rot.Yaw, 1.0, 10.0, 35.0);
    ed.ghostAt = pos;
    ed.ghostRot = rot;
    ed.ghostBorn = now;
}

// the newest ghost to the old ones (taken out later)
function CjGhostRetire() {
    var ed : CjEditor;
    ed = theGame.CjEditorGet();
    if (ed.ghost) {
        ed.oldAt.PushBack(ed.ghostAt);
        ed.oldBorn.PushBack(ed.ghostBorn);
        ed.oldRes.PushBack(ed.plantRes);
    }
    ed.ghost = false;
}

// every frame (CjFlyTick): the waiting cursor place drawn, the old ghosts that surely stand taken out; `all`: every
// old one now (the editor goes off)
function CjGhostDue(optional all : bool) {
    var ed : CjEditor;
    var now : float;
    var i : int;
    ed = theGame.CjEditorGet();
    now = theGame.GetEngineTimeAsSeconds();
    if (ed.pending && ed.ghost && now - ed.ghostBorn >= 0.08) {
        CjGhostTo(ed.pendingAt, ed.pendingRot);
    }
    for (i = ed.oldAt.Size() - 1; i >= 0; i -= 1) {
        if (all || now - ed.oldBorn[i] >= 0.3) {
            if (ed.oldRes[i]) {
                TW3SE_FoliageRemoveAt(ed.oldRes[i], ed.oldAt[i].X, ed.oldAt[i].Y, ed.oldAt[i].Z, 0.1);
            }
            ed.oldAt.Erase(i);
            ed.oldBorn.Erase(i);
            ed.oldRes.Erase(i);
        }
    }
}

function CjGhostOff() {
    var ed : CjEditor;
    ed = theGame.CjEditorGet();
    ed.pending = false;
    CjGhostRetire();
}

// the app tells the tree of a plant template before it sets the template (the empty string cannot be passed: clear)
exec function cj_set_plant(srt : string) {
    var ed : CjEditor;
    ed = theGame.CjEditorGet();
    CjGhostOff();
    ed.plantSrt = srt;
    ed.plantRes = LoadResource(srt, true);
    CjOut("plant|" + srt + "|" + CjYesNo(ed.plantRes));
}

exec function cj_clear_plant() {
    var ed : CjEditor;
    ed = theGame.CjEditorGet();
    CjGhostOff();
    ed.plantSrt = "";
    ed.plantRes = NULL;
}

function CjFreezeDue() {
    var ed : CjEditor;
    var anim : CAnimatedComponent;
    var now : float;
    var i : int;
    ed = theGame.CjEditorGet();
    now = EngineTimeToFloat(theGame.GetEngineTime());
    for (i = ed.toFreeze.Size() - 1; i >= 0; i -= 1) {
        if (ed.freezeAt[i] <= now) {
            if (ed.toFreeze[i]) {
                anim = ed.toFreeze[i].GetRootAnimatedComponent();
                if (anim) {
                    anim.FreezePose();
                }
            }
            ed.toFreeze.Erase(i);
            ed.freezeAt.Erase(i);
        }
    }
}

function CjPreview(show : bool) {
    var ed : CjEditor;
    var tpl : CEntityTemplate;
    ed = theGame.CjEditorGet();
    if (ed.preview) {
        CjDestroy(ed.preview);
        ed.preview = NULL;
    }
    CjGhostOff();
    if (show && ed.template != "" && ed.plantSrt != "") {
        return;                                 // a plant: its ghost follows the cursor (cj_pick)
    }
    if (show && ed.template != "") {            // nothing chosen yet: nothing follows the cursor
        tpl = (CEntityTemplate)LoadResource(ed.template, true);
        if (tpl) {
            ed.preview = theGame.CreateEntity(tpl, thePlayer.GetWorldPosition(), ed.userRot);
            if (ed.look != "") {
                ed.preview.ApplyAppearance(ed.look);    // the one placed takes the preview's look
            }
            CjCalm(ed.preview);
            CjShowClue(ed.preview);
        }
    }
}

function CjMusic(off : bool) {
    var ed : CjEditor;
    var cfg : CInGameConfigWrapper;
    ed = theGame.CjEditorGet();
    cfg = theGame.GetInGameConfigWrapper();
    if (off && !ed.musicOff) {
        ed.musicVolume = cfg.GetVarValue('Audio', 'MusicVolume');
        cfg.SetVarValue('Audio', 'MusicVolume', "0");
        theSound.SoundEnableMusicEvents(false);
        ed.musicOff = true;
    } else if (!off && ed.musicOff) {
        cfg.SetVarValue('Audio', 'MusicVolume', ed.musicVolume);
        theSound.SoundEnableMusicEvents(true);
        ed.musicOff = false;
    }
    CjOut("music off=" + CjYesNo(ed.musicOff) + " restore=" + ed.musicVolume);
}

// the game's whole HUD (minimap, quest tracker, ...) off while editing: the system visibility overrides all others
function CjHud(show : bool) {
    var hud : CR4ScriptedHud;
    hud = (CR4ScriptedHud)theGame.GetHud();
    if (hud) {
        hud.ForceShow(show, HVS_System);
    }
}

// One of our placed objects is reported "deleted" (just un-place it, nothing persisted). An entity that was
// already in the world is reported "removed" - the app records that so the removal can be re-applied on load.
function CjReportRemoval(e : CEntity) {
    if (e.HasTag('cj_placed')) {
        CjReport("deleted", e, CjTemplateOf(e));
    } else {
        CjReport("removed", e, CjTemplateOf(e));
    }
}

// Gone from the world: one of ours is destroyed; an object of the game is hidden instead - Destroy does nothing to
// an entity of a layer (seen 04.10.). The script extender hides it the way a `remove` world edit does: its running
// effects stopped, its components (collision, interaction, light, sound) off - and brings exactly those back.
function CjRemove(e : CEntity) {
    var ed : CjEditor;
    if (e.HasTag('cj_placed')) {
        CjDestroy(e);
        return;
    }
    TW3SE_HideEntity(e, true);
    ed = theGame.CjEditorGet();
    ed.hiddenWorld.PushBack(e);
}

function CjWorldShow(e : CEntity) {
    TW3SE_HideEntity(e, false);
}

// a move taken back in the editor: the object with this GUID where it stood (no report - nothing to record)
exec function cj_world_put(guid : string, x : float, y : float, z : float, roll : float, pitch : float, yaw : float) {
    var e : CEntity;
    var rot : EulerAngles;
    e = TW3SE_EntityByGuid(guid);
    if (!e) {
        CjOut("worldput|none");
        return;
    }
    rot.Roll = roll;
    rot.Pitch = pitch;
    rot.Yaw = yaw;
    e.TeleportWithRotation(Vector(x, y, z, 1), rot);
    CjOut("worldput|" + guid);
}

// a removal taken back in the editor: the hidden object with this GUID is there again at once
exec function cj_world_show(guid : string) {
    var ed : CjEditor;
    var i : int;
    ed = theGame.CjEditorGet();
    for (i = ed.hiddenWorld.Size() - 1; i >= 0; i -= 1) {
        if (ed.hiddenWorld[i] && TW3SE_EntityGuid(ed.hiddenWorld[i]) == guid) {
            CjWorldShow(ed.hiddenWorld[i]);
            ed.hiddenWorld.Erase(i);
            CjOut("worldshow|" + guid);
            return;
        }
    }
    CjOut("worldshow|none");
}

function CjDeleteSelected() {
    var ed : CjEditor;
    var i : int;
    ed = theGame.CjEditorGet();
    if (!ed.selected) {
        return;
    }
    // the group goes along
    while (ed.group.Size() > 0) {
        if (ed.group[0]) {
            CjReportRemoval(ed.group[0]);
            i = ed.placed.FindFirst(ed.group[0]);
            if (i >= 0) {
                CjForgetPlaced(i);
            }
            CjRemove(ed.group[0]);
        }
        ed.group.Erase(0);
    }
    CjReportGroup();
    CjReportRemoval(ed.selected);
    i = ed.placed.FindFirst(ed.selected);
    if (i >= 0) {
        CjForgetPlaced(i);
    }
    CjRemove(ed.selected);
    ed.selected = NULL;
}

// An effect on the selected object (on: play it, off: stop it), reported so the app keeps it as a change to a
// world object (the script extender plays it every time the object comes into the world).
exec function cj_world_effect(fx : name, on : bool) {
    var ed : CjEditor;
    ed = theGame.CjEditorGet();
    if (!ed.selected) {
        CjOut("worldfx|none");
        return;
    }
    if (on && !ed.selected.HasEffect(fx)) {
        CjOut("worldfx|missing|" + NameToString(fx));
        return;
    }
    if (on) {
        ed.selected.PlayEffect(fx);
        CjReport("effect", ed.selected, CjTemplateOf(ed.selected), "|value=" + NameToString(fx));
    } else {
        ed.selected.StopEffect(fx);
        CjReport("effect_off", ed.selected, CjTemplateOf(ed.selected), "|value=" + NameToString(fx));
    }
}

// The selected object's look (its appearance component), reported like an effect.
exec function cj_world_look(look : string) {
    var ed : CjEditor;
    var comp : CAppearanceComponent;
    ed = theGame.CjEditorGet();
    if (!ed.selected) {
        CjOut("worldlook|none");
        return;
    }
    comp = (CAppearanceComponent)ed.selected.GetComponentByClassName('CAppearanceComponent');
    if (!comp) {
        CjOut("worldlook|nocomponent");
        return;
    }
    comp.ApplyAppearance(look);
    CjReport("look", ed.selected, CjTemplateOf(ed.selected), "|value=" + look);
}

// Toggle whether the editor may pick entities already in the world (not only our placed ones). The app sets
// this when the user turns on "edit existing world" so clicks select real world objects to move or remove.
exec function cj_edit_existing(on : bool) {
    var ed : CjEditor;
    ed = theGame.CjEditorGet();
    ed.editExisting = on;
    CjOut("editexisting|" + CjYesNo(on));
}

// While the suite runs, Esc is the editor's (MaximdeWinter 05.10.: playing from the editor, Esc goes back to editing, as in
// Unreal): the game's pause menu stays shut - the fact lives 10 s, the suite renews it - except while one of the
// game's menus is open (the game menu opened from the editor's File menu)
exec function cj_pause_menu_off() {
    if (!theGame.GetGuiManager().IsAnyMenu()) {
        FactsSet("nge_pause_menu_disabled", 1, 10);
    }
}

// Esc while playing: back to editing ("esc|edit") - not in a dialogue, a cutscene, a menu or a fade (Esc is the
// game's there)
exec function cj_play_esc() {
    if (theGame.IsDialogOrCutscenePlaying() || theGame.GetGuiManager().IsAnyMenu() || theGame.IsBlackscreenOrFading()) {
        return;
    }
    CjOut("esc|edit");
}

// a fresh session from a game definition (docs/VANILLA_EDITING_PLAN.md, step 4): no save loaded - the game's own
// new game, with another definition (its worlds, starting point, main quest: CDPR's review starts, or one of ours)
// the facts the next editor session starts with: the story's state at the point jumped to. The game object lives on
// from session to session; the session's main quest (conjunction\sessions\jump.w2quest) sets them at its start
// (CjSessionFacts) - the game's initial facts (AddInitialFact) did not come over into a session asked for in game
@addField(CR4Game)
var w3sSessionFacts : array< string >;

@addMethod(CR4Game)
function CjSessionFactAdd(fact : string) {
    w3sSessionFacts.PushBack(fact);
}

@addMethod(CR4Game)
function CjSessionFactsTake() : array< string > {
    var taken : array< string >;
    taken = w3sSessionFacts;
    w3sSessionFacts.Clear();
    return taken;
}

exec function cj_session_fact(fact : string) {
    theGame.CjSessionFactAdd(fact);
}

exec function cj_session_clear() {
    theGame.CjSessionFactsTake();
}

quest function CjSessionFacts() {
    var facts : array< string >;
    var i : int;
    facts = theGame.CjSessionFactsTake();
    for (i = 0; i < facts.Size(); i += 1) {
        FactsAdd(facts[i], 1);
    }
    CjOut("session_facts|" + IntToString(facts.Size()));
}

exec function cj_fact_add(fact : string, value : int) {
    FactsAdd(fact, value);
}

exec function cj_new_session(definition : string) {
    if (theGame.RequestNewGame(definition)) {
        CjOut("session|" + definition);
    } else {
        CjOut("session_failed|" + definition);
    }
}

// a session of a project (sessions.start_project): no save while it runs - autosaves, quick saves and the menu's
// Save all locked (the player's saves are never touched by Conjunction, MaximdeWinter 14.11.); the lock ends with the session
@addField(CR4Game)
var cjSessionLock : int;

@addField(CR4Game)
var cjSessionLocked : bool;

// (ReleaseNoSaveLockByName faulted, 14.11.: the lock's number kept instead; not unique - unique hands out no
// number when one of that name is there)
@addMethod(CR4Game)
function CjSessionLock(on : bool) {
    if (cjSessionLocked) {
        ReleaseNoSaveLock(cjSessionLock);
        cjSessionLocked = false;
    }
    if (on) {
        CreateNoSaveLock("conjunction_session", cjSessionLock, false, false);
        cjSessionLocked = true;
    }
}

exec function cj_session_nosave() {
    theGame.CjSessionLock(true);
    CjOut("session|nosave");
}

exec function cj_session_lock(on : bool) {
    theGame.CjSessionLock(on);
    CjOut("session|lock");
}

// tests: may the game save right now (any lock: a session's, a fight, a scene)?
exec function cj_saves_locked() {
    if (theGame.AreSavesLocked()) {
        CjOut("saves|locked");
    } else {
        CjOut("saves|free");
    }
}

// Build & Play in a session: the session's own save for the reload (a manual save of its own, not the player's
// quick save; play.lua deletes it once loaded) - the lock off for it, set again when the save has loaded
exec function cj_session_save() {
    theGame.CjSessionLock(false);
    if (theGame.AreSavesLocked()) {
        CjOut("save|locked");
        return;
    }
    theGame.SaveGame(SGT_Manual, -1);
    CjOut("save|requested");
}

// the game's own menu (save, load, settings) from the editor
exec function cj_game_menu() {
    FactsRemove("nge_pause_menu_disabled");
    theGame.SetMenuToOpen('');
    theGame.RequestMenu('CommonIngameMenu');
}

exec function cj_edit(on : bool) {
    var ed : CjEditor;
    ed = theGame.CjEditorGet();
    if (on && !ed.on) {
        theInput.StoreContext('EMPTY_CONTEXT');
        thePlayer.BlockAllActions('conjunction_editor', true);   // clicks never reach Geralt (attacks, signs)
        theGame.ShowHardwareCursor();
        CjHud(false);
        ed.on = true;
        ed.selected = NULL;
        CjBackHome();
        CjPreview(ed.placing);
        thePlayer.CjFlyStart();
        if (ed.light > 0) {
            CjLight(ed.light);
        }
        CjLamp(ed.lampOn);
        CjOut("edit on world=" + theGame.GetWorld().GetDepotPath() + " template=" + ed.template);
    } else if (on && ed.on) {
        theGame.ShowHardwareCursor();       // already on: the cursor again (06.10.: gone after other windows had the focus)
    } else if (!on && ed.on) {
        CjPreview(false);
        CjGhostDue(true);
        ed.selected = NULL;
        thePlayer.CjFlyStop();
        if (ed.light > 0) {
            CjLight(0);
        }
        CjLamp(false);
        FactsRemove("nge_pause_menu_disabled");     // the pause menu works again (conjunction_cam.ws CjFlyTick)
        CjMusic(false);
        CjHud(true);
        theGame.HideHardwareCursor();
        thePlayer.BlockAllActions('conjunction_editor', false);
        theInput.RestoreContext('EMPTY_CONTEXT', true);
        ed.on = false;
        CjOut("edit off placed=" + IntToString(ed.placed.Size()));
    }
}

exec function cj_mode(placing : bool) {
    var ed : CjEditor;
    ed = theGame.CjEditorGet();
    ed.placing = placing;
    ed.selected = NULL;
    if (ed.on) {
        CjPreview(placing);
    }
    CjOut("mode placing=" + CjYesNo(placing));
}

exec function cj_music(off : bool) {
    CjMusic(off);
}

exec function cj_set_place(place : string) {
    var ed : CjEditor;
    ed = theGame.CjEditorGet();
    ed.place = place;
    CjOut("place=" + place);
}

function CjSetTemplate(template : string) {
    var ed : CjEditor;
    ed = theGame.CjEditorGet();
    ed.template = template;
    if (ed.on && ed.placing) {
        CjPreview(true);
    }
    CjOut("template=" + template);
}

exec function cj_set_template(template : string) {
    CjSetTemplate(template);
}

// a person's look chosen in the app: the preview wears it, each one placed takes it from the preview. None again:
// the preview made anew (the game picks its look)
function CjSetLook(look : string) {
    var ed : CjEditor;
    ed = theGame.CjEditorGet();
    if (look == ed.look) {
        return;
    }
    ed.look = look;
    if (ed.preview && look != "") {
        ed.preview.ApplyAppearance(look);
    } else if (ed.preview && ed.on && ed.placing) {
        CjPreview(true);
    }
    CjOut("look=" + look);
}

exec function cj_set_look(look : string) {
    CjSetLook(look);
}

exec function cj_clear_look() {
    CjSetLook("");
}

// nothing to place: the game's command line cannot pass an empty string ("" fails the whole call, measured 04.10.)
exec function cj_clear_template() {
    CjSetTemplate("");
}

// placing options from the editor's bar
exec function cj_place_opts(grid : float, align : bool, randomYaw : bool) {
    var ed : CjEditor;
    ed = theGame.CjEditorGet();
    ed.grid = grid;
    ed.align = align;
    ed.randomYaw = randomYaw;
    CjOut("placeopts|grid=" + FloatToString(grid) + "|align=" + CjYesNo(align) + "|random="
        + CjYesNo(randomYaw));
}

// the first surface along the ray through the cursor, with its normal
function CjTraceNormal(sx : float, sy : float, aspect : float, out hit : Vector, out normal : Vector) : bool {
    var origin, dir, to, start : Vector;
    var material : name;
    var comp : CComponent;
    var ent : CEntity;
    var ed : CjEditor;
    var i : int;
    ed = theGame.CjEditorGet();
    CjRay(sx, sy, aspect, origin, dir);
    to = origin + dir * 400;
    start = origin;
    for (i = 0; i < 6; i += 1) {
        if (!theGame.GetWorld().StaticTraceWithAdditionalInfo(start, to, hit, normal, material, comp)) {
            return false;
        }
        ent = NULL;
        if (comp) {
            ent = comp.GetEntity();
        }
        if (!ent || ent != ed.preview) {
            return true;
        }
        start = hit + dir * 0.05;
    }
    return false;
}

// a turn (yaw) tilted so that the object's up follows the surface normal
function CjAligned(yaw : float, n : Vector) : EulerAngles {
    var m : Matrix;
    var f, r, u : Vector;
    u = VecNormalize(n);
    f = MatrixGetAxisY(MatrixBuiltRotation(EulerAngles(0, yaw, 0)));
    f = VecNormalize(f - u * VecDot(f, u));
    r = VecCross(f, u);
    m.X = r;
    m.Y = f;
    m.Z = u;
    m.W = Vector(0, 0, 0, 1);
    return MatrixGetRotation(m);
}

exec function cj_pick(sx : float, sy : float, aspect : float) {
    var ed : CjEditor;
    var hit, normal, down, pos : Vector;
    var ent : CEntity;
    var rot : EulerAngles;
    ed = theGame.CjEditorGet();
    if (!ed.on || (!ed.preview && !(ed.placing && ed.plantRes))) {
        return;
    }
    if (CjTraceNormal(sx, sy, aspect, hit, normal)) {
        pos = hit;
        if (ed.grid > 0) {
            // on the grid, then down onto whatever is there
            pos.X = RoundF(hit.X / ed.grid) * ed.grid;
            pos.Y = RoundF(hit.Y / ed.grid) * ed.grid;
            if (CjTraceLine(Vector(pos.X, pos.Y, hit.Z + 2), Vector(pos.X, pos.Y, hit.Z - 5), ed.preview, NULL, down,
                             ent)) {
                pos.Z = down.Z;
            }
        }
        rot = ed.userRot;
        if (ed.align) {
            rot = CjAligned(ed.userRot.Yaw, normal);
        }
        if (ed.preview) {
            CjPut(ed.preview, pos, rot);
        } else {
            CjGhostTo(pos, rot);
        }
    }
}

// the selected object down onto what is below it (itself excluded)
exec function cj_drop_selected() {
    var ed : CjEditor;
    var p : Vector;
    var gz : float;
    ed = theGame.CjEditorGet();
    if (!ed.on || !ed.selected) {
        return;
    }
    p = ed.selected.GetWorldPosition();
    // the highest surface below it, objects and the ground (CjSurfaceBelow), from 1.5 m above its foot
    if (CjSurfaceBelow(p, 1.5, ed.selected, ed.preview, gz)) {
        // (W = 1: a position with W 0 was not moved to - Drop did nothing, 06.10.)
        CjPutAndReport(ed.selected, Vector(p.X, p.Y, gz, 1), ed.selected.GetWorldRotation());
        CjReport("moved", ed.selected, CjTemplateOf(ed.selected), "|from=" + FloatToString(p.X) + ","
            + FloatToString(p.Y) + "," + FloatToString(p.Z));
    } else {
        CjOut("drop|none");
    }
}

// tests: the aligned turn for a surface normal (flat ground must give back the yaw)
exec function cj_align_test(yaw : float, nx : float, ny : float, nz : float) {
    var r : EulerAngles;
    r = CjAligned(yaw, Vector(nx, ny, nz));
    CjOut("align|" + FloatToString(r.Roll) + "," + FloatToString(r.Pitch) + "," + FloatToString(r.Yaw));
}

exec function cj_place() {
    var ed : CjEditor;
    var tpl : CEntityTemplate;
    var e : CEntity;
    var was : CActor;
    var look : string;
    ed = theGame.CjEditorGet();
    if (!ed.on || (!ed.preview && !ed.ghost)) {
        return;
    }
    tpl = (CEntityTemplate)LoadResource(ed.template, true);
    if (!ed.preview) {
        // a plant: the real one is made where the ghost is (it draws its own tree, with its collision). The ghost
        // stays: the two cover each other, and deleting the tree takes both (the engine's remove is by radius)
        ed.pending = false;
        ed.ghost = false;
        ed.planted = true;
        ed.plantedAt = ed.ghostAt;
        e = theGame.CreateEntity(tpl, ed.ghostAt, ed.ghostRot);
    } else {
        e = theGame.CreateEntity(tpl, ed.preview.GetWorldPosition(), ed.preview.GetWorldRotation());
    }
    CjShowClue(e);
    CjCalm(e);
    e.AddTag('cj_placed');
    CjAddPlaced(e, ed.template, e.GetWorldPosition(), e.GetWorldRotation());
    // a person looks as the preview did (each picks a look at random when it is made) - and the quest keeps it
    look = "";
    was = (CActor)ed.preview;
    if (was && (CActor)e) {
        look = NameToString(was.GetAppearance());
        if (look != "") {
            e.ApplyAppearance(look);
        }
    }
    CjReport("placed", e, ed.template, "|appearance=" + look);
    if (ed.randomYaw) {
        // the next one is turned differently (clutter should not look copied)
        ed.userRot.Yaw = RandRangeF(360);
        if (ed.preview) {
            CjPut(ed.preview, ed.preview.GetWorldPosition(), ed.userRot);
        }
    }
}

// axis 0 = yaw (around up), 1 = pitch, 2 = roll: turns the preview (place mode) or the selected object
exec function cj_rotate(deg : float, axis : int) {
    var ed : CjEditor;
    var e : CEntity;
    var rot : EulerAngles;
    ed = theGame.CjEditorGet();
    if (!ed.on) {
        return;
    }
    e = ed.preview;
    if (!ed.placing) {
        e = ed.selected;
    }
    if (!e && ed.placing && ed.ghost) {         // a plant's ghost: the user's turn, drawn anew
        if (axis == 0) {
            ed.userRot.Yaw = AngleNormalize(ed.userRot.Yaw + deg);
        }
        CjGhostTo(ed.ghostAt, EulerAngles(0, ed.userRot.Yaw, 0));
        return;
    }
    if (!e) {
        return;
    }
    rot = e.GetWorldRotation();
    if (e == ed.preview) {
        rot = ed.userRot;                   // the user's turn (aligning adds the tilt at the next pick)
    }
    if (axis == 1) {
        rot.Pitch = AngleNormalize180(rot.Pitch + deg);
    } else if (axis == 2) {
        rot.Roll = AngleNormalize180(rot.Roll + deg);
    } else {
        rot.Yaw = AngleNormalize(rot.Yaw + deg);
    }
    if (e == ed.preview) {
        ed.userRot = rot;
        if (ed.align) {
            rot = CjAligned(rot.Yaw, MatrixGetAxisZ(MatrixBuiltRotation(e.GetWorldRotation())));
        }
    }
    if (e == ed.selected) {
        e = CjPutAndReport(e, e.GetWorldPosition(), rot);
        CjReport("rotated", e, CjTemplateOf(e));
    } else {
        CjPut(e, e.GetWorldPosition(), rot);
    }
}

exec function cj_select(sx : float, sy : float, aspect : float) {
    var ed : CjEditor;
    var hit : Vector;
    var ent : CEntity;
    ed = theGame.CjEditorGet();
    if (!ed.on) {
        return;
    }
    ed.selected = NULL;
    ed.group.Clear();
    CjReportGroup();
    if (CjTrace(sx, sy, aspect, hit, ent) && CjSelectable(ed, ent)) {
        ed.selected = ent;
        CjReport("selected", ent, CjTemplateOf(ent));
    } else {
        CjOut("select|none");
    }
}

// Shift+click: one more into the selection, or out of it again
exec function cj_select_add(sx : float, sy : float, aspect : float) {
    var ed : CjEditor;
    var hit : Vector;
    var ent : CEntity;
    var i : int;
    ed = theGame.CjEditorGet();
    if (!ed.on || !CjTrace(sx, sy, aspect, hit, ent) || !CjSelectable(ed, ent)) {
        return;
    }
    i = ed.group.FindFirst(ent);
    if (i >= 0) {
        ed.group.Erase(i);
    } else if (ent == ed.selected) {
        // the leader leaves: the next one leads
        ed.selected = NULL;
        if (ed.group.Size() > 0) {
            ed.selected = ed.group[0];
            ed.group.Erase(0);
        }
    } else if (!ed.selected) {
        ed.selected = ent;
    } else {
        ed.group.PushBack(ent);
    }
    CjReportGroup();
    if (ed.selected) {
        CjReport("selected", ed.selected, CjTemplateOf(ed.selected));
    } else {
        CjOut("select|none");
    }
}

// move the selected object to (x, y, z). collide: it stays on surfaces - dropped onto the first thing below the
// target (itself excluded), never below it; snap: always on what is below (Snap to ground); without: exactly there,
// through anything. The search starts above the object as it is and the target (06.10.: from 2 m above the target
// only, a target pulled into the ground started it under the ground - the ground did not count)
exec function cj_move_to(x : float, y : float, z : float, collide : bool, snap : bool) {
    var ed : CjEditor;
    var target, delta, cur, from, to, hit, dir : Vector;
    var ent : CEntity;
    var gz, now : float;
    var i : int;
    var vertical : bool;
    ed = theGame.CjEditorGet();
    if (!ed.on || !ed.selected) {
        return;
    }
    target = Vector(x, y, z, 1);
    cur = ed.selected.GetWorldPosition();
    // collision: what is in the way stops it (06.10.: it climbed over the obstacle - MaximdeWinter: no way round)
    if (collide) {
        from = cur + Vector(0, 0, 0.3);
        to = target + Vector(0, 0, 0.3);
        from.W = 1;
        to.W = 1;
        if (VecDistance(from, to) > 0.001 && CjTraceLine(from, to, ed.selected, ed.preview, hit, ent)) {
            dir = VecNormalize(to - from);
            target = hit - dir * 0.05 - Vector(0, 0, 0.3);
            target.W = 1;
        }
    }
    // (straight up or down - the height's arrow - it only stops at what is below: within 30 cm of the ground it was
    // pulled back down, MaximdeWinter 24.10.: after Drop it could never be lifted again)
    vertical = AbsF(target.X - cur.X) < 0.005 && AbsF(target.Y - cur.Y) < 0.005;
    if ((collide || snap) && CjSurfaceBelow(target, MaxF(cur.Z - target.Z, 0) + 1.5, ed.selected, ed.preview, gz)) {
        if (snap || target.Z < gz || (!vertical && target.Z - gz < 0.3)) {
            target.Z = gz;
        }
    }
    // the app draws the outline and the arrows where it really is (snapped down a slope, stopped at a wall) -
    // told at most ten times a second (a line every frame made it lag)
    now = EngineTimeToFloat(theGame.GetEngineTime());
    if ((collide || snap) && now - ed.movingSaid > 0.1) {
        ed.movingSaid = now;
        CjOut("moving|" + FloatToString(target.X) + "," + FloatToString(target.Y) + "," + FloatToString(target.Z));
    }
    // the group keeps its shape: the others go the same way
    delta = target - ed.selected.GetWorldPosition();
    CjPut(ed.selected, target, ed.selected.GetWorldRotation());
    CjGroupFollow(delta, collide, snap);
}

// the rest of the selection moved by delta; with collision (or snap) none goes below what is under it - each on its
// own (MaximdeWinter 24.10.: the first one lowered, one beside it standing lower went into the ground)
function CjGroupFollow(delta : Vector, collide : bool, snap : bool) {
    var ed : CjEditor;
    var p : Vector;
    var gz : float;
    var i : int;
    ed = theGame.CjEditorGet();
    for (i = 0; i < ed.group.Size(); i += 1) {
        if (ed.group[i]) {
            p = ed.group[i].GetWorldPosition() + delta;
            p.W = 1;
            if ((collide || snap) && CjSurfaceBelow(p, MaxF(-delta.Z, 0) + 1.5, ed.group[i], ed.preview, gz)
                    && (snap || p.Z < gz)) {
                p.Z = gz;
            }
            CjPut(ed.group[i], p, ed.group[i].GetWorldRotation());
        }
    }
}

// the middle handle of the gizmo: the selection follows the cursor over the surfaces (itself and its group are not
// what it lands on), on the grid if there is one; the app sends this whenever the cursor moves while it is held
exec function cj_move_free(sx : float, sy : float, aspect : float) {
    var ed : CjEditor;
    var origin, dir, to, start, hit, normal, delta, back : Vector;
    var material : name;
    var comp : CComponent;
    var ent, backEnt : CEntity;
    var i : int;
    var found : bool;
    ed = theGame.CjEditorGet();
    if (!ed.on || !ed.selected) {
        return;
    }
    CjRay(sx, sy, aspect, origin, dir);
    to = origin + dir * 400;
    start = origin;
    // (23.10.: in 5 cm steps the ray went on through the object itself to the ground far behind it - at a flat
    // view it jumped 10 to 17 m back and forth every frame; now from where it leaves the object's box)
    for (i = 0; i < 30 && !found; i += 1) {
        if (!theGame.GetWorld().StaticTraceWithAdditionalInfo(start, to, hit, normal, material, comp)) {
            return;
        }
        ent = NULL;
        if (comp) {
            ent = comp.GetEntity();
        }
        if (!ent || (ent != ed.selected && ent != ed.preview && ed.group.FindFirst(ent) < 0)) {
            found = true;
        } else if (CjSkip(ent, hit, dir, start, back, backEnt) && backEnt != ed.selected && backEnt != ed.preview
                   && ed.group.FindFirst(backEnt) < 0) {
            hit = back;
            found = true;
        }
    }
    if (!found) {
        return;
    }
    if (ed.grid > 0) {
        hit.X = RoundF(hit.X / ed.grid) * ed.grid;
        hit.Y = RoundF(hit.Y / ed.grid) * ed.grid;
    }
    hit.W = 1;
    delta = hit - ed.selected.GetWorldPosition();
    CjPut(ed.selected, hit, ed.selected.GetWorldRotation());
    CjGroupFollow(delta, true, false);           // (dragged over the surfaces: the others stay on them too)
    // nothing logged here: a log line every frame made it lag (cj_move_done reports where it ends)
}

// end of a drag: report where it came from, so the app can find it in the project (the group: moved as far)
exec function cj_move_done(fx : float, fy : float, fz : float) {
    var ed : CjEditor;
    var delta, p : Vector;
    var i : int;
    ed = theGame.CjEditorGet();
    if (ed.on && ed.selected) {
        delta = ed.selected.GetWorldPosition() - Vector(fx, fy, fz, 1);
        for (i = 0; i < ed.group.Size(); i += 1) {
            if (ed.group[i]) {
                p = ed.group[i].GetWorldPosition() - delta;
                CjReport("moved", ed.group[i], CjTemplateOf(ed.group[i]), "|from=" + FloatToString(p.X) + ","
                    + FloatToString(p.Y) + "," + FloatToString(p.Z));
            }
        }
        CjReport("moved", ed.selected, CjTemplateOf(ed.selected), "|from=" + FloatToString(fx) + ","
            + FloatToString(fy) + "," + FloatToString(fz));
        CjReportGroup();
    }
}

exec function cj_delete_selected() {
    var ed : CjEditor;
    ed = theGame.CjEditorGet();
    if (ed.on) {
        CjDeleteSelected();
    }
}

exec function cj_delete(sx : float, sy : float, aspect : float) {
    var ed : CjEditor;
    var hit : Vector;
    var ent : CEntity;
    ed = theGame.CjEditorGet();
    if (!ed.on) {
        return;
    }
    if (CjTrace(sx, sy, aspect, hit, ent) && CjSelectable(ed, ent)) {
        ed.selected = ent;
        CjDeleteSelected();
    } else {
        CjOut("delete: nothing there");
    }
}

// loading a place for editing: the baked layer of the place goes (cj_layer), its objects come back as copies that
// can be selected, moved, deleted (cj_spawn). cj_clear first: the project file is the truth, not what stands.
exec function cj_clear() {
    var ed : CjEditor;
    var i : int;
    ed = theGame.CjEditorGet();
    for (i = 0; i < ed.placed.Size(); i += 1) {
        if (ed.placed[i]) {
            CjDestroy(ed.placed[i]);
        }
    }
    ed.placed.Clear();
    ed.templates.Clear();
    ed.homes.Clear();
    ed.homeRots.Clear();
    ed.looks.Clear();
    ed.renew.Clear();
    ed.renewAt.Clear();
    ed.selected = NULL;
    ed.group.Clear();
    CjOut("cleared");
}

// (exec functions cannot be called from scripts - so the work is here, the exec only forwards)
// a clue of the game (a corpse, blood, tracks) is dark until a quest switches it on - in the editor it must show
// (MaximdeWinter 01.10.: "Go to" the corpse, nothing there)
function CjShowClue(e : CEntity) {
    var clue : W3MonsterClue;
    clue = (W3MonsterClue)e;
    if (clue) {
        clue.SetAttributes(FCAA_ForceSet, true, false, false, true, false, false);
    }
}

function CjSpawn(template : string, x : float, y : float, z : float, roll : float, pitch : float, yaw : float)
    : CEntity {
    var ed : CjEditor;
    var tpl : CEntityTemplate;
    var e : CEntity;
    var rot : EulerAngles;
    ed = theGame.CjEditorGet();
    tpl = (CEntityTemplate)LoadResource(template, true);
    if (!tpl) {
        CjOut("spawn|missing|" + template);
        return NULL;
    }
    rot.Roll = roll;
    rot.Pitch = pitch;
    rot.Yaw = yaw;
    e = theGame.CreateEntity(tpl, Vector(x, y, z, 1), rot);
    CjCalm(e);
    CjShowClue(e);
    e.AddTag('cj_placed');
    CjAddPlaced(e, template, Vector(x, y, z, 1), rot);
    return e;
}

exec function cj_spawn(template : string, x : float, y : float, z : float, roll : float, pitch : float, yaw : float) {
    CjSpawn(template, x, y, z, roll, pitch, yaw);
}

exec function cj_layer(group : string, show : bool) {
    if (show) {
        theGame.GetWorld().ShowLayerGroup(group);
    } else {
        theGame.GetWorld().HideLayerGroup(group);
    }
    CjOut("layer|" + group + "|" + CjYesNo(show));
}

// the player off his horse at once, before the editor moves him: a teleport takes him from the saddle and leaves him
// in the riding animation (05.11.) - dismounted as the game does when a horse is hidden under its rider
function CjOffHorse() {
    var horse : W3HorseComponent;
    if (thePlayer.IsUsingHorse(true)) {
        horse = thePlayer.GetUsedHorseComponent();
        if (horse) {
            horse.IssueCommandToDismount(DT_instant);
        }
    }
}

// try it out: Geralt onto the ground below the editor camera (the editor stays on; F8 hands him over)
exec function cj_player_here() {
    var hit, from : Vector;
    var ent : CEntity;
    if (!thePlayer.w3sFlyOn) {
        return;
    }
    from = thePlayer.w3sFlyPos;
    if (CjTraceLine(from, from - Vector(0, 0, 200), theGame.CjEditorGet().preview, NULL, hit, ent)) {
        CjOffHorse();
        thePlayer.Teleport(hit);
        thePlayer.CjFlySetHome(hit);               // closing the editor leaves him here
        CjOut("player|" + FloatToString(hit.X) + "," + FloatToString(hit.Y) + "," + FloatToString(hit.Z));
    } else {
        CjOut("player|no ground");
    }
}

exec function cj_fov(vertical : bool) {
    var ed : CjEditor;
    ed = theGame.CjEditorGet();
    ed.fovVertical = vertical;
}


// --- by position (undo, the properties panel): the app knows objects by where they stand
function CjFindPlaced(x : float, y : float, z : float) : CEntity {
    var ed : CjEditor;
    var i, best : int;
    var d, bestD : float;
    ed = theGame.CjEditorGet();
    best = -1;
    // the nearest within 1.5 m: a creature settles after it was placed (ground, pose) and is not where it was
    bestD = 1.5 * 1.5;
    for (i = 0; i < ed.placed.Size(); i += 1) {
        if (ed.placed[i]) {
            d = VecDistanceSquared(ed.placed[i].GetWorldPosition(), Vector(x, y, z, 1));
            if (d <= bestD) {
                best = i;
                bestD = d;
            }
        }
    }
    if (best < 0) {
        // not one of ours: the selected object the game placed (edit existing), if it is the one meant
        if (ed.selected && VecDistanceSquared(ed.selected.GetWorldPosition(), Vector(x, y, z, 1)) <= 1.5 * 1.5) {
            return ed.selected;
        }
        return NULL;
    }
    return ed.placed[best];
}

exec function cj_select_at(x : float, y : float, z : float) {
    var ed : CjEditor;
    var e : CEntity;
    ed = theGame.CjEditorGet();
    e = CjFindPlaced(x, y, z);
    ed.selected = e;
    if (e) {
        CjReport("selected", e, CjTemplateOf(e));
    } else {
        CjOut("select|none");
    }
}

// exact transform of the object at (x, y, z): reported as moved (from = where it was)
exec function cj_set_at(x : float, y : float, z : float, nx : float, ny : float, nz : float, roll : float,
                         pitch : float, yaw : float) {
    var e : CEntity;
    var rot : EulerAngles;
    e = CjFindPlaced(x, y, z);
    if (!e) {
        CjOut("set_at|none");
        return;
    }
    rot.Roll = roll;
    rot.Pitch = pitch;
    rot.Yaw = yaw;
    e = CjPutAndReport(e, Vector(nx, ny, nz, 1), rot);
    CjReport("moved", e, CjTemplateOf(e), "|from=" + FloatToString(x) + "," + FloatToString(y) + ","
        + FloatToString(z));
}

exec function cj_delete_at(x : float, y : float, z : float) {
    var ed : CjEditor;
    ed = theGame.CjEditorGet();
    ed.selected = CjFindPlaced(x, y, z);
    if (ed.selected) {
        CjDeleteSelected();
    } else {
        CjOut("delete_at|none");
    }
}

// place exactly (undo of a delete): like a click, reported as placed
exec function cj_place_at(template : string, x : float, y : float, z : float, roll : float, pitch : float,
                           yaw : float) {
    var e : CEntity;
    e = CjSpawn(template, x, y, z, roll, pitch, yaw);
    if (e) {
        CjReport("placed", e, template);
    }
}

// one of ours (by where it stands) into the selection's group - lists and tests
exec function cj_group_add_at(x : float, y : float, z : float) {
    var ed : CjEditor;
    var e : CEntity;
    ed = theGame.CjEditorGet();
    e = CjFindPlaced(x, y, z);
    if (e && e != ed.selected && ed.group.FindFirst(e) < 0) {
        ed.group.PushBack(e);
    }
    CjReportGroup();
}

// the point under the cursor (pasting puts the copied objects there): "cursor|x,y,z"
exec function cj_cursor_hit(sx : float, sy : float, aspect : float) {
    var hit, normal : Vector;
    if (CjTraceNormal(sx, sy, aspect, hit, normal)) {
        CjOut("cursor|" + FloatToString(hit.X) + "," + FloatToString(hit.Y) + "," + FloatToString(hit.Z));
    } else {
        CjOut("cursor|none");
    }
}

// while a place is edited, the NPCs its quest spawned step aside (the editor shows its own copies)
// a built person hidden while its copy is edited, as the editor's ghost Geralt is: unseen and without collision
// (23.10.: switching its mesh parts off grew a list without end - the game switches a person's parts on again - and a
// built thing's collision stays anyway; built things go with their layer group, cj_layer)
function CjHideBuilt(e : CEntity, hide : bool) {
    var person : CActor;
    e.SetHideInGame(hide);
    person = (CActor)e;
    if (person) {
        person.EnableCollisions(!hide);
    }
}

exec function cj_hide_tag(tag : name, hide : bool) {
    var ents : array<CEntity>;
    var i : int;
    theGame.GetEntitiesByTag(tag, ents);
    for (i = 0; i < ents.Size(); i += 1) {
        if (!ents[i].HasTag('cj_placed')) {
            CjHideBuilt(ents[i], hide);
        }
    }
    CjOut("hide|" + NameToString(tag) + "|" + IntToString(ents.Size()) + "|" + CjYesNo(hide));
}

// duplicate the selected object (one metre aside); the copy is selected and reported as placed
exec function cj_duplicate() {
    var ed : CjEditor;
    var e, g : CEntity;
    var copies : array<CEntity>;
    var tpl : string;
    var p, offset : Vector;
    var r : EulerAngles;
    var i : int;
    ed = theGame.CjEditorGet();
    if (!ed.on || !ed.selected) {
        return;
    }
    // one metre to the side of the leader; the group is copied the same way and the copies are selected
    offset = VecFromHeading(ed.selected.GetHeading() - 90);
    for (i = 0; i < ed.group.Size(); i += 1) {
        g = ed.group[i];
        if (g) {
            tpl = CjTemplateOf(g);
            p = g.GetWorldPosition() + offset;
            r = g.GetWorldRotation();
            e = CjSpawn(tpl, p.X, p.Y, p.Z, r.Roll, r.Pitch, r.Yaw);
            if (e) {
                CjReport("placed", e, tpl);
                copies.PushBack(e);
            }
        }
    }
    tpl = CjTemplateOf(ed.selected);
    p = ed.selected.GetWorldPosition() + offset;
    r = ed.selected.GetWorldRotation();
    e = CjSpawn(tpl, p.X, p.Y, p.Z, r.Roll, r.Pitch, r.Yaw);
    if (e) {
        CjReport("placed", e, tpl);
        ed.selected = e;
        ed.group = copies;
        CjReportGroup();
        CjReport("selected", e, tpl);
    }
}

// --- the inspector: inventory and appearance of one of ours (found by position, like undo)
function CjInvReport(x : float, y : float, z : float, ge : CGameplayEntity) {
    var inv : CInventoryComponent;
    var items : array<SItemUniqueId>;
    var i : int;
    var line : string;
    line = "invlist|" + FloatToString(x) + "," + FloatToString(y) + "," + FloatToString(z);
    inv = ge.GetInventory();
    if (!inv) {
        CjOut(line + "|none");
        return;
    }
    inv.GetAllItems(items);
    for (i = 0; i < items.Size(); i += 1) {
        line += "|" + NameToString(inv.GetItemName(items[i])) + ":" + IntToString(inv.GetItemQuantity(items[i]));
    }
    CjOut(line);
}

// what is in it now (loot tables fill containers too)
exec function cj_inv_list(x : float, y : float, z : float) {
    var ge : CGameplayEntity;
    ge = (CGameplayEntity)CjFindPlaced(x, y, z);
    if (ge) {
        CjInvReport(x, y, z, ge);
    } else {
        CjOut("invlist|" + FloatToString(x) + "," + FloatToString(y) + "," + FloatToString(z) + "|none");
    }
}

// exactly `count` of an item in it (0 takes it out)
exec function cj_inv_set(x : float, y : float, z : float, item : name, count : int) {
    var ge : CGameplayEntity;
    var inv : CInventoryComponent;
    var have : int;
    ge = (CGameplayEntity)CjFindPlaced(x, y, z);
    if (!ge) {
        return;
    }
    inv = ge.GetInventory();
    if (!inv) {
        return;
    }
    have = inv.GetItemQuantityByName(item);
    if (count > have) {
        inv.AddAnItem(item, count - have, true, true);
    } else if (count < have) {
        inv.RemoveItemByName(item, have - count);
    }
    CjInvReport(x, y, z, ge);
}

// the loot table of a placed container: emptied (clear), filled from the table ('' = none)
exec function cj_loot_set(x : float, y : float, z : float, loot : name, clear : bool) {
    var ge : CGameplayEntity;
    var inv : CInventoryComponent;
    var items : array<SItemUniqueId>;
    var i : int;
    ge = (CGameplayEntity)CjFindPlaced(x, y, z);
    if (!ge) {
        return;
    }
    inv = ge.GetInventory();
    if (!inv) {
        return;
    }
    if (clear) {
        // one by one, as the game's scripts empty a container (RemoveAllItems is the game's for Geralt only)
        inv.GetAllItems(items);
        for (i = items.Size() - 1; i >= 0; i -= 1) {
            inv.RemoveItem(items[i], inv.GetItemQuantity(items[i]));
        }
    }
    // 'cj_none': no loot (the game's command line cannot pass an empty string, measured 04.10.)
    if (loot != '' && loot != 'cj_none') {
        inv.AddItemsFromLootDefinition(loot);
    }
    CjInvReport(x, y, z, ge);
}

exec function cj_appearance(x : float, y : float, z : float, appearance : string) {
    var e : CEntity;
    var ed : CjEditor;
    var i : int;
    ed = theGame.CjEditorGet();
    e = CjFindPlaced(x, y, z);
    if (e) {
        e.ApplyAppearance(appearance);
        i = ed.placed.FindFirst(e);
        while (i >= 0 && ed.looks.Size() <= i) {
            ed.looks.PushBack("");
        }
        if (i >= 0) {
            ed.looks[i] = appearance;   // (made anew: CjRenew gives it again)
        }
        CjOut("appearance|" + appearance);
    }
}

// the witcher senses while editing (V): clues and usable things highlighted, as the player sees them
exec function cj_senses(on : bool) {
    var fm : CFocusModeController;
    fm = theGame.GetFocusModeController();
    if (fm) {
        fm.SetActive(on);
        fm.EnableVisuals(on);
        fm.EnableExtendedVisuals(on, 0.5);
    }
    CjOut("senses|" + CjYesNo(on));
}
