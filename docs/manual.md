# Conjunction manual

The first quest step by step: [first-quest.md](first-quest.md).

## The Conjunction panel

**F8** in the game's main menu opens it.

| page         | what it is for 
|---|---|
| **Projects** | your projects. **New project** (a Quest or a Place mod), **Open ingame**, **History**, **Add folder** 
| **Library**  | quest files (`.w3q`) to play, and the content packs in the game 
| **Settings** | General, Profile, Game (the game, REDkit and radish folders), Tools 

## Projects

A project becomes one mod. There are two kinds:

- **Quest**: steps, dialogues and a journal entry. Its NPCs and objects are in the world while the quest runs.
- **Place mod**: things that are always in the world, like a house or a camp.

A project has one or more **locations** (the **Places** tab): groups of NPCs and objects that appear and disappear
together. Every change is saved right away.

## Sessions

**Open ingame** starts the project in a session of its own, in the project's world (Velen for a new project). Saving
is deactivated during a session, so your save files don't get confused.

**File** > **Open project ...** opens another project in the running game.

## The editor

**F8** switches between editing and playing. While you edit, the game stands still. **Esc** opens the game's menu.

The bar has three modes: **Select** for the objects and NPCs you placed, **Asset Browser** for new ones, **Look** for
the camera only. **Project** opens the panel with **Places**, **Quest** and **Build**.

| key                     | what it does 
|---|---|
| right mouse button held | look around 
| W A S D, Space, X       | fly; Space up, X down 
| F held + mouse wheel    | fly speed 
| Enter                   | while placing: done 
| Shift + click           | Multi select 
| mouse wheel             | turns the selection (Shift: 1°); R held: pitch, Tab held: roll 
| End                     | drops the selection onto the ground 
| H                       | lamp on the camera; hold H and turn the wheel to dim it 
| Del, short right click  | deletes the selection 
| Ctrl+Z / Ctrl+D         | undo / duplicate 
| Ctrl+C / Ctrl+V         | copy / paste under the cursor 
| F11                     | screenshot (`Documents\Conjunction\screenshots`) 

**Edit** > **Keyboard shortcuts** changes the keys.

## Asset Browser

Every NPC, creature, object and item, sorted by category, by style and by what a thing can do. A green
speech mark: the NPC can lipsync. A red mark: it can't lipsync.

A tile with a number is a folder: "5 variants" are different people of one kind (like Soldiers), "9 looks" are one person in
different clothes. A yellow speech mark: some of them can speak. **Place random** places one of them (good for crowds).

## Quests

**Project** > **Quest** shows the quest as a graph, from **QUEST STARTS** down. There are six blocks:

- **Goal**: something the player has to do (talk, go to, collect, kill, find clues, gwent ...)
- **Action**: something the game does (a reward, a weather change, an NPC turning hostile)
- **Choice**: branches (either / or, at random, or by a condition)
- **Meanwhile**: a track alongside the story
- **Chapter**: a heading for a part of a long quest
- **End**: completed or failed

A step's info is at the bottom of the window. Missing options are highlighted in red.

- every block, card and dialogue option: [quest-graph.md](quest-graph.md)
- hide areas for your own cellar or cave: [world-changes.md](world-changes.md)
- your own voice recordings: [content-packs.md](content-packs.md)

## Testing

- **Build** > **Check** plays the quest through with a stand-in player and says where a branch gets stuck.
- **Build & Play** puts the new build into the session. The quest starts fresh, and you can test it. A project that changes the game's own quests restarts the game.
- **Play from here** (a step's **···** menu) starts the quest at that step, with the items of the steps before.

## Reporting a bug

**Help** > **Report a bug**. **Add screenshot** takes a picture of the game to draw on. **Save report** saves one file
in `bug-reports` with your text, the screenshots, the logs, the project and the installed mods. Your names and the
PC's name are taken out. The bug reports never leave your PC until you send them yourself.

**Copy for Nexus** copies a short version for the **Bugs** tab of Conjunction's Nexus page.

## Sharing quests

**Build** > **Export quest file** makes `Documents\Conjunction\exports\<quest name>\` with:

- a zip for Nexus and mod managers
- the quest file (`.w3q`) for Conjunction's Library
- a placeholder text for the quest's Nexus page

**Include the project** puts the project into the export, so others can open and change it in Conjunction.

**Mods a quest uses** are listed on the Build tab. A content pack will list itself automatically; for any other mod you type its name,
version and link once. A player who lacks one is told which mod and where to get it. How a mod becomes a content
pack: [content-creators.md](content-creators.md).

Quests made with Conjunction run side by side. If two would clash, the Library says so.

**Players** of a quest need The Witcher 3 Remastered (5.0, 5.01 or 5.01c). A quest that changes the world needs
[TW3SE](https://www.nexusmods.com/witcher3/mods/13837). The Conjunction Runtime (an optional file of Conjunction)
removes quests cleanly.

## Profiles and history

A profile is completely optional: a name and a key (Settings > Profile > **New profile**). Everything you make is signed with
it. The key is `Documents\Conjunction\identity\<name>.cjkey`. Never share it: whoever has it can sign as you.

- **History** (Projects > **History**): every step of a project, signed and chained. It shows when the history was
  manipulated. It goes into the built quest and the export.
- **Marks**: the built quest carries marks of your profile that stay when someone removes the history.
- **Check origin** (Settings > Profile): who made a quest file, a project or an installed quest.

## Folders

`Documents\Conjunction`:

| folder        | holds 
|---|---|
| `projects`    | your projects 
| `quests`     | quest files (`.w3q`) to play 
| `exports`     | exported quests 
| `bug-reports` | saved bug reports 
| `screenshots` | F11, one folder per project 
| `tools`       | the radish modding tools 
| `data`        | settings, caches and logs 
| `identity`    | profile keys 

The game folder:

| folder                                | holds
|---|---|
| `bin\x64_dx12\tw3se\mods\conjunction` | the editor 
| `bin\x64_dx12\tw3se\plugins`          | cj_core.dll, cj_qt.dll and Qt (`cj_qt`) 
| `Mods\modConjunction`                 | the editor's scripts 
| `Mods\modConjunctionRuntime`          | the scripts every quest made with Conjunction calls 
| `Mods\modConjunctionSessions`         | the sessions 
| `dlc\dlcconjunctiontexts`             | texts for scenes 
