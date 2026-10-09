// The fixer (Maxim 06.10.: the runtime stays in the game and puts right what a removed quest left). A quest made
// with Conjunction that changes the game's own world - hides one of its people, switches off an encounter, makes
// someone hostile, locks a door or a chest - does it through the *Q functions below, which note the change in the
// save with the quest's id. The quest taking its change back takes the note too. Every five seconds a note whose
// quest's DLC is no longer in the game is undone, as soon as its object is near (a person far away: when the player
// comes near). The quest's own things (their tags carry its id) are not noted: they go with its DLC.
//
// 08.10. (Maxim: every quest runs without the runtime, the runtime puts things right): a quest carries its own copy
// of the functions it calls (scriptlib.py), so a note has to live where a quest can write it and the runtime can
// read it - the facts of the save. A note is text ("<quest id>|<kind>|<tag>"), one fact per letter:
// cjfixn_<slot>_<letter> = the letter's place in CJFIX_LETTERS, cjfixn_count = the slots in use. A script makes no
// name out of text, so the runtime finds the object by its tags among those near the player.

// the notes of quests built before 08.10. (they called the runtime's own functions): read, never written any more
@addField(CR4Player)
saved var cjFixWhat : array<string>;      // "<quest id>|<kind>" - kind: presence, encounter, hostile, lock

@addField(CR4Player)
saved var cjFixTags : array<name>;        // the tag of each, at the same place

function CjFixLetters() : string {
    return "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_|-. ?";
}

function CjFixKey(slot : int, at : int) : string {
    return "cjfixn_" + IntToString(slot) + "_" + IntToString(at);
}

// the note in a slot ("" when the slot is free)
function CjFixRead(slot : int) : string {
    var letters, s : string;
    var at, code : int;
    letters = CjFixLetters();
    for (at = 0; at < 200; at += 1) {
        code = FactsQueryLatestValue(CjFixKey(slot, at));
        if (code <= 0) {
            break;
        }
        s += StrMid(letters, code - 1, 1);
    }
    return s;
}

function CjFixClear(slot : int) {
    var at : int;
    for (at = 0; at < 200; at += 1) {
        if (!FactsDoesExist(CjFixKey(slot, at))) {
            break;
        }
        FactsRemove(CjFixKey(slot, at));
    }
}

function CjFixWrite(slot : int, s : string) {
    var letters : string;
    var at, code : int;
    letters = CjFixLetters();
    CjFixClear(slot);
    for (at = 0; at < StrLen(s); at += 1) {
        code = StrFindFirst(letters, StrMid(s, at, 1)) + 1;
        if (code <= 0) {
            code = StrLen(letters);                         // (a letter outside the list: '?')
        }
        FactsSet(CjFixKey(slot, at), code);
    }
}

function CjFixNote(qid : string, kind : string, tag : name, active : bool) {
    var note : string;
    var slot, slots, free : int;
    if (StrFindFirst(NameToString(tag), qid) >= 0) {
        return;                                         // the quest's own thing
    }
    note = qid + "|" + kind + "|" + NameToString(tag);
    slots = FactsQuerySum("cjfixn_count");
    free = -1;
    for (slot = 0; slot < slots; slot += 1) {
        if (CjFixRead(slot) == note) {
            if (!active) {
                CjFixClear(slot);
            }
            return;
        }
        if (free < 0 && !FactsDoesExist(CjFixKey(slot, 0))) {
            free = slot;
        }
    }
    if (!active) {
        return;
    }
    if (free < 0) {
        free = slots;
        FactsAdd("cjfixn_count", 1, -1);
    }
    CjFixWrite(free, note);
}

// is the quest's DLC in the game (its id: dlc<quest id>; radish's dlc_<quest id> asked too)
function CjQuestInGame(qid : string, dlcs : array<name>) : bool {
    var i : int;
    var id : string;
    for (i = 0; i < dlcs.Size(); i += 1) {
        id = NameToString(dlcs[i]);
        if (id == "dlc" + qid || id == "dlc_" + qid) {
            return true;
        }
    }
    return false;
}

// one change undone, if its object is loaded -> done
function CjFixUndo(kind : string, tag : name) : bool {
    var ents : array<CEntity>;
    var box : W3LockableEntity;
    theGame.GetEntitiesByTag(tag, ents);
    if (ents.Size() == 0) {
        return false;                                   // not loaded: next time
    }
    if (kind == "presence") {
        CjPresence(tag, true);
    } else if (kind == "encounter") {
        CjEncounter(tag, true);
    } else if (kind == "hostile") {
        CjHostile(tag, false);
    } else if (kind == "lock") {
        box = (W3LockableEntity)ents[0];
        if (box) {
            box.Unlock();
        }
    }
    return true;
}

// the tag (as a name) of an object near the player whose tag reads `text`, or '' (a script makes no name of text)
function CjFixNearTag(text : string) : name {
    var near : array<CGameplayEntity>;
    var tags : array<name>;
    var i, j : int;
    FindGameplayEntitiesInRange(near, thePlayer, 150.0, 1000);
    for (i = 0; i < near.Size(); i += 1) {
        tags = near[i].GetTags();
        for (j = 0; j < tags.Size(); j += 1) {
            if (StrLower(NameToString(tags[j])) == StrLower(text)) {
                return tags[j];
            }
        }
    }
    return '';
}

// every note of a quest no longer in the game: undone when it can be -> how many were undone
function CjFixPass() : int {
    var dlcs : array<name>;
    var i, n, slot, slots : int;
    var qid, kind, note, rest : string;
    var tag : name;
    theGame.GetDLCManager().GetDLCs(dlcs);
    slots = FactsQuerySum("cjfixn_count");
    for (slot = 0; slot < slots; slot += 1) {
        note = CjFixRead(slot);
        if (note == "") {
            continue;
        }
        qid = StrBeforeFirst(note, "|");
        rest = StrAfterFirst(note, "|");
        kind = StrBeforeFirst(rest, "|");
        if (CjQuestInGame(qid, dlcs)) {
            continue;
        }
        tag = CjFixNearTag(StrAfterFirst(rest, "|"));
        if (tag != '' && CjFixUndo(kind, tag)) {
            LogChannel('Cj', "fixer|undone|" + note);
            CjFixClear(slot);
            n += 1;
        }
    }
    for (i = thePlayer.cjFixWhat.Size() - 1; i >= 0; i -= 1) {
        qid = StrBeforeFirst(thePlayer.cjFixWhat[i], "|");
        kind = StrAfterFirst(thePlayer.cjFixWhat[i], "|");
        if (CjQuestInGame(qid, dlcs)) {
            continue;
        }
        if (CjFixUndo(kind, thePlayer.cjFixTags[i])) {
            LogChannel('Cj', "fixer|undone|" + thePlayer.cjFixWhat[i] + "|" + NameToString(thePlayer.cjFixTags[i]));
            thePlayer.cjFixWhat.Erase(i);
            thePlayer.cjFixTags.Erase(i);
            n += 1;
        }
    }
    return n;
}

@wrapMethod(CR4Player)
function OnSpawned(spawnData : SEntitySpawnData) {
    wrappedMethod(spawnData);
    AddTimer('CjFixerTick', 5.0, true);
}

@addMethod(CR4Player)
timer function CjFixerTick(dt : float, id : int) {
    if (this == thePlayer) {
        CjFixPass();
    }
}

// --- what quests call: the change, and its note
quest function CjPresenceQ(qid : string, tag : name, show : bool) {
    CjPresence(tag, show);
    CjFixNote(qid, "presence", tag, !show);
}

quest function CjEncounterQ(qid : string, tag : name, enable : bool) {
    CjEncounter(tag, enable);
    CjFixNote(qid, "encounter", tag, !enable);
}

quest function CjHostileQ(qid : string, tag : name, hostile : bool) {
    CjHostile(tag, hostile);
    CjFixNote(qid, "hostile", tag, hostile);
}

// (a latent quest function cannot call another: CjLock's own body, CjLockName)
latent quest function CjLockQ(qid : string, tag : name, lock : bool, key : string, keyGoes : bool) {
    var keyName : name;
    CjFixNote(qid, "lock", tag, lock);
    if (key != "") {
        keyName = CjItemName(key);
    }
    CjLockName(tag, lock, keyName, keyGoes);
}

latent quest function CjLockNQ(qid : string, tag : name, lock : bool, keyName : name, keyGoes : bool) {
    CjFixNote(qid, "lock", tag, lock);
    CjLockName(tag, lock, keyName, keyGoes);
}
