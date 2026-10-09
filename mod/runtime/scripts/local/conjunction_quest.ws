// conjunction quest functions: called by quests built with the suite (radish `script` blocks).

// reward step: money (crowns) and experience; money below 0: the player loses it (robbed, a fine)
quest function CjGive(money : int, xp : int) {
    if (money > 0) {
        thePlayer.AddMoney(money);
    } else if (money < 0) {
        thePlayer.RemoveMoney(Min(-money, thePlayer.GetMoney()));
    }
    if (xp > 0) {
        GetWitcherPlayer().AddPoints(EExperiencePoint, xp, true);
    }
    LogChannel('Cj', "give|money=" + IntToString(money) + "|xp=" + IntToString(xp));
}

// a chapter's journal text in place of the earlier ones: every paragraph of the quest's journal entry but `keep` set
// inactive (the journal shows what is not inactive - journalQuestMenu.ws), `keep` active. `journalQuest`: the
// journal quest's baseName (<quest id>_<key>), `keep`: the paragraph's (journal_encoder.py)
quest function CjJournalOnly(journalQuest : string, keep : string) {
    var jm : CWitcherJournalManager;
    var all : array<CJournalBase>;
    var q : CJournalQuest;
    var group : CJournalQuestDescriptionGroup;
    var para : CJournalBase;
    var i, k, hidden : int;
    jm = theGame.GetJournalManager();
    jm.GetActivatedOfType('CJournalQuest', all);
    for (i = 0; i < all.Size(); i += 1) {
        q = (CJournalQuest)all[i];
        if (q && q.baseName == journalQuest) {
            for (k = 0; k < q.GetNumChildren(); k += 1) {
                if ((CJournalQuestDescriptionGroup)q.GetChild(k)) {
                    group = (CJournalQuestDescriptionGroup)q.GetChild(k);
                }
            }
        }
    }
    if (!group) {
        LogChannel('Cj', "journal only|no journal entry " + journalQuest);
        return;
    }
    for (k = 0; k < group.GetNumChildren(); k += 1) {
        para = group.GetChild(k);
        if (para.baseName == keep) {
            jm.ActivateEntry(para, JS_Active);
        } else if (jm.GetEntryStatus(para) != JS_Inactive) {
            jm.ActivateEntry(para, JS_Inactive);
            hidden += 1;
        }
    }
    LogChannel('Cj', "journal only|" + journalQuest + "|" + keep + "|hidden=" + IntToString(hidden));
}

// dialogue choices: the answer the player picked, as a fact the quest branches on (<quest>_s<step>_choice = 1, 2, ..)
storyscene function CjSetFact(player : CStoryScenePlayer, fact : string, value : int) {
    FactsRemove(fact);
    FactsAdd(fact, value);
    LogChannel('Cj', "choice|" + fact + "=" + IntToString(value));
}

// collect step: waits until the player carries `count` of `item` (a look every second), then fact 1
latent quest function CjHasItems(item : string, count : int, fact : string) {
    var n : name;
    FactsRemove(fact);
    n = CjItemName(item);                      // the item as text (names with spaces work)
    if (n == '') {
        LogChannel('Cj', "has|unknown item " + item);
        return;
    }
    while (thePlayer.inv.GetItemQuantityByName(n) < count) {
        Sleep(1.0);
    }
    FactsAdd(fact, 1);
}

// a loot step's item (06.10.): until the player carries it, the container holds what is still missing - the item
// put in at the start is gone when the container comes anew (its layer hidden and shown, loaded again after the
// player went far away): put back, never twice (what the player carries counts)
function CjKeepIn(tag : name, n : name, count : int) {
    var ge : CGameplayEntity;
    var inv : CInventoryComponent;
    var want, have : int;
    want = count - thePlayer.inv.GetItemQuantityByName(n);
    if (want <= 0) {
        return;
    }
    ge = (CGameplayEntity)theGame.GetEntityByTag(tag);
    if (!ge) {
        return;                                 // (not loaded now: when it comes, the next look puts it in)
    }
    inv = ge.GetInventory();
    if (!inv) {
        return;
    }
    have = inv.GetItemQuantityByName(n);
    if (have < want) {
        inv.AddAnItem(n, want - have);
        LogChannel('Cj', "keep|" + NameToString(n) + " x" + IntToString(want - have) + " back into "
            + NameToString(tag));
    }
}

latent quest function CjHasItemsFrom(item : string, count : int, fact : string, tag : name) {
    var n : name;
    FactsRemove(fact);
    n = CjItemName(item);
    if (n == '') {
        LogChannel('Cj', "has|unknown item " + item);
        return;
    }
    while (thePlayer.inv.GetItemQuantityByName(n) < count) {
        CjKeepIn(tag, n, count);
        Sleep(1.0);
    }
    FactsAdd(fact, 1);
}

latent quest function CjHasItemsFromN(itemName : name, count : int, fact : string, tag : name) {
    FactsRemove(fact);
    while (thePlayer.inv.GetItemQuantityByName(itemName) < count) {
        CjKeepIn(tag, itemName, count);
        Sleep(1.0);
    }
    FactsAdd(fact, 1);
}

// If (Maxim 05.10.): has the player that many of the item - now, once: the fact 1 yes, 2 no
quest function CjHasItemsNow(item : string, count : int, fact : string) {
    var n : name;
    FactsRemove(fact);
    n = CjItemName(item);
    if (n != '' && thePlayer.inv.GetItemQuantityByName(n) >= count) {
        FactsAdd(fact, 1);
    } else {
        FactsAdd(fact, 2);
    }
}

quest function CjHasItemsNowN(itemName : name, count : int, fact : string) {
    FactsRemove(fact);
    if (thePlayer.inv.GetItemQuantityByName(itemName) >= count) {
        FactsAdd(fact, 1);
    } else {
        FactsAdd(fact, 2);
    }
}

// dialogue answers: what they do and what they need (the scene calls these; `player` is the scene's)
storyscene function CjSceneItem(player : CStoryScenePlayer, item : string, count : int) {
    var n : name;
    n = CjItemName(item);
    if (n == '') {
        LogChannel('Cj', "scene|unknown item " + item);
        return;
    }
    if (count > 0) {
        thePlayer.inv.AddAnItem(n, count);
    } else if (count < 0) {
        thePlayer.inv.RemoveItemByName(n, -count);
    }
}

storyscene function CjSceneGive(player : CStoryScenePlayer, money : int, xp : int) {
    if (money > 0) {
        thePlayer.AddMoney(money);
    }
    if (xp > 0) {
        GetWitcherPlayer().AddPoints(EExperiencePoint, xp, true);
    }
}

storyscene function CjSceneCheck(player : CStoryScenePlayer, fact : string, item : string, count : int, money : int) {
    var n : name;
    var ok : bool;
    ok = true;
    if (item != "") {
        n = CjItemName(item);
        ok = n != '' && thePlayer.inv.GetItemQuantityByName(n) >= count;
    }
    if (money > 0 && thePlayer.GetMoney() < money) {
        ok = false;
    }
    FactsRemove(fact);
    if (ok) {
        FactsAdd(fact, 1);
    }
}

// objects set up in the editor (inspector): once, as soon as the object is there (its place may stream in later).
// A fact per object and item keeps a reload from doing it again.
latent function CjWaitFor(tag : name) : CEntity {
    var e : CEntity;
    e = theGame.GetEntityByTag(tag);
    if (!e) {
        LogChannel('Cj', "setup|waiting for " + NameToString(tag));
    }
    while (!e) {
        Sleep(2.0);
        e = theGame.GetEntityByTag(tag);
    }
    // found while its layer streams in (a save just loaded): a moment to finish, its inventory too
    Sleep(1.0);
    LogChannel('Cj', "setup|there: " + NameToString(tag) + " = " + e.GetReadableName());
    return e;
}

// the inventory of a container / person that has just streamed in (it comes a moment after the entity)
latent function CjWaitInventory(ge : CGameplayEntity) : CInventoryComponent {
    var inv : CInventoryComponent;
    var i : int;
    inv = ge.GetInventory();
    for (i = 0; i < 40 && !inv; i += 1) {
        Sleep(0.5);
        inv = ge.GetInventory();
    }
    return inv;
}

// an item into an inventory - checked, and once more a moment later if it did not stay (a container that was still
// filling itself took it away)
latent function CjAddChecked(inv : CInventoryComponent, n : name, count : int, forQuest : bool) : int {
    var i, have : int;
    for (i = 0; i < 10; i += 1) {
        have = inv.GetItemQuantityByName(n);
        if (have >= count) {
            return have;
        }
        if (forQuest) {
            inv.AddAnItem(n, count - have, true, true);
        } else {
            inv.AddAnItem(n, count - have);
        }
        Sleep(1.0);
    }
    return inv.GetItemQuantityByName(n);
}

latent quest function CjSetupLook(tag : name, appearance : string) {
    var fact : string;
    var e : CEntity;
    fact = "cj_look_" + NameToString(tag);
    if (FactsQuerySum(fact) > 0) {
        return;
    }
    e = CjWaitFor(tag);
    e.ApplyAppearance(appearance);
    FactsAdd(fact, 1);
}

// item: its name as text (radish passes names only as [a-z_0-9]; CjItemName looks it up - conjunction_items.ws,
// made from the user's game when the suite installs its scripts)
// the loot table an object got in the editor: emptied, filled from the table ('' = none); once
latent quest function CjSetupLoot(tag : name, loot : string) {
    var found : CEntity;
    var fact : string;
    var ge : CGameplayEntity;
    var inv : CInventoryComponent;
    var items : array<SItemUniqueId>;
    var n : name;
    var i : int;
    fact = "cj_loot_" + NameToString(tag);
    LogChannel('Cj', "setup|loot " + NameToString(tag) + " '" + loot + "' done before=" + IntToString(FactsQuerySum(fact)));
    if (FactsQuerySum(fact) > 0) {
        return;
    }
    n = CjLootName(loot);
    found = CjWaitFor(tag);
    ge = (CGameplayEntity)found;
    if (!ge) {
        LogChannel('Cj', "setup|loot: not a gameplay entity");
    } else if (!ge.GetInventory()) {
        LogChannel('Cj', "setup|loot: no inventory");
    }
    if (ge) {
        inv = CjWaitInventory(ge);
        if (inv) {
            // one by one, as the game's scripts empty a container (RemoveAllItems is only ever used on Geralt; on a
            // chest it took the game down)
            inv.GetAllItems(items);
            LogChannel('Cj', "setup|loot emptying " + IntToString(items.Size()));
            for (i = items.Size() - 1; i >= 0; i -= 1) {
                inv.RemoveItem(items[i], inv.GetItemQuantity(items[i]));
            }
            if (n != '') {
                inv.AddItemsFromLootDefinition(n);
            }
        }
    }
    FactsAdd(fact, 1);
    LogChannel('Cj', "setup|loot done " + NameToString(tag));
}

// a person's or creature's loot when killed: the table's items added to what they carry (never emptied); once
latent quest function CjSetupDrops(tag : name, loot : string) {
    var found : CEntity;
    var fact : string;
    var ge : CGameplayEntity;
    var n : name;
    fact = "cj_drops_" + NameToString(tag);
    if (FactsQuerySum(fact) > 0) {
        return;
    }
    n = CjLootName(loot);
    if (n == '') {
        LogChannel('Cj', "setup|unknown loot table " + loot);
        return;
    }
    found = CjWaitFor(tag);
    ge = (CGameplayEntity)found;
    if (ge && ge.GetInventory()) {
        ge.GetInventory().AddItemsFromLootDefinition(n);
        LogChannel('Cj', "setup|drops " + loot + " -> " + NameToString(tag));
    }
    FactsAdd(fact, 1);
}

latent quest function CjSetupItem(tag : name, item : string, count : int) {
    var found : CEntity;
    var fact : string;
    var ge : CGameplayEntity;
    var inv : CInventoryComponent;
    var have : int;
    var n : name;
    n = CjItemName(item);
    if (n == '') {
        LogChannel('Cj', "setup|unknown item " + item);
        return;
    }
    fact = "cj_item_" + NameToString(tag) + "_" + item;
    if (FactsQuerySum(fact) > 0) {
        return;
    }
    found = CjWaitFor(tag);
    ge = (CGameplayEntity)found;
    if (ge) {
        inv = CjWaitInventory(ge);
        if (inv) {
            have = CjAddChecked(inv, n, count, true);
            LogChannel('Cj', "setup|item in: " + item + " x" + IntToString(have));
            if (have >= count) {
                FactsAdd(fact, 1);              // (not done: a save loaded later tries again)
            }
        } else {
            LogChannel('Cj', "setup|item: no inventory on " + NameToString(tag));
        }
    }
}

// hostile / friendly: an NPC (or every NPC with the tag) attacks the player - or stops (a fight after a talk)
quest function CjHostile(tag : name, hostile : bool) {
    var ents : array<CEntity>;
    var actor : CActor;
    var i : int;
    theGame.GetEntitiesByTag(tag, ents);
    for (i = 0; i < ents.Size(); i += 1) {
        actor = (CActor)ents[i];
        if (!actor) {
            continue;
        }
        if (hostile) {
            actor.SetTemporaryAttitudeGroup('hostile_to_player', AGP_Default);
        } else {
            actor.ResetTemporaryAttitudeGroup(AGP_Default);
        }
    }
    LogChannel('Cj', "hostile|" + NameToString(tag) + "|" + CjYesNo(hostile) + "|" + IntToString(ents.Size()));
}

// witcher-sense clues of a "find clues" step: the clue is switched on (visible in the senses, can be examined, once)
// and the block waits until Geralt examined it (the game's own clue entities, W3MonsterClue)
// Build & Play's runs of one project (<base>r<n>): a run says its number when it starts - only upward, an older
// run that starts after a newer one changes nothing
latent quest function CjRunStart(base : string, run : int) {
    if (FactsQueryLatestValue(base + "_run") < run) {
        FactsAdd(base + "_run", run);
    }
}

// ... and waits until a newer run has started (or Conjunction retires it): then it steps aside - its people
// and places go (Maxim 06.10.: three fathers after three runs)
latent quest function CjRunRetired(base : string, run : int, retired : string) {
    while (FactsQueryLatestValue(base + "_run") <= run && FactsQuerySum(retired) < 1) {
        Sleep(1.0);
    }
}

// a retiring run's person out of the world now (its community's despawn waits until nobody looks)
latent quest function CjRunGone(tag : name) {
    var found : array<CEntity>;
    var i : int;
    theGame.GetEntitiesByTag(tag, found);
    for (i = 0; i < found.Size(); i += 1) {
        if ((CActor)found[i]) {
            found[i].Destroy();
        }
    }
}

latent quest function CjClue(tag : name) {
    CjClueRun(tag, 0, false);
}

// how Geralt bends to it: 0 as the clue says (else to the ground, a body low), 1 ground, 2 eye level, 3 body, 4 high
latent quest function CjClueAs(tag : name, how : int) {
    CjClueRun(tag, how, false);
}

// the same, for a clue whose line is said while the game goes on: it comes as Geralt goes down (the game's own
// clues speak at the start of the interaction) - not after he stood up again
latent quest function CjClueSays(tag : name, how : int) {
    CjClueRun(tag, how, true);
}

latent function CjClueRun(tag : name, how : int, early : bool) {
    var found : CEntity;
    var clue : W3MonsterClue;
    found = CjWaitFor(tag);
    clue = (W3MonsterClue)found;
    if (!clue) {
        LogChannel('Cj', "clue|" + NameToString(tag) + " is not a clue");
        return;
    }
    CjClueHow(clue, how);
    CjClueSwitchOn(clue);
    // asked again each time by its tag: the place streams out when the player goes far (or flies in the editor) and
    // the clue comes back as a new entity - the old handle never sees it examined (Maxim 01.10.: E, nothing)
    while (true) {
        found = theGame.GetEntityByTag(tag);
        if ((W3MonsterClue)found != clue && (W3MonsterClue)found) {
            clue = (W3MonsterClue)found;
            if (!clue.GetWasDetected()) {
                CjClueHow(clue, how);
                CjClueSwitchOn(clue);          // a new one: its attributes are its template's again
            }
        }
        if (clue && clue.GetWasDetected()) {
            break;
        }
        Sleep(0.5);
    }
    LogChannel('Cj', "clue|" + NameToString(tag) + " examined");
    // the player kneels / bends to it (the clue's interaction animation): what follows (a monologue scene) waits for
    // it - started at once, the scene cut the animation off (Maxim 01.10.: "Geralt did not kneel")
    if (early) {
        Sleep(0.3);                         // (the scene takes about a second to come)
    } else if (clue.interactionAnim != PEA_None) {
        Sleep(ClampF(clue.interactionAnimTime, 1.5, 4.0));
    }
}

function CjClueHow(clue : W3MonsterClue, how : int) {
    if (how == 1) {
        clue.interactionAnim = PEA_ExamineGround;
    } else if (how == 2) {
        clue.interactionAnim = PEA_ExamineEyeLevel;
    } else if (how == 3) {
        clue.interactionAnim = PEA_InspectLow;
    } else if (how == 4) {
        clue.interactionAnim = PEA_InspectHigh;
    }
}

// a trail (trails.py): every piece with the tag lit in the witcher senses - nothing to press, they show the way
latent quest function CjClueGroupOn(tag : name) {
    var ents : array<CEntity>;
    var piece : W3MonsterClue;
    var i : int;
    theGame.GetEntitiesByTag(tag, ents);
    while (ents.Size() == 0) {
        Sleep(1.0);
        theGame.GetEntitiesByTag(tag, ents);
    }
    Sleep(1.0);                                 // (its layer still streaming in)
    theGame.GetEntitiesByTag(tag, ents);
    for (i = 0; i < ents.Size(); i += 1) {
        piece = (W3MonsterClue)ents[i];
        if (piece) {
            piece.SetAttributes(FCAA_ForceSet, true, false, false, true, false, false);
        }
    }
    LogChannel('Cj', "trail|" + NameToString(tag) + " on " + IntToString(ents.Size()));
}

// ... and done when Geralt has seen one of its pieces in the witcher senses (asked again each time: pieces stream)
latent quest function CjClueGroupSeen(tag : name) {
    var ents : array<CEntity>;
    var i : int;
    var clue : W3MonsterClue;
    while (true) {
        theGame.GetEntitiesByTag(tag, ents);
        for (i = 0; i < ents.Size(); i += 1) {
            clue = (W3MonsterClue)ents[i];
            if (clue && clue.GetWasDetected()) {
                LogChannel('Cj', "trail|" + NameToString(tag) + " seen");
                return;
            }
        }
        Sleep(0.5);
    }
}

function CjClueSwitchOn(clue : W3MonsterClue) {
    // Geralt kneels and looks at it, as at every clue of the game's contracts (their layers set it on each clue;
    // the catalog's generic clue templates leave it out - E then did nothing to see, Maxim 01.10.)
    if (clue.interactionAnim == PEA_None) {
        if ((W3ClueCorpse)clue) {
            clue.interactionAnim = PEA_InspectLow;
        } else {
            clue.interactionAnim = PEA_ExamineGround;
        }
    }
    if (clue.GetComponent("InteractiveClue")) {
        clue.SetAttributes(FCAA_ForceSet, true, true, false, true, false, false);     // examined (E)
    } else {
        // no examine interaction on this one: detected when looked at in the witcher senses, as the game does it
        clue.SetAttributes(FCAA_ForceSet, true, false, false, true, false, false);
    }
}

// a trail piece (footprints, blood, drag marks leading to a clue): red in the witcher senses from now on - it
// shows the way, there is nothing to examine (dark before: CjClueOff)
latent quest function CjClueOn(tag : name) {
    var found : CEntity;
    var clue : W3MonsterClue;
    found = CjWaitFor(tag);
    clue = (W3MonsterClue)found;
    if (clue) {
        if (clue.GetComponent("InteractiveClue")) {
            clue.SetAttributes(FCAA_ForceSet, true, true, false, true, false, false);
        } else {
            clue.SetAttributes(FCAA_ForceSet, true, false, false, true, false, false);
        }
    }
}

// --- actions of the quest board ("then"): small wrappers with plain parameters (radish passes no enums / structs)
quest function CjFx(tag : name, effect : name, on : bool) {
    var ents : array<CEntity>;
    var i : int;
    theGame.GetEntitiesByTag(tag, ents);
    for (i = 0; i < ents.Size(); i += 1) {
        if (on) {
            ents[i].PlayEffect(effect);
        } else {
            ents[i].StopEffect(effect);
        }
    }
}

quest function CjSound(soundEvent : string) {
    theSound.SoundEvent(soundEvent);
}

quest function CjFade(fadeOut : bool, seconds : float) {
    if (fadeOut) {
        theGame.FadeOutAsync(seconds);
    } else {
        theGame.FadeInAsync(seconds);
    }
}

// a portal (Maxim 01.10., Keira's hut and her bath): stepping into A takes the player to B's exit, into B (two-way)
// back to A's exit - a fade between (white like a mage's portal, or black). Runs beside the story as long as the quest
// does; the portals' effect shows them open.
function CjPortalFade(white : bool) {
    if (white) {
        theGame.FadeOutAsync(0.4, Color(254, 254, 254, 0));
    } else {
        theGame.FadeOutAsync(0.4);
    }
}

latent quest function CjPortal(tagA : name, tagB : name, ax : float, ay : float, az : float, ayaw : float,
                                 bx : float, by : float, bz : float, byaw : float, radius : float, twoWay : bool,
                                 white : bool, effect : name) {
    var a, b, litA, litB : CEntity;
    var p : Vector;
    var into : int;
    var glow : bool;
    glow = effect != '' && effect != 'none';
    a = CjWaitFor(tagA);
    LogChannel('Cj', "portal|" + NameToString(tagA) + "|open");
    // the other end may be far away and not streamed in yet (Keira's bath, 01.10.: the house portal stayed shut
    // while it waited for it) - each end lights up whenever it is there (again after it streamed out and in)
    while (true) {
        a = theGame.GetEntityByTag(tagA);           // (asked again: the place streams in and out)
        b = theGame.GetEntityByTag(tagB);
        if (glow && a && a != litA) {
            a.PlayEffect(effect);
            litA = a;
        }
        if (glow && twoWay && b && b != litB) {
            b.PlayEffect(effect);
            litB = b;
        }
        Sleep(0.25);
        p = thePlayer.GetWorldPosition();
        into = 0;
        if (a && VecDistance(p, a.GetWorldPosition()) < radius) {
            into = 1;
        } else if (twoWay && b && VecDistance(p, b.GetWorldPosition()) < radius) {
            into = 2;
        }
        if (into == 0) {
            continue;
        }
        CjPortalFade(white);
        Sleep(0.45);
        if (into == 1) {
            thePlayer.TeleportWithRotation(Vector(bx, by, bz), EulerAngles(0, byaw, 0));
        } else {
            thePlayer.TeleportWithRotation(Vector(ax, ay, az), EulerAngles(0, ayaw, 0));
        }
        Sleep(0.6);
        theGame.FadeInAsync(0.5);
        LogChannel('Cj', "portal|" + NameToString(tagA) + "|through " + IntToString(into));
        Sleep(2.0);                                 // (arrived beside the other one: not straight back)
    }
}

// go to - the other two ways (Keira stress test, 01.10.): away from a spot (farther than the radius: 'too far from
// the gossips'), or near a person wherever they are (within the radius of the tagged one); then the fact
latent quest function CjAwayFrom(x : float, y : float, z : float, radius : float, fact : string) {
    FactsRemove(fact);
    while (VecDistance(thePlayer.GetWorldPosition(), Vector(x, y, z)) <= radius) {
        Sleep(0.5);
    }
    FactsAdd(fact, 1);
}

latent quest function CjNearTo(tag : name, radius : float, fact : string) {
    var e : CEntity;
    FactsRemove(fact);
    while (true) {
        e = theGame.GetEntityByTag(tag);
        if (e && VecDistance(thePlayer.GetWorldPosition(), e.GetWorldPosition()) <= radius) {
            break;
        }
        Sleep(0.5);
    }
    FactsAdd(fact, 1);
}

// looking at a person or thing for some seconds (q104: the player watches the gossiping women): it stands near the
// middle of the screen, within the distance; looking away starts the count again
latent quest function CjLookAt(tag : name, seconds : float, radius : float, fact : string) {
    var e : CEntity;
    var held, x, y : float;
    FactsRemove(fact);
    held = 0;
    while (held < seconds) {
        Sleep(0.25);
        e = theGame.GetEntityByTag(tag);
        if (e && VecDistance(thePlayer.GetWorldPosition(), e.GetWorldPosition()) <= radius
                && theCamera.WorldVectorToViewRatio(e.GetWorldPosition() + Vector(0, 0, 1.2), x, y)
                && AbsF(x) < 0.4 && AbsF(y) < 0.6) {
            held += 0.25;
        } else {
            held = 0;
        }
    }
    FactsAdd(fact, 1);
}

// a fade in a colour (white like a mage's portal); CjFade stays as it is for quests built before
quest function CjFadeColor(fadeOut : bool, seconds : float, white : bool) {
    if (!fadeOut) {
        theGame.FadeInAsync(seconds);
    } else if (white) {
        theGame.FadeOutAsync(seconds, Color(254, 254, 254, 0));
    } else {
        theGame.FadeOutAsync(seconds);
    }
}

// lights on / off: candles, torches, braziers (their CGameplayLightComponent), as the game's SetLights - and a
// switch among them (W3Switch) turned too (Keira's candles, q104)
quest function CjLights(tag : name, on : bool, fade : bool) {
    var ents : array<CEntity>;
    var light : CGameplayLightComponent;
    var sw : W3Switch;
    var i : int;
    theGame.GetEntitiesByTag(tag, ents);
    for (i = 0; i < ents.Size(); i += 1) {
        light = (CGameplayLightComponent)ents[i].GetComponentByClassName('CGameplayLightComponent');
        if (light) {
            if (fade) {
                light.SetFadeLight(on);
            } else {
                light.SetLight(on);
            }
            continue;
        }
        sw = (W3Switch)ents[i];
        if (sw) {
            sw.Turn(on, NULL, true, false);
        }
    }
}

// a person (or a thing) gone from the world and back: not drawn, no collision, nothing to interact with
quest function CjPresence(tag : name, show : bool) {
    var ents : array<CEntity>;
    var comps : array<CComponent>;
    var actor : CActor;
    var i, j : int;
    theGame.GetEntitiesByTag(tag, ents);
    for (i = 0; i < ents.Size(); i += 1) {
        ents[i].SetHideInGame(!show, true);
        actor = (CActor)ents[i];
        if (actor) {
            actor.EnableCollisions(show);
            actor.SetGameplayVisibility(show);
        }
        comps = ents[i].GetComponentsByClassName('CInteractionComponent');
        for (j = 0; j < comps.Size(); j += 1) {
            comps[j].SetEnabled(show);
        }
    }
}

// the creatures of an area (one of the game's encounters: wolves, drowners) off / on, by its tag - the game finds
// encounters only so (a search around a point found none, 01.10.); the quest step calls this for each encounter
// within its radius (encounters.py: the index of the world's encounters). Off also takes away the ones already out.
quest function CjEncounter(tag : name, enable : bool) {
    var ents : array<CEntity>;
    var enc : CEncounter;
    var i, n : int;
    theGame.GetEntitiesByTag(tag, ents);
    for (i = 0; i < ents.Size(); i += 1) {
        enc = (CEncounter)ents[i];
        if (!enc) {
            continue;
        }
        enc.EnableEncounter(enable);
        if (!enable) {
            enc.ForceDespawnDetached();
        }
        n += 1;
    }
    if (enable) {
        LogChannel('Cj', "encounter|" + NameToString(tag) + "|" + IntToString(n) + "|on");
    } else {
        LogChannel('Cj', "encounter|" + NameToString(tag) + "|" + IntToString(n) + "|off");
    }
}

quest function CjShake(strength : float) {
    GCameraShake(strength);
}

quest function CjWeather(weather : name, blend : float) {
    RequestWeatherChangeTo(weather, blend, false);
}

quest function CjMessage(text : string) {
    thePlayer.DisplayHudMessage(text);
}

// open / close / lock (with a key item) / unlock a door
quest function CjDoor(tag : name, doorState : string, key : string) {
    var keyName : name;
    if (key != "") {
        keyName = CjItemName(key);
    }
    if (doorState == "open") {
        DoorChangeState(tag, EDQS_Open, keyName, false, true, false);
    } else if (doorState == "close") {
        DoorChangeState(tag, EDQS_Close, keyName, false, true, false);
    } else if (doorState == "lock") {
        DoorChangeState(tag, EDQS_Lock, keyName, false, true, false);
    } else if (doorState == "unlock") {
        DoorChangeState(tag, EDQS_RemoveLock, keyName, false, true, false);
    }
}

// a lever, button or handle (the game's W3Switch): until it is on (or off) - its real state, not only "used"
latent quest function CjWaitSwitch(tag : name, on : bool) {
    var found : CEntity;
    var sw : W3Switch;
    found = CjWaitFor(tag);
    sw = (W3Switch)found;
    if (!sw) {
        LogChannel('Cj', "switch|" + NameToString(tag) + " is not a switch");
        return;
    }
    while (sw.IsOn() != on) {
        Sleep(0.5);
    }
}

// a mechanism the quest sets: on, off, lock (nobody can use it), unlock
quest function CjSwitch(tag : name, how : string) {
    var ents : array<CEntity>;
    var sw : W3Switch;
    var i : int;
    theGame.GetEntitiesByTag(tag, ents);
    for (i = 0; i < ents.Size(); i += 1) {
        sw = (W3Switch)ents[i];
        if (!sw) {
            continue;
        }
        if (how == "on" || how == "off") {
            sw.Turn(how == "on", NULL, true, false);
        } else if (how == "lock" || how == "unlock") {
            sw.Lock(how == "lock");
        }
    }
}

// follow / escort: the path as text "x,y,z;x,y,z;..." (radish passes no arrays)
function CjPathPoints(path : string) : array<Vector> {
    var pts : array<Vector>;
    var rest, one, x, yz, y, z, tail : string;
    rest = path;
    while (StrLen(rest) > 0) {
        if (!StrSplitFirst(rest, ";", one, tail)) {
            one = rest;
            tail = "";
        }
        if (StrSplitFirst(one, ",", x, yz) && StrSplitFirst(yz, ",", y, z)) {
            pts.PushBack(Vector(StringToFloat(x), StringToFloat(y), StringToFloat(z), 1));   // (a position: W 1)
        }
        rest = tail;
    }
    return pts;
}

// Geralt follows: the NPC walks (runs) the path point by point; when Geralt falls behind more than waitDist it stops
// and waits for him. lead: Geralt leads - the NPC follows him until both are at the path's last point.
// an NPC sent to a point by an AI tree forced on it (as the game's quests do with Scripted Actions): a community NPC
// at its work turns ActionMoveToAsync down (02.10.: the guide never took a step) -> the behaviour's id (-1: refused)
function CjMoveNPC(npc : CActor, pos : Vector, mt : EMoveType) : int {
    var tree : CAIMoveToPoint;
    var z : float;
    var id : int;
    var safe : Vector;
    tree = new CAIMoveToPoint in npc;
    tree.OnCreated();
    tree.enterExplorationOnStart = false;
    pos.W = 1;
    // the point on the navmesh (as the game's scenes do): a height a little off finds no way
    if (theGame.GetWorld().NavigationComputeZ(pos, pos.Z - 5, pos.Z + 5, z)) {
        pos.Z = z;
    }
    // a point drawn beside the navmesh (a bush, a wall): the nearest free spot on it (02.10.: none was valid)
    if (!npc.GetMovingAgentComponent().IsPositionValid(pos)
            && theGame.GetWorld().NavigationFindSafeSpot(pos, 0.5, 5.0, safe)) {
        pos = safe;
    }
    pos.W = 1;                                  // a position (the safe spot came back as a direction: W 0)
    tree.params.destinationPosition = pos;
    tree.params.destinationHeading = VecHeading(pos - npc.GetWorldPosition());
    tree.params.moveType = mt;
    tree.params.maxDistance = 1.0;
    tree.params.maxIterationsNumber = 3;
    id = npc.ForceAIBehavior(tree, BTAP_Emergency);
    LogChannel('Cj', "move|" + VecToString(npc.GetWorldPosition()) + " -> " + VecToString(pos) + "|ai " + IntToString(id));
    return id;
}

// `progress`: a fact the waypoint reached is written to (1 = the first) - talks on the way start by it
latent quest function CjEscort(tag : name, path : string, lead : bool, run : bool, waitDist : float, progress : string) {
    var found : CEntity;
    var npc : CActor;
    var pts : array<Vector>;
    var mt : EMoveType;
    var k, ai : int;
    var goal : Vector;
    found = CjWaitFor(tag);
    npc = (CActor)found;
    pts = CjPathPoints(path);
    ai = -1;
    if (!npc || pts.Size() == 0) {
        LogChannel('Cj', "escort|" + NameToString(tag) + " - no NPC or no path");
        return;
    }
    mt = MT_Walk;
    if (run) {
        mt = MT_Run;
    }
    LogChannel('Cj', "escort|" + NameToString(tag) + "|start|" + IntToString(pts.Size()) + " points");
    if (lead) {
        goal = pts[pts.Size() - 1];
        while (VecDistance2D(thePlayer.GetWorldPosition(), goal) > 5.0
               || VecDistance2D(npc.GetWorldPosition(), goal) > 8.0) {
            if (VecDistance2D(npc.GetWorldPosition(), thePlayer.GetWorldPosition()) > 3.0 && !npc.IsMoving()) {
                npc.ActionMoveToDynamicNodeAsync(thePlayer, mt, 1.0, 2.5, true);
            }
            Sleep(0.5);
        }
        npc.ActionCancelAll();
        return;
    }
    k = 0;
    while (k < pts.Size()) {
        if (VecDistance2D(npc.GetWorldPosition(), thePlayer.GetWorldPosition()) > waitDist) {
            if (ai >= 0) {                          // wait for the player
                npc.CancelAIBehavior(ai);
                ai = -1;
            }
            while (VecDistance2D(npc.GetWorldPosition(), thePlayer.GetWorldPosition()) > waitDist * 0.7) {
                Sleep(0.5);
            }
        }
        if (VecDistance2D(npc.GetWorldPosition(), pts[k]) <= 1.5) {
            k += 1;
            LogChannel('Cj', "escort|" + NameToString(tag) + "|at " + IntToString(k));
            if (progress != "") {
                FactsRemove(progress);
                FactsAdd(progress, k);
            }
            if (ai >= 0) {
                npc.CancelAIBehavior(ai);
                ai = -1;
            }
        } else if (ai < 0) {
            ai = CjMoveNPC(npc, pts[k], mt);
            if (ai < 0) {
                LogChannel('Cj', "escort|" + NameToString(tag) + "|cannot move to point " + IntToString(k + 1));
            }
        }
        Sleep(0.3);
    }
    if (ai >= 0) {
        npc.CancelAIBehavior(ai);
    }
}

// a person walking by his community's phases (02.10.: the quest switched the phase that sends him to the point)
// is there - within 2 m of it, at most 90 s (far away, not loaded: the quest goes on); `progress` counts the points
// (talks on the way wait for it); waitDist > 0: then the player must come within that distance (a follow)
latent quest function CjArrive(tag : name, x : float, y : float, z : float, point : int, progress : string,
                                waitDist : float, pin : name) {
    var found : CEntity;
    var npc : CActor;
    var goal : Vector;
    var t : float;
    found = CjWaitFor(tag);
    npc = (CActor)found;
    if (!npc) {
        LogChannel('Cj', "arrive|" + NameToString(tag) + "|no NPC");
        return;
    }
    goal = Vector(x, y, z, 1);
    // at least a moment between two phases: two in the same instant and the game kept the first only (02.10.: he
    // stood beside point 1 after a talk, point 2 came at once and was never taken - 90 s until the next)
    Sleep(1.5);
    t = 1.5;
    // (5 m short: the next point is set before he gets there - at 2 m he stood and idled at every point, 02.10.)
    while (VecDistance2D(npc.GetWorldPosition(), goal) > 5.0 && t < 90.0) {
        CjPinTo(pin, npc);
        Sleep(0.5);
        t += 0.5;
    }
    CjPinTo(pin, npc);
    LogChannel('Cj', "arrive|" + NameToString(tag) + "|point " + IntToString(point) + "|"
        + FloatToString(VecDistance2D(npc.GetWorldPosition(), goal)) + " m after " + FloatToString(t) + " s");
    if (progress != "") {
        FactsRemove(progress);
        FactsAdd(progress, point);
    }
    if (waitDist > 0) {
        while (VecDistance2D(npc.GetWorldPosition(), thePlayer.GetWorldPosition()) > waitDist) {
            CjPinTo(pin, npc);
            Sleep(0.5);
        }
    }
}

// the quest's map pin (an entity of its meta layer, tagged with the pin's name) onto a person who walks - the map
// and the minimap show him, not the end of his way
function CjPinTo(pin : name, npc : CActor) {
    var e : CEntity;
    if (pin == 'cj_nopin' || !npc) {
        return;
    }
    if (npc.HasTag(pin)) {
        return;
    }
    // the pin's own entity is a static of the meta layer - teleported, the map kept it at the start (02.10.): the
    // tag goes to him instead, the map follows a tagged person (as the game's escort quests)
    e = theGame.GetEntityByTag(pin);
    if (e) {
        e.RemoveTag(pin);
    }
    npc.AddTag(pin);
    theGame.GetCommonMapManager().InvalidateStaticMapPin(pin);
    LogChannel('Cj', "pin|" + NameToString(pin) + "|on the person");
}

// an NPC walks (runs) to a point and stays there; waitThere: the quest goes on when it has arrived
latent quest function CjWalkTo(tag : name, x : float, y : float, z : float, run : bool, waitThere : bool) {
    var found : CEntity;
    var npc : CActor;
    var mt : EMoveType;
    found = CjWaitFor(tag);
    npc = (CActor)found;
    if (!npc) {
        return;
    }
    mt = MT_Walk;
    if (run) {
        mt = MT_Run;
    }
    if (CjMoveNPC(npc, Vector(x, y, z, 1), mt) < 0) {
        LogChannel('Cj', "walk|" + NameToString(tag) + "|cannot move");
        return;
    }
    if (waitThere) {                            // the quest goes on once there (within 2 m)
        while (VecDistance2D(npc.GetWorldPosition(), Vector(x, y, z, 1)) > 2.0) {
            Sleep(0.5);
        }
    }
}

// an NPC patrols a way ("x,y,z;..."), point to point and back to the first, on and on (not while fighting); runs in
// a branch of its own, the quest goes on
latent quest function CjPatrol(tag : name, path : string, run : bool) {
    var found : CEntity;
    var npc : CActor;
    var pts : array<Vector>;
    var mt : EMoveType;
    var k, ai : int;
    found = CjWaitFor(tag);
    npc = (CActor)found;
    pts = CjPathPoints(path);
    if (!npc || pts.Size() == 0) {
        return;
    }
    mt = MT_Walk;
    if (run) {
        mt = MT_Run;
    }
    k = 0;
    ai = -1;
    while (npc && npc.IsAlive()) {
        if (VecDistance2D(npc.GetWorldPosition(), pts[k]) <= 1.5) {
            k = (k + 1) % pts.Size();
            if (ai >= 0) {
                npc.CancelAIBehavior(ai);
                ai = -1;
            }
            Sleep(1.5);                             // a look around at each point
        } else if (ai < 0 && !npc.IsInCombat()) {
            ai = CjMoveNPC(npc, pts[k], mt);
        } else if (ai >= 0 && npc.IsInCombat()) {   // a fight: the patrol waits
            npc.CancelAIBehavior(ai);
            ai = -1;
        }
        Sleep(0.5);
    }
}

// a tutorial popup: a title and a text (<<Action>> tags become the key's icon), shown for some seconds
quest function CjTutorial(title : string, text : string, seconds : float) {
    var data : W3TutorialPopupData;
    data = new W3TutorialPopupData in theGame;
    data.managerRef = theGame.GetTutorialSystem();
    data.scriptTag = 'cj_tutorial';
    data.messageTitle = title;
    data.messageText = ReplaceTagsToIcons(text);
    data.duration = seconds * 1000.0;
    theGame.RequestMenu('TutorialPopupMenu', data);
}

// a chest (anything lockable) locked with a key item - the game's item by text - or unlocked; keyGoes: the key
// is taken when it opens the lock
latent quest function CjLock(tag : name, lock : bool, key : string, keyGoes : bool) {
    var keyName : name;
    if (key != "") {
        keyName = CjItemName(key);
    }
    CjLockName(tag, lock, keyName, keyGoes);
}

// the same with the quest's own key (by name)
latent quest function CjLockN(tag : name, lock : bool, keyName : name, keyGoes : bool) {
    CjLockName(tag, lock, keyName, keyGoes);
}

latent function CjLockName(tag : name, lock : bool, keyName : name, keyGoes : bool) {
    var found : CEntity;
    var box : W3LockableEntity;
    found = CjWaitFor(tag);
    box = (W3LockableEntity)found;
    if (!box) {
        LogChannel('Cj', "lock|" + NameToString(tag) + " cannot be locked");
        return;
    }
    if (lock) {
        box.Lock(keyName, keyGoes);
    } else {
        box.Unlock();
    }
}

// Geralt gets (count > 0) or loses (count < 0) an item
quest function CjPlayerItem(item : string, count : int) {
    var n : name;
    n = CjItemName(item);
    if (n == '') {
        LogChannel('Cj', "item|unknown " + item);
        return;
    }
    if (count > 0) {
        thePlayer.inv.AddAnItem(n, count);
    } else if (count < 0) {
        thePlayer.inv.RemoveItemByName(n, -count);
    }
}

// immortal: cannot die ("until he yields"); unconscious: falls down instead of dying; off
quest function CjImmortal(tag : name, mode : string) {
    var ents : array<CEntity>;
    var actor : CActor;
    var i : int;
    theGame.GetEntitiesByTag(tag, ents);
    for (i = 0; i < ents.Size(); i += 1) {
        actor = (CActor)ents[i];
        if (!actor) {
            continue;
        }
        if (mode == "immortal") {
            actor.SetImmortalityMode(AIM_Immortal, AIC_Default);
        } else if (mode == "unconscious") {
            actor.SetImmortalityMode(AIM_Unconscious, AIC_Default);
        } else {
            actor.SetImmortalityMode(AIM_None, AIC_Default);
        }
    }
}

// the time of day (the next time it is that hour)
quest function CjSetTime(hour : int, minute : int) {
    var now : GameTime;
    var day : int;
    now = theGame.GetGameTime();
    day = GameTimeDays(now);
    if (GameTimeHours(now) * 60 + GameTimeMinutes(now) >= hour * 60 + minute) {
        day += 1;
    }
    theGame.SetGameTime(GameTimeCreate(day, hour, minute, 0), true);
}

// play as: from here on the player is someone else - as the game's quests do it (ChangePlayerQuest: the Baron's
// story told as Ciri). who: geralt | ciri; look: "" | wounded | winter | naked; move: taken to x, y, z first, behind
// a black screen (the game teleports before it switches, the new player stands where the old one stood)
latent quest function CjPlayAs(who : string, look : string, x : float, y : float, z : float, yaw : float,
                                move : bool) {
    theGame.FadeOutAsync(0.4);
    Sleep(0.5);
    if (move) {
        thePlayer.TeleportWithRotation(Vector(x, y, z, 1), EulerAngles(0, yaw, 0));
        Sleep(0.3);
    }
    if (who == "ciri") {
        if (look == "naked") {
            theGame.ChangePlayer("Ciri_naked");
        } else {
            theGame.ChangePlayer("Ciri");
        }
        while (!((W3ReplacerCiri)thePlayer)) {
            SleepOneFrame();
        }
        if (look == "wounded") {
            thePlayer.ApplyAppearance("ciri_wounded");
        } else if (look == "winter") {
            thePlayer.ApplyAppearance("ciri_winter");
        } else if (look != "naked") {
            thePlayer.ApplyAppearance("ciri_player");
        }
    } else {
        theGame.ChangePlayer("Geralt");
        while (!((W3PlayerWitcher)thePlayer)) {
            SleepOneFrame();
        }
    }
    thePlayer.abilityManager.RestoreStat(BCS_Vitality);
    Sleep(0.3);
    theGame.FadeInAsync(0.6);
    LogChannel('Cj', "playas|" + who + "|" + look);
}

quest function CjTeleport(x : float, y : float, z : float, yaw : float) {
    thePlayer.TeleportWithRotation(Vector(x, y, z, 1), EulerAngles(0, yaw, 0));
}

quest function CjAutosave() {
    theGame.RequestAutoSave("conjunction quest", false);
}

// defeat: the fight goes on until the NPC's health is down to `percent` (he is immortal meanwhile), then it stops
latent quest function CjWaitDefeated(tag : name, percent : int) {
    var found : CEntity;
    var actor : CActor;
    found = CjWaitFor(tag);
    actor = (CActor)found;
    if (!actor) {
        return;
    }
    while (actor.GetHealthPercents() < 0 || actor.GetHealthPercents() * 100 > percent) {
        Sleep(0.3);
    }
    LogChannel('Cj', "defeated|" + NameToString(tag));
}

// read: waits until Geralt has read the book / letter / notice (the game marks read books)
latent quest function CjWaitRead(item : string) {
    var n : name;
    n = CjItemName(item);
    if (n == '') {
        LogChannel('Cj', "read|unknown item " + item);
        return;
    }
    while (!thePlayer.inv.IsBookReadByName(n)) {
        Sleep(0.5);
    }
}

// wait until a time of day (within the hour after it: a quest that comes back later does not wait a whole day)
latent quest function CjWaitHour(hour : int, minute : int) {
    var now : GameTime;
    var t, target : int;
    target = hour * 60 + minute;
    while (true) {
        now = theGame.GetGameTime();
        t = GameTimeHours(now) * 60 + GameTimeMinutes(now);
        if ((t - target + 1440) % 1440 < 60) {
            return;
        }
        Sleep(1.0);
    }
}

// Go to at a time of day and / or staying there: done when Geralt is within `radius` of the point in the hours
// [fromHour, toHour) (from == to: any time; 22 to 5 goes over midnight - he may wait there, meditate); with `stay`,
// leaving the circle (by 5 m) after arriving ends it too. The fact says how: 1 arrived in time, 2 left.
latent quest function CjGoAt(x : float, y : float, z : float, radius : float, fromHour : int, toHour : int,
                              stay : bool, fact : string) {
    var d : float;
    var h : int;
    var arrived, inHours : bool;
    FactsRemove(fact);
    while (true) {
        d = VecDistance2D(thePlayer.GetWorldPosition(), Vector(x, y, z));
        h = GameTimeHours(theGame.GetGameTime());
        if (fromHour == toHour) {
            inHours = true;
        } else if (fromHour < toHour) {
            inHours = h >= fromHour && h < toHour;
        } else {
            inHours = h >= fromHour || h < toHour;
        }
        if (d <= radius) {
            arrived = true;
            if (inHours) {
                FactsAdd(fact, 1);
                return;
            }
        } else if (stay && arrived && d > radius + 5.0) {
            FactsAdd(fact, 2);
            return;
        }
        Sleep(0.5);
    }
}

// clues of a later step: dark in the witcher senses until their step switches them on (CjClue)
latent quest function CjClueOff(tag : name) {
    var found : CEntity;
    var clue : W3MonsterClue;
    found = CjWaitFor(tag);
    clue = (W3MonsterClue)found;
    if (clue && !clue.GetWasDetected()) {
        clue.SetAttributes(FCAA_ForceSet, false, false, false, false, false, false);
    }
}

// --- the quest's own items (letters, notes, books its DLC defines): passed by name (radish: cname_<id>), no lookup
quest function CjPlayerItemN(itemName : name, count : int) {
    if (count > 0) {
        thePlayer.inv.AddAnItem(itemName, count);
    } else if (count < 0) {
        thePlayer.inv.RemoveItemByName(itemName, -count);
    }
}

latent quest function CjWaitReadN(itemName : name) {
    while (!thePlayer.inv.IsBookReadByName(itemName)) {
        Sleep(0.5);
    }
}

// collect / use with an item: waits until the player carries `count` of it (a look every second - the quest's own
// pause between checks took up to two minutes), then the fact the quest goes on with
latent quest function CjHasItemsN(itemName : name, count : int, fact : string) {
    FactsRemove(fact);
    while (thePlayer.inv.GetItemQuantityByName(itemName) < count) {
        Sleep(1.0);
    }
    FactsAdd(fact, 1);
    LogChannel('Cj', "has|" + NameToString(itemName) + " " + IntToString(thePlayer.inv.GetItemQuantityByName(itemName))
        + "/" + IntToString(count) + " -> " + fact);
}

// equip step (Maxim, 01.10.): waits until the player wears / holds the item in one of their slots, then the fact
function CjIsEquipped(itemName : name) : bool {
    var witcher : W3PlayerWitcher;
    witcher = GetWitcherPlayer();
    if (!witcher) {
        return false;
    }
    return witcher.IsItemEquippedByName(itemName);
}

latent quest function CjEquippedN(itemName : name, count : int, fact : string) {
    FactsRemove(fact);
    while (!CjIsEquipped(itemName)) {
        Sleep(1.0);
    }
    FactsAdd(fact, 1);
    LogChannel('Cj', "equipped|" + NameToString(itemName) + " -> " + fact);
}

latent quest function CjEquipped(item : string, count : int, fact : string) {
    var n : name;
    FactsRemove(fact);
    n = CjItemName(item);
    if (n == '') {
        LogChannel('Cj', "equipped|unknown item " + item);
        return;
    }
    while (!CjIsEquipped(n)) {
        Sleep(1.0);
    }
    FactsAdd(fact, 1);
    LogChannel('Cj', "equipped|" + item + " -> " + fact);
}

latent quest function CjSetupItemN(tag : name, itemName : name, count : int) {
    var found : CEntity;
    var fact : string;
    var ge : CGameplayEntity;
    var inv : CInventoryComponent;
    var have : int;
    LogChannel('Cj', "setup|itemN called");
    fact = "cj_item_" + NameToString(tag) + "_" + NameToString(itemName);
    LogChannel('Cj', "setup|item " + NameToString(itemName) + " -> " + NameToString(tag) + " done before="
        + IntToString(FactsQuerySum(fact)));
    if (FactsQuerySum(fact) > 0) {
        return;
    }
    found = CjWaitFor(tag);
    ge = (CGameplayEntity)found;
    if (ge) {
        inv = CjWaitInventory(ge);
        if (inv) {
            have = CjAddChecked(inv, itemName, count, false);     // (a latent call may not stand in a condition)
            if (have >= count) {
                FactsAdd(fact, 1);              // (not done: a save loaded later tries again)
            }
            LogChannel('Cj', "setup|item in: " + NameToString(itemName) + " x"
                + IntToString(inv.GetItemQuantityByName(itemName)));
        } else {
            LogChannel('Cj', "setup|item: no inventory on " + NameToString(tag));
        }
    }
}

storyscene function CjSceneItemN(player : CStoryScenePlayer, itemName : name, count : int) {
    if (count > 0) {
        thePlayer.inv.AddAnItem(itemName, count);
    } else if (count < 0) {
        thePlayer.inv.RemoveItemByName(itemName, -count);
    }
}

// an answer shown only if the player has one of these items (items: "a;b;c", their names), or - none - none of them
storyscene function CjSceneHas(player : CStoryScenePlayer, fact : string, items : string, count : int, none : bool) {
    var rest, one, tail : string;
    var n : name;
    var found : bool;
    rest = items;
    while (rest != "") {
        if (!StrSplitFirst(rest, ";", one, tail)) {
            one = rest;
            tail = "";
        }
        n = CjItemName(one);
        if (n != '' && thePlayer.inv.GetItemQuantityByName(n) >= count) {
            found = true;
        }
        rest = tail;
    }
    FactsRemove(fact);
    if (found != none) {
        FactsAdd(fact, 1);
    }
}

// an answer shown only if all these facts are so (checks: "fact,op,value;fact,op,value"; op = != < <= > >=)
storyscene function CjSceneAll(player : CStoryScenePlayer, fact : string, checks : string) {
    var rest, one, tail, f, opv, op, v : string;
    var have, want : int;
    var ok : bool;
    ok = true;
    rest = checks;
    while (rest != "") {
        if (!StrSplitFirst(rest, ";", one, tail)) {
            one = rest;
            tail = "";
        }
        if (StrSplitFirst(one, ",", f, opv) && StrSplitFirst(opv, ",", op, v)) {
            have = FactsQuerySum(f);
            want = StringToInt(v);
            if (op == "=" && have != want) { ok = false; }
            if (op == "!=" && have == want) { ok = false; }
            if (op == "<" && have >= want) { ok = false; }
            if (op == "<=" && have > want) { ok = false; }
            if (op == ">" && have <= want) { ok = false; }
            if (op == ">=" && have < want) { ok = false; }
        }
        rest = tail;
    }
    FactsRemove(fact);
    if (ok) {
        FactsAdd(fact, 1);
    }
}

storyscene function CjSceneCheckN(player : CStoryScenePlayer, fact : string, itemName : name, count : int) {
    FactsRemove(fact);
    if (thePlayer.inv.GetItemQuantityByName(itemName) >= count) {
        FactsAdd(fact, 1);
    }
}

// notice: a notice on a notice board (the game's, by its tag, or one placed by the quest) - its title and text are
// the strings `key` and `key`_text; taking it in the board's menu adds `fact` (the quest waits for it). The board
// shows it until taken (W3NoticeBoard.SetCardsVisible: hidden once the fact exists).
latent quest function CjNotice(board : name, key : string, fact : string) {
    CjNoticeOn(board, key, fact, '');
}

// the same, and taking it gives the player `item` (the notice to read again)
latent quest function CjNoticeN(board : name, key : string, fact : string, item : name) {
    CjNoticeOn(board, key, fact, item);
}

latent function CjNoticeOn(board : name, key : string, fact : string, item : name) {
    var ents : array<CEntity>;
    var b : W3NoticeBoard;
    var errand : ErrandDetailsList;
    var i : int;
    errand.errandStringKey = key;
    errand.newQuestFact = fact;
    errand.addedItemName = item;
    // a board far away is not there (streamed out): waited for until the player comes near it
    theGame.GetEntitiesByTag(board, ents);
    while (ents.Size() == 0) {
        Sleep(2.0);
        theGame.GetEntitiesByTag(board, ents);
    }
    for (i = 0; i < ents.Size(); i += 1) {
        b = (W3NoticeBoard)ents[i];
        if (b) {
            b.AddErrand(errand, true);
            b.UpdateBoard();
            b.UpdateInteraction();
            LogChannel('Cj', "notice|" + key + "|on " + NameToString(board));
        }
    }
}


// wait for: something of the game (PLAN 3.4) - 1 a fight starts, 2 the fight is over, 3 the witcher senses are on,
// 4 the player's health at or below `percent`
latent quest function CjWaitGame(what : int, percent : int) {
    var focus : CFocusModeController;
    while (true) {
        if (what == 1 && thePlayer.IsInCombat()) {
            break;
        }
        if (what == 2 && !thePlayer.IsInCombat()) {
            break;
        }
        if (what == 3) {
            focus = theGame.GetFocusModeController();
            if (focus && focus.IsActive()) {
                break;
            }
        }
        if (what == 4 && thePlayer.GetHealthPercents() * 100.0 <= (float)percent) {
            break;
        }
        Sleep(0.25);
    }
    LogChannel('Cj', "waitfor|" + IntToString(what));
}

// a person of the quest whose template has a talk of its own (a merchant, a smith): it is switched off whenever he
// is there (he comes anew after a phase or out of streaming) - the quest's talks only (Maxim 02.10.)
latent quest function CjOwnTalkOff(tag : name) {
    var e : CEntity;
    var c : CComponent;
    var told : bool;
    while (true) {
        e = theGame.GetEntityByTag(tag);
        if (e) {
            c = e.GetComponentByClassName('CStorySceneComponent');
            if (c && c.IsEnabled()) {
                c.SetEnabled(false);            // (the game turns it on again now and then: off again each time)
                if (!told) {
                    LogChannel('Cj', "owntalk|" + NameToString(tag) + "|off");
                    told = true;
                }
            }
        }
        Sleep(1.0);
    }
}

// a follow the game's way (pathfollow.py: he walks the path with the player as companion): which point he has passed
// - the progress fact (talks on the way wait for it), the pin on him; done at the path's end
// (the check of the points in a function of its own: a break out of a loop inside this latent one crashed the game,
// 03.10.)
function CjPassedPoint(pos : Vector, pts : array<Vector>, k : int) : int {
    var j, last : int;
    var near : float;
    last = pts.Size() - 1;
    j = last;
    while (j >= k) {
        near = 4.0;
        if (j == last) {
            near = 2.5;
        }
        if (VecDistance2D(pos, pts[j]) <= near) {
            return j + 1;
        }
        j -= 1;
    }
    return k;
}

latent quest function CjFollowTrack(tag : name, path : string, progress : string, pin : name) {
    var npc : CActor;
    var pts : array<Vector>;
    var k, got, n : int;
    CjWaitFor(tag);
    pts = CjPathPoints(path);
    n = pts.Size();
    k = 0;
    while (k < n) {
        npc = (CActor)theGame.GetEntityByTag(tag);
        if (npc) {
            CjPinTo(pin, npc);
            got = CjPassedPoint(npc.GetWorldPosition(), pts, k);
            if (got > k) {
                k = got;
                FactsRemove(progress);
                FactsAdd(progress, k);
                LogChannel('Cj', "follow|" + NameToString(tag) + "|point " + IntToString(k));
            }
        }
        Sleep(0.5);
    }
}

// a talk that starts when the player is near the person (wherever they stand now, else the talk's spot) - also
// when he is there already (an area waits for a step in: 03.10. he had followed the person in)
latent quest function CjWaitNear(tag : name, radius : float, x : float, y : float, z : float) {
    var e : CEntity;
    var where, p : Vector;
    var close : bool;
    close = false;
    while (!close) {
        e = theGame.GetEntityByTag(tag);
        where = Vector(x, y, z, 1);
        if (e) {
            where = e.GetWorldPosition();
        }
        p = thePlayer.GetWorldPosition();
        close = VecDistance2D(p, where) <= radius && AbsF(p.Z - where.Z) < 4.0;
        if (!close) {
            Sleep(0.3);
        }
    }
}

// a person put somewhere at once (Play from here: where an earlier step would have brought them)
latent quest function CjPutAt(tag : name, x : float, y : float, z : float, yaw : float) {
    var e : CEntity;
    e = CjWaitFor(tag);
    if (e) {
        e.TeleportWithRotation(Vector(x, y, z, 1), EulerAngles(0, yaw, 0));
    }
}
