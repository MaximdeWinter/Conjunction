// conjunction: what the player is shown, in the script log (channel W3S) - a test reads what was really said and
// offered instead of looking at pictures (Maxim 03.10.: "can you read whether he really said it, with subtitles?")

// every subtitle: a scene's line, a line said while the game goes on, a one-liner in passing
@wrapMethod(CR4HudModuleSubtitles)
function OnSubtitleAdded(id : int, speakerNameDisplayText : string, htmlString : string, alternativeUI : bool) {
    CjOut("subtitle|" + speakerNameDisplayText + "|" + htmlString);
    return wrappedMethod(id, speakerNameDisplayText, htmlString, alternativeUI);
}

// the line of a talk on the screen (with subtitles off too)
@wrapMethod(CR4HudModuleDialog)
function OnDialogSentenceSet(text : string, optional alternativeUI : bool) {
    CjOut("sentence|" + text);
    wrappedMethod(text, alternativeUI);
}

// the answers offered, and the one taken
@wrapMethod(CR4HudModuleDialog)
function OnDialogChoicesSet(choices : array<SSceneChoice>, alternativeUI : bool) {
    var i : int;
    var line : string;
    line = "choices";
    for (i = 0; i < choices.Size(); i += 1) {
        line += "|" + choices[i].description;
    }
    CjOut(line);
    wrappedMethod(choices, alternativeUI);
}

@wrapMethod(CR4HudModuleDialog)
function OnDialogOptionAccepted(index : int) {
    CjOut("chosen|" + IntToString(index));
    return wrappedMethod(index);
}
