// conjunction: link - the app sends commands through the script extender (TW3SE, its pipe's exec), and everything the
// game reports goes back as one line through CjOut (TW3SE_Emit, read by the pipe's events). No -debugscripts.
import function TW3SE_Emit(text : string);
import function TW3SE_EntityGuid(e : CEntity) : string;
import function TW3SE_EntityEffects(e : CEntity) : string;
import function TW3SE_EntityTemplate(e : CEntity) : CEntityTemplate;
import function TW3SE_HideEntity(e : CEntity, hide : bool) : bool;
import function TW3SE_EntityByGuid(guid : string) : CEntity;
import function TW3SE_FoliagePlant(tree : CResource, x : float, y : float, z : float, yaw : float, scale : float,
                                   half : float, height : float) : bool;
import function TW3SE_FoliageRemoveAt(tree : CResource, x : float, y : float, z : float, radius : float) : bool;

// what an object the game placed can play and switch to (its template's effects and appearances): the world card
function CjWorldInfo(e : CEntity) {
    var names : array<name>;
    var tmpl : CEntityTemplate;
    var looks : string;
    var i : int;
    tmpl = TW3SE_EntityTemplate(e);
    looks = "";
    if (tmpl) {
        GetAppearanceNames(tmpl, names);
        for (i = 0; i < names.Size(); i += 1) {
            if (i > 0) {
                looks += ",";
            }
            looks += NameToString(names[i]);
        }
    }
    CjOut("worldinfo|fx=" + TW3SE_EntityEffects(e) + "|looks=" + looks);
}

function CjOut(text : string) {
    TW3SE_Emit(text);
}

exec function cj_ping(n : int) {
    CjOut("ping " + IntToString(n));
}

exec function cj_where() {
    var p, c, d : Vector;
    p = thePlayer.GetWorldPosition();
    c = theCamera.GetCameraPosition();
    d = theCamera.GetCameraDirection();
    CjOut("where world=" + theGame.GetWorld().GetDepotPath() + " player=" + VecToString(p)
        + " cam=" + VecToString(c) + " dir=" + VecToString(d) + " heading=" + FloatToString(thePlayer.GetHeading()));
}

// does something stand at (x, y)? a ray from high above straight down, the first hit is reported
exec function cj_probe(x : float, y : float, z : float) {
    var hit, normal : Vector;
    var material : name;
    var comp : CComponent;
    var ent : CEntity;
    var what : string;
    if (theGame.GetWorld().StaticTraceWithAdditionalInfo(Vector(x, y, z + 5), Vector(x, y, z - 5), hit, normal, material, comp)) {
        what = "?";
        if (comp) {
            ent = comp.GetEntity();
            if (ent) {
                what = ent.GetReadableName();
            }
        }
        CjOut("probe " + FloatToString(x) + "," + FloatToString(y) + " top=" + FloatToString(hit.Z) + " " + what);
    } else {
        CjOut("probe " + FloatToString(x) + "," + FloatToString(y) + " nothing");
    }
}

// quest checks for tests: the tracked quest and its objectives (status 0 inactive, 1 active, 2 success, 3 failed)
exec function cj_quest() {
    var jm : CWitcherJournalManager;
    var q : CJournalQuest;
    var objs : array<SJournalQuestObjectiveData>;
    var i : int;
    jm = theGame.GetJournalManager();
    q = jm.GetTrackedQuest();
    if (!q) {
        CjOut("quest|none tracked");
        return;
    }
    CjOut("quest|" + GetLocStringById(q.GetTitleStringId()) + "|status=" + IntToString((int)jm.GetEntryStatus(q)));
    jm.GetTrackedQuestObjectivesData(objs);
    for (i = 0; i < objs.Size(); i += 1) {
        CjOut("objective|" + GetLocStringById(objs[i].objectiveEntry.GetTitleStringId()) + "|status="
            + IntToString((int)objs[i].status));
    }
}

exec function cj_fact(id : string) {
    CjOut("fact|" + id + "=" + IntToString(FactsQuerySum(id)));
}

// every objective below a quest (phases -> objectives) with its status
function CjLogObjectives(jm : CWitcherJournalManager, c : CJournalContainer) {
    var i : int;
    var child : CJournalBase;
    var obj : CJournalQuestObjective;
    for (i = 0; i < c.GetNumChildren(); i += 1) {
        child = c.GetChild(i);
        obj = (CJournalQuestObjective)child;
        if (obj) {
            CjOut("objective|" + GetLocStringById(obj.GetTitleStringId()) + "|status="
                + IntToString((int)jm.GetEntryStatus(obj)));
        } else if ((CJournalQuestPhase)child) {
            CjLogObjectives(jm, (CJournalContainer)child);
        }
    }
}

// a journal quest's paragraphs (by its baseName): each with its status - what the journal shows is every one not 0
exec function cj_journal_text(base : string) {
    var jm : CWitcherJournalManager;
    var all : array<CJournalBase>;
    var q : CJournalQuest;
    var group : CJournalQuestDescriptionGroup;
    var para : CJournalQuestDescriptionEntry;
    var i, k : int;
    jm = theGame.GetJournalManager();
    jm.GetActivatedOfType('CJournalQuest', all);
    for (i = 0; i < all.Size(); i += 1) {
        q = (CJournalQuest)all[i];
        if (q && q.baseName == base) {
            CjOut("jquest|" + base + "|status=" + IntToString((int)jm.GetEntryStatus(q)));
            for (k = 0; k < q.GetNumChildren(); k += 1) {
                if ((CJournalQuestDescriptionGroup)q.GetChild(k)) {
                    group = (CJournalQuestDescriptionGroup)q.GetChild(k);
                }
            }
        }
    }
    if (!group) {
        CjOut("jtext|" + base + "|none");
        return;
    }
    for (k = 0; k < group.GetNumChildren(); k += 1) {
        para = (CJournalQuestDescriptionEntry)group.GetChild(k);
        CjOut("jtext|" + para.baseName + "|status=" + IntToString((int)jm.GetEntryStatus(para)) + "|"
            + GetLocStringById(para.GetDescriptionStringId()));
    }
}

// a paragraph of a journal quest (by baseNames) set to a status (0 inactive, 1 active) - its status read back
exec function cj_journal_set(base : string, para_name : string, status : int) {
    var jm : CWitcherJournalManager;
    var all : array<CJournalBase>;
    var q : CJournalQuest;
    var group : CJournalQuestDescriptionGroup;
    var para : CJournalBase;
    var i, k : int;
    jm = theGame.GetJournalManager();
    jm.GetActivatedOfType('CJournalQuest', all);
    for (i = 0; i < all.Size(); i += 1) {
        q = (CJournalQuest)all[i];
        if (q && q.baseName == base) {
            for (k = 0; k < q.GetNumChildren(); k += 1) {
                if ((CJournalQuestDescriptionGroup)q.GetChild(k)) {
                    group = (CJournalQuestDescriptionGroup)q.GetChild(k);
                }
            }
        }
    }
    for (k = 0; group && k < group.GetNumChildren(); k += 1) {
        para = group.GetChild(k);
        if (para.baseName == para_name) {
            jm.ActivateEntry(para, (EJournalStatus)status);
            CjOut("jset|" + para_name + "|asked=" + IntToString(status) + "|now=" + IntToString((int)jm.GetEntryStatus(para)));
        }
    }
}

// a paragraph activated as a journal block does it (with its parents or not) - then every paragraph's status
exec function cj_journal_on(base : string, para_name : string, parents : bool) {
    var jm : CWitcherJournalManager;
    var all : array<CJournalBase>;
    var q : CJournalQuest;
    var group : CJournalQuestDescriptionGroup;
    var para : CJournalBase;
    var i, k : int;
    jm = theGame.GetJournalManager();
    jm.GetActivatedOfType('CJournalQuest', all);
    for (i = 0; i < all.Size(); i += 1) {
        q = (CJournalQuest)all[i];
        if (q && q.baseName == base) {
            for (k = 0; k < q.GetNumChildren(); k += 1) {
                if ((CJournalQuestDescriptionGroup)q.GetChild(k)) {
                    group = (CJournalQuestDescriptionGroup)q.GetChild(k);
                }
            }
        }
    }
    for (k = 0; group && k < group.GetNumChildren(); k += 1) {
        para = group.GetChild(k);
        if (para.baseName == para_name) {
            jm.ActivateEntry(para, JS_Active, false, parents);
        }
    }
    for (k = 0; group && k < group.GetNumChildren(); k += 1) {
        para = group.GetChild(k);
        CjOut("jon|" + para.baseName + "|status=" + IntToString((int)jm.GetEntryStatus(para)));
    }
}

// active journal quests whose title contains `filter` (with status and their objectives' status)
exec function cj_quests(filter : string) {
    var jm : CWitcherJournalManager;
    var all : array<CJournalBase>;
    var q : CJournalQuest;
    var i : int;
    var title : string;
    jm = theGame.GetJournalManager();
    jm.GetActivatedOfType('CJournalQuest', all);
    for (i = 0; i < all.Size(); i += 1) {
        q = (CJournalQuest)all[i];
        if (q) {
            title = GetLocStringById(q.GetTitleStringId());
            if (StrFindFirst(StrLower(title), StrLower(filter)) >= 0) {
                CjOut("quest|" + title + "|status=" + IntToString((int)jm.GetEntryStatus(q))
                    + "|tracked=" + CjYesNo(jm.GetTrackedQuest() == q));
                CjLogObjectives(jm, q);
            }
        }
    }
}

// is the game paused? The engine pauses whenever its window is not the active one - with no reason these can see
// (checked 29.09. against every string of the exe) - and opens its pause menu on the focus loss. So the editor never
// takes the focus from it (keyboard.py) and keeps the pause menu off (nge_pause_menu_disabled, conjunction_cam.ws).
exec function cj_pause_info() {
    var reasons : array<string>;
    var i : int;
    var line : string;
    reasons.PushBack("Inactive");
    reasons.PushBack("inactive");
    reasons.PushBack("WindowInactive");
    reasons.PushBack("Viewport");
    reasons.PushBack("ViewportInactive");
    reasons.PushBack("Focus");
    reasons.PushBack("FocusLost");
    reasons.PushBack("Deactivated");
    reasons.PushBack("Minimized");
    reasons.PushBack("Background");
    reasons.PushBack("Activate");
    reasons.PushBack("ActivePause");
    reasons.PushBack("menus");
    reasons.PushBack("Menu");
    reasons.PushBack("System");
    reasons.PushBack("user");
    line = "pause|paused=" + CjYesNo(theGame.IsPaused()) + "|active=" + CjYesNo(theGame.IsActive())
        + "|activelyPaused=" + CjYesNo(theGame.IsActivelyPaused()) + "|reasons=";
    for (i = 0; i < reasons.Size(); i += 1) {
        if (theGame.IsPausedForReason(reasons[i])) {
            line += reasons[i] + ",";
        }
    }
    CjOut(line);
}

// tests: which entities carry a tag, and where
// tests: every entity with a tag and what it is; then an item into the first that has an inventory (the quest's
// setup without the quest)
exec function cj_put_tag(tag : name, item : name) {
    var ents : array<CEntity>;
    var ge : CGameplayEntity;
    var i : int;
    var g : string;
    theGame.GetEntitiesByTag(tag, ents);
    for (i = 0; i < ents.Size(); i += 1) {
        ge = (CGameplayEntity)ents[i];
        g = "n";
        if (ge) {
            g = "y";
        }
        CjOut("put|" + IntToString(i) + " " + ents[i].GetReadableName() + " gameplay=" + g
            + " byTag=" + CjYesNo(theGame.GetEntityByTag(tag) == ents[i]));
    }
    ge = (CGameplayEntity)theGame.GetEntityByTag(tag);
    if (ge && ge.GetInventory()) {
        ge.GetInventory().AddAnItem(item, 1);
        CjOut("put|added " + NameToString(item) + " x" + IntToString(ge.GetInventory().GetItemQuantityByName(item)));
    } else {
        CjOut("put|nothing to put it in");
    }
}

// tests: what an entity with a tag holds (a quest's chest)
exec function cj_inv_tag(tag : name) {
    var ge : CGameplayEntity;
    var items : array<SItemUniqueId>;
    var inv : CInventoryComponent;
    var i : int;
    var s : string;
    ge = (CGameplayEntity)theGame.GetEntityByTag(tag);
    if (!ge || !ge.GetInventory()) {
        CjOut("invtag|" + NameToString(tag) + "|none");
        return;
    }
    inv = ge.GetInventory();
    inv.GetAllItems(items);
    s = "";
    for (i = 0; i < items.Size(); i += 1) {
        s += "|" + NameToString(inv.GetItemName(items[i])) + ":" + IntToString(inv.GetItemQuantity(items[i]));
    }
    CjOut("invtag|" + NameToString(tag) + "|" + IntToString(items.Size()) + s);
}

// tests: every gameplay entity within r metres of a point - its name, its quest tag, how many of its drawables draw
// (a person hidden by cj_hide_tag draws none) and whether it is one of the editor's copies
exec function cj_near(x : float, y : float, z : float, r : float) {
    var ents : array<CGameplayEntity>;
    var comps : array<CComponent>;
    var tags : array<name>;
    var d : CDrawableComponent;
    var i, j, shown : int;
    var line : string;
    FindGameplayEntitiesInSphere(ents, Vector(x, y, z), r, 300);
    CjOut("near|" + IntToString(ents.Size()));
    for (i = 0; i < ents.Size(); i += 1) {
        comps.Clear();                                  // (the call appends to what the array holds)
        comps = ents[i].GetComponentsByClassName('CDrawableComponent');
        shown = 0;
        for (j = 0; j < comps.Size(); j += 1) {
            d = (CDrawableComponent)comps[j];
            if (d && d.IsVisible()) {
                shown += 1;
            }
        }
        line = "nearent|" + ents[i].GetReadableName() + "|" + VecToString(ents[i].GetWorldPosition()) + "|drawn="
            + IntToString(shown) + "/" + IntToString(comps.Size()) + "|placed=" + CjYesNo(ents[i].HasTag('cj_placed'))
            + "|actor=" + CjYesNo((CActor)ents[i]) + "|tags=";
        tags.Clear();
        tags = ents[i].GetTags();
        for (j = 0; j < tags.Size(); j += 1) {
            line += NameToString(tags[j]) + ",";
        }
        CjOut(line);
    }
}

exec function cj_find(tag : name) {
    var ents : array<CEntity>;
    var i : int;
    theGame.GetEntitiesByTag(tag, ents);
    CjOut("find|" + NameToString(tag) + "|" + IntToString(ents.Size()));
    for (i = 0; i < ents.Size(); i += 1) {
        CjOut("found|" + ents[i].GetReadableName() + "|" + VecToString(ents[i].GetWorldPosition())
            + "|" + FloatToString(ents[i].GetHeading()));
    }
}

// tests: put Geralt somewhere (looking along yaw)
exec function cj_teleport(x : float, y : float, z : float, yaw : float) {
    var pos, safe : Vector;
    var gz : float;
    pos = Vector(x, y, z, 1);
    // on the ground: the navmesh's height there (a caller's z can be metres off - 02.10. the player ended in a wall)
    if (theGame.GetWorld().NavigationComputeZ(pos, z - 30, z + 30, gz)) {
        pos.Z = gz;
    }
    // in a wall, a bush, a house: the nearest free spot on the navmesh
    if (!thePlayer.GetMovingAgentComponent().IsPositionValid(pos)
            && theGame.GetWorld().NavigationFindSafeSpot(pos, 0.5, 8.0, safe)) {
        pos = safe;
    }
    pos.W = 1;
    thePlayer.TeleportWithRotation(pos, EulerAngles(0, yaw, 0));
    CjOut("teleport|" + VecToString(pos));
}

// tests (Maxim 02.10.: "tell Geralt: go to this point, and he goes"): the player walks (or runs) there on the
// navmesh the way an NPC does, around houses and fences; cj_player_go_state says how far he is
// (a state of the player's own, as the game's ApproachInteractionState: in exploration his moves come from the pad,
// an ActionMoveToAsync there does nothing - 02.10. measured)
state CjGo in W3PlayerWitcher extends ExtendedMovable {
    var target : Vector;
    var run : bool;

    event OnEnterState(prevStateName : name) {
        super.OnEnterState(prevStateName);
        Go();
    }

    entry function Go() {
        var mt : EMoveType;
        var ok : bool;
        var safe : Vector;
        mt = MT_Walk;
        if (run) {
            mt = MT_Run;
        }
        ok = parent.ActionMoveTo(target, mt, 1.0, 0.6, MFA_EXIT);
        // standing off the navmesh (a rock, a bush: 02.10. no path at all) - onto the nearest free spot, again
        if (!ok && VecDistance2D(parent.GetWorldPosition(), target) > 1.0
                && theGame.GetWorld().NavigationFindSafeSpot(parent.GetWorldPosition(), 0.5, 6.0, safe)) {
            safe.W = 1;
            parent.Teleport(safe);
            Sleep(0.3);
            ok = parent.ActionMoveTo(target, mt, 1.0, 0.6, MFA_EXIT);
        }
        CjOut("player_go_done|ok=" + ok + "|pos=" + VecToString(parent.GetWorldPosition()));
        parent.PopState(true);
    }
}

exec function cj_player_go(x : float, y : float, z : float, optional run : bool) {
    var pos : Vector;
    var gz : float;
    var st : W3PlayerWitcherStateCjGo;
    pos = Vector(x, y, z, 1);
    if (theGame.GetWorld().NavigationComputeZ(pos, z - 30, z + 30, gz)) {
        pos.Z = gz;
    }
    st = (W3PlayerWitcherStateCjGo)thePlayer.GetState('CjGo');
    if (!st) {
        CjOut("player_go|no state");
        return;
    }
    st.target = pos;
    st.run = run;
    thePlayer.GotoState('CjGo');
    CjOut("player_go|to=" + VecToString(pos) + "|state=" + thePlayer.GetCurrentStateName());
}

exec function cj_player_go_state() {
    CjOut("player_go_state|pos=" + VecToString(thePlayer.GetWorldPosition()) + "|moving="
        + thePlayer.IsMoving() + "|action=" + (int)thePlayer.GetCurrentActionType() + "|state="
        + thePlayer.GetCurrentStateName());
}

exec function cj_player_stop() {
    thePlayer.ActionCancelAll();
    CjOut("player_stop");
}

// tests: kill every actor with a tag the way a fight would (the death sets actor_<tag>_was_killed)
exec function cj_kill(tag : name) {
    var ents : array<CEntity>;
    var actor : CActor;
    var i, n : int;
    theGame.GetEntitiesByTag(tag, ents);
    for (i = 0; i < ents.Size(); i += 1) {
        actor = (CActor)ents[i];
        if (actor && actor.IsAlive()) {
            actor.Kill('cj', true, thePlayer);
            n += 1;
        }
    }
    CjOut("kill|" + NameToString(tag) + "|" + IntToString(n));
}

// quick save before the app restarts the game for a build (the quick start loads it again: same place, same state);
// the game logs "[Savegame] OnSaveCompleted ..." when done
exec function cj_quicksave() {
    if (theGame.AreSavesLocked()) {
        CjOut("save|locked");
        return;
    }
    theGame.SaveGame(SGT_QuickSave, -1);
    CjOut("save|requested");
}

// tests: does the generated item table know an item (by its text)?
exec function cj_item_name(s : string) {
    CjOut("itemname|" + s + "=" + NameToString(CjItemName(s)));
}

// tests: the doors around Geralt - do they have their door component, are they enabled, open (open=true: open them)
exec function cj_doors(open : bool) {
    var ents : array<CGameplayEntity>;
    var door : W3NewDoor;
    var cmp : CDoorComponent;
    var i : int;
    var has, interactive : bool;
    FindGameplayEntitiesInRange(ents, thePlayer, 20, 50);
    for (i = 0; i < ents.Size(); i += 1) {
        door = (W3NewDoor)ents[i];
        if (door) {
            cmp = (CDoorComponent)door.GetComponentByClassName('CDoorComponent');
            has = false;
            interactive = false;
            if (cmp) {
                has = true;
                interactive = cmp.IsInteractive();
                if (open) {
                    cmp.Open(false, false);
                }
            }
            CjOut("door|" + door.GetReadableName() + "|" + VecToString(door.GetWorldPosition())
                + "|component=" + CjYesNo(has) + "|enabled=" + CjYesNo(door.IsEnabled())
                + "|locked=" + CjYesNo(door.IsLocked()) + "|open=" + CjYesNo(door.IsOpen())
                + "|interactive=" + CjYesNo(interactive));
        }
    }
}

// tests: a string by its id as the game has it (empty: the game did not load it)
exec function cj_str(id : int) {
    CjOut("str|" + IntToString(id) + "|" + GetLocStringById(id));
}

// tests: play a scene of a DLC right here (its actors must be near) - e.g. to hear a talk again
exec function cj_scene(path : string) {
    var scene : CStoryScene;
    scene = (CStoryScene)LoadResource(path, true);
    if (!scene) {
        CjOut("scene|not found " + path);
        return;
    }
    theGame.GetStorySceneSystem().PlayScene(scene, "Input");
    CjOut("scene|playing " + path);
}

// tests: the look an entity with a tag wears (does a speaker wear the one with a face that can talk?)
exec function cj_look(tag : name) {
    var ents : array<CEntity>;
    var i : int;
    theGame.GetEntitiesByTag(tag, ents);
    for (i = 0; i < ents.Size(); i += 1) {
        CjOut("look|" + NameToString(tag) + "|" + NameToString(((CActor)ents[i]).GetAppearance()));
    }
    if (ents.Size() == 0) {
        CjOut("look|" + NameToString(tag) + "|none");
    }
}

// tests: another look for an entity with a tag
exec function cj_look_set(tag : name, look : string) {
    var ent : CEntity;
    ent = theGame.GetEntityByTag(tag);
    if (!ent) {
        CjOut("look_set|none");
        return;
    }
    ent.ApplyAppearance(look);
    CjOut("look_set|" + look);
}

// tests: an actor says one of the DLC's lines (its voice and lip sync from the speech file)
exec function cj_line(tag : name, id : int) {
    var actor : CActor;
    actor = (CActor)theGame.GetEntityByTag(tag);
    if (!actor) {
        CjOut("line|none");
        return;
    }
    actor.PlayLine(id, true);
    CjOut("line|" + NameToString(tag));
}

// tests: a witcher-sense clue's state (available, visible, interactive, detected, its distance from the player)
exec function cj_clue_info(tag : name) {
    var clue : W3MonsterClue;
    var inter : bool;
    clue = (W3MonsterClue)theGame.GetEntityByTag(tag);
    if (!clue) {
        CjOut("clueinfo|" + NameToString(tag) + "|none");
        return;
    }
    inter = false;
    if (clue.GetComponent("InteractiveClue")) {
        inter = true;
    }
    CjOut("clueinfo|" + NameToString(tag) + "|detected=" + CjYesNo(clue.GetWasDetected())
        + "|interactive=" + CjYesNo(inter)
        + "|dist=" + FloatToString(VecDistance(clue.GetWorldPosition(), thePlayer.GetWorldPosition())));
}

// tests: a clue found as if looked at in the witcher senses (the game's own detection: facts, next clue, comment)
exec function cj_clue_detect(tag : name) {
    var clue : W3MonsterClue;
    clue = (W3MonsterClue)theGame.GetEntityByTag(tag);
    if (clue) {
        clue.DetectClue();
        CjOut("cluedetect|" + NameToString(tag) + "|" + CjYesNo(clue.GetWasDetected()));
    }
}

// the ground under many points at once ("x,y,z;x,y,z;...": a ray from z + 3 m down to z - 6 m each) -> one line
// "grounds|z1;z2;..." (a point with nothing below keeps its z) - the editor lays a trail's pieces on it
exec function cj_grounds(points : string) {
    var rest, one, tail, xs, ys, zs, res : string;
    var hit, normal : Vector;
    var material : name;
    var comp : CComponent;
    var x, y, z : float;
    rest = points;
    res = "";
    while (rest != "") {
        if (!StrSplitFirst(rest, ";", one, tail)) {
            one = rest;
            tail = "";
        }
        rest = tail;
        StrSplitFirst(one, ",", xs, tail);
        StrSplitFirst(tail, ",", ys, zs);
        x = StringToFloat(xs);
        y = StringToFloat(ys);
        z = StringToFloat(zs);
        if (theGame.GetWorld().StaticTraceWithAdditionalInfo(Vector(x, y, z + 3), Vector(x, y, z - 6), hit, normal,
                                                             material, comp)) {
            z = hit.Z;
        }
        if (res != "") {
            res += ";";
        }
        res += FloatToString(z);
    }
    CjOut("grounds|" + res);
}

// the ground under placed things ("x,y,z;..."): a ray from z + 3 m down to z - 6 m; nothing hit (deeper under the
// ground, or not loaded): the navmesh's height within 30 m - only when it is above the point (a cellar keeps its
// floor) -> "groundz|z1;n;z3" (n: nothing found, the point is too far to be loaded)
exec function cj_ground_z(points : string) {
    var rest, one, tail, xs, ys, zs, res, got : string;
    var hit, normal : Vector;
    var material : name;
    var comp : CComponent;
    var x, y, z, gz : float;
    rest = points;
    res = "";
    while (rest != "") {
        if (!StrSplitFirst(rest, ";", one, tail)) {
            one = rest;
            tail = "";
        }
        rest = tail;
        StrSplitFirst(one, ",", xs, tail);
        StrSplitFirst(tail, ",", ys, zs);
        x = StringToFloat(xs);
        y = StringToFloat(ys);
        z = StringToFloat(zs);
        got = "n";
        if (theGame.GetWorld().StaticTraceWithAdditionalInfo(Vector(x, y, z + 3), Vector(x, y, z - 6), hit, normal,
                                                             material, comp)) {
            got = FloatToString(hit.Z);
        } else if (theGame.GetWorld().NavigationComputeZ(Vector(x, y, z, 1), z, z + 2.5, gz) && gz > z) {
            got = FloatToString(gz);
        }
        if (res != "") {
            res += ";";
        }
        res += got;
    }
    CjOut("groundz|" + res);
}

// tests: a notice board's notices (key, fact, shown), and taking one as its menu does
exec function cj_notices(tag : name) {
    var b : W3NoticeBoard;
    var i : int;
    b = (W3NoticeBoard)theGame.GetEntityByTag(tag);
    if (!b) {
        CjOut("notices|" + NameToString(tag) + "|no board");
        return;
    }
    for (i = 0; i < b.addedNotes.Size(); i += 1) {
        CjOut("notices|" + b.addedNotes[i].errandStringKey + "|" + b.addedNotes[i].newQuestFact + "|pos="
            + IntToString(b.addedNotes[i].errandPosition) + "|" + GetLocStringByKeyExt(b.addedNotes[i].errandStringKey));
    }
}

exec function cj_take_notice(tag : name, key : string) {
    var b : W3NoticeBoard;
    b = (W3NoticeBoard)theGame.GetEntityByTag(tag);
    if (b) {
        b.AcceptNewQuest(key);
        CjOut("notices|taken " + key);
    }
}

exec function cj_open_board(tag : name) {
    var b : W3NoticeBoard;
    b = (W3NoticeBoard)theGame.GetEntityByTag(tag);
    if (b) {
        b.OpenNoticeboardPanel();
    }
}

// tests: an NPC's state when it should walk and does not
exec function cj_npc_debug(tag : name, x : float, y : float, z : float) {
    var a : CActor;
    var mac : CMovingAgentComponent;
    var safe : Vector;
    a = (CActor)theGame.GetEntityByTag(tag);
    if (!a) {
        CjOut("npcdebug|none");
        return;
    }
    mac = a.GetMovingAgentComponent();
    CjOut("npcdebug|alive=" + CjYesNo(a.IsAlive()) + "|moving=" + CjYesNo(a.IsMoving())
        + "|combat=" + CjYesNo(a.IsInCombat()) + "|action=" + IntToString((int)a.GetCurrentActionType())
        + "|navigable=" + CjYesNo(mac.IsOnNavigableSpace()) + "|target ok=" + CjYesNo(mac.IsPositionValid(Vector(x, y, z)))
        + "|straight=" + CjYesNo(mac.CanGoStraightToDestination(Vector(x, y, z)))
        + "|safe spot=" + CjYesNo(theGame.GetWorld().NavigationFindSafeSpot(Vector(x, y, z, 1), 0.5, 5.0, safe))
        + " " + VecToString(safe)
        + "|atwork=" + CjYesNo(((CNewNPC)a).IsAtWork()) + "|working=" + CjYesNo(((CNewNPC)a).IsConsciousAtWork())
        + "|maxspeed=" + FloatToString(mac.GetMaxSpeed()) + "|forced=" + IntToString(mac.IsEntityRepresentationForced())
        + "|pos=" + VecToString(a.GetWorldPosition()));
}

// tests: an NPC sent to a point one way or another (0 ActionMoveToAsync, 1 forced AI tree, 2 after ActionCancelAll)
exec function cj_npc_try(tag : name, mode : int, x : float, y : float, z : float) {
    var a : CActor;
    var ok : bool;
    var id : int;
    var safe : Vector;
    var tree : CAIMoveToPoint;
    a = (CActor)theGame.GetEntityByTag(tag);
    if (!a) {
        return;
    }
    if (theGame.GetWorld().NavigationFindSafeSpot(Vector(x, y, z, 1), 0.5, 5.0, safe)) {
        x = safe.X;
        y = safe.Y;
        z = safe.Z;
    }
    if (mode == 0) {
        ok = a.ActionMoveToAsync(Vector(x, y, z, 1), MT_Walk, 1.0, 1.0);
        CjOut("npctry|0|" + CjYesNo(ok));
    } else if (mode == 1) {
        id = CjMoveNPC(a, Vector(x, y, z, 1), MT_Walk);
        CjOut("npctry|1|" + IntToString(id));
    } else if (mode == 2) {
        a.ActionCancelAll();
        ok = a.ActionMoveToAsync(Vector(x, y, z, 1), MT_Walk, 1.0, 1.0);
        CjOut("npctry|2|" + CjYesNo(ok));
    } else if (mode == 3) {
        a.SignalGameplayEvent('AI_ForceInterruption');
        id = CjMoveNPC(a, Vector(x, y, z, 1), MT_Walk);
        CjOut("npctry|3|" + IntToString(id));
    } else if (mode == 4) {
        tree = new CAIMoveToPoint in a;
        tree.OnCreated();
        tree.enterExplorationOnStart = false;
        tree.params.destinationPosition = Vector(x, y, z, 1);
        tree.params.destinationHeading = VecHeading(Vector(x, y, z, 1) - a.GetWorldPosition());
        tree.params.moveType = MT_Walk;
        tree.params.maxIterationsNumber = 2;
        tree.params.useTimeout = true;
        tree.params.timeoutValue = 3.0;
        id = a.ForceAIBehavior(tree, BTAP_Emergency);
        CjOut("npctry|4|" + IntToString(id));
    } else {
        ok = a.ActionExitWorkAsync(true);
        CjOut("npctry|5|exit work " + CjYesNo(ok));
    }
}

// tests: a path entity (pathfollow.py) as the game reads it - its points in the world
exec function cj_path_info(tag : name) {
    var e : CEntity;
    var p : CPathComponent;
    var i, n : int;
    var s : string;
    e = theGame.GetEntityByTag(tag);
    if (!e) {
        CjOut("pathinfo|" + NameToString(tag) + "|no entity");
        return;
    }
    p = (CPathComponent)e.GetComponentByClassName('CPathComponent');
    if (!p) {
        CjOut("pathinfo|" + NameToString(tag) + "|no path component");
        return;
    }
    n = p.GetPointsCount();
    s = "";
    for (i = 0; i < n; i += 1) {
        s += VecToString(p.GetWorldPoint(i)) + ";";
    }
    CjOut("pathinfo|" + NameToString(tag) + "|" + IntToString(n) + " points|" + s);
}

// tests: the newest save loaded again (a quest built while the game ran: does the load take it in?)
exec function cj_reload() {
    CjOut("reload|loading the last save");
    theGame.LoadLastGameInit();
}
