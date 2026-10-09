// conjunction: the game starts straight into the last save - no start videos, no main menu, no recap.
// Once a start: back in the main menu later (quit to menu) it stays the menu.

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

// the main menu, the first time it opens: what Continue does
@wrapMethod(CR4IngameMenu)
function OnConfigUI() {
    var saves : array< SSavegameInfo >;
    var result : bool;
    result = wrappedMethod();
    if (!isMainMenu || !theGame.CjAutoloadOnce()) {
        return result;
    }
    theGame.ListSavedGames(saves);
    if (saves.Size() > 0) {
        CjOut("autoload: the last save");
        SetIgnoreInput(true);
        theGame.LoadLastGameInit();
    }
    return result;
}
