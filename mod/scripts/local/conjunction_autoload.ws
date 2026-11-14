// conjunction: the game starts without its start videos and without the recap while a save loads.

@addField(CR4Game)
var w3sAutoloadDone : bool;

@addMethod(CR4Game)
function CjAutoloadOnce() : bool {
    // true the first time only
    if (w3sAutoloadDone) {
        return false;
    }
    w3sAutoloadDone = true;
    return true;
}

// the start videos (disclaimers, legal, logo - each skipped by its own key press) are a menu the game queues once
// at start; an empty queue opens none
@replaceMethod(CR4Game)
function PopulateMenuQueueStartupOnce(out menus : array< name >) {
}

// the recap ("the story so far", recap_wip.usm) that plays while a save loads: closed as it opens - the loading
// screen goes on without it (the idea of SkippySkippy, nexusmods 7154, without replacing the game's scripts)
@wrapMethod(CR4RecapMoviesMenu)
function OnConfigUI() {
    var result : bool;
    result = wrappedMethod();
    CloseMenu();
    return result;
}

// (the main menu stays the game's: no save is loaded by Conjunction any more - MaximdeWinter 14.11.; F8 there shows the
// projects, a project is worked on in a session of its own: ingame/lua/conjunction/ui/start_menu.lua)
