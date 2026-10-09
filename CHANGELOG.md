# Changelog

## 0.1.0 (October 2026)

First release.

**The editor in the game**
- F8 switches between editing and playing. Fly freely and place anything of the game (about 19 000 templates and
  11 000 meshes) with a mouse click. Move, turn, duplicate, copy, undo
- The Asset Browser: every NPC, creature, object and item of your game, sorted and searchable. A green speech mark
  shows the NPCs that can speak in a dialogue
- Placed things are put onto the ground before Build & Play

**Quests**
- A quest is a graph: goals, actions, choices, parallel tracks, chapters and ends
- Goals: talk, deliver, follow, go to, wait, loot, examine, use, collect, equip, read, notice boards, find clues, kill,
  defeat, fist fight, gwent, race, all of these
- Actions: rewards, items, teleport, travel, play as Ciri, portals, hostile NPCs, walking and patrols, doors, lights,
  weather, time of day, journal notes, the game's own quest functions and more
- Choices: either / or, at random, if (by an earlier branch, a fact, an area, an item, a game quest's state, the time
  of day, someone there, a fight)
- A quest starts right away, together with a quest of the game, or after one (the story map shows every quest of the
  game on a timeline)
- Several quests in one project
- Your own items: rename an item of the game and it is a new item of your quest

**Dialogues**
- Lines, choices and conditions, with the game's voices, your own recordings or a mouth that moves to the text
- Gestures, moods, cameras, poses and extras per line
- Options that pay, persuade with Axii, hand over or receive an item, or open a shop

**Testing**
- Check plays the quest through with a stand-in player and says where a branch would get stuck
- Build & Play builds the quest and starts it in the game with your save
- Play from here starts the quest at any step

**Sharing**
- Export makes a zip for Nexus and mod managers, a quest file for Conjunction's Library and the text for the quest's
  Nexus page
- Every quest carries what it needs and runs on its own. The Conjunction Runtime is recommended: it puts the world
  back as it was when a quest is removed
- Content packs: any mod with furniture, items or people becomes a content pack with one click. Quests name the mods
  they take things from, and players who lack one are told which mod and where to get it
- Furniture from FBX files, decals from pictures and items from a short list, built into a content pack

**The game's own world** (with [TW3SE](https://www.nexusmods.com/witcher3/mods/13837))
- Remove, move, relight or re-skin objects the game placed, for the whole quest or between two of its steps
- Hide areas: grass, ground or water hidden inside an outline you draw

**The app**
- Projects, Library, Settings and plug-in pages in one window
- Profiles (optional): sign what you make, with a history of every step of a project
- Updates: Conjunction asks Nexus Mods for newer versions of itself, TW3SE, the Runtime and content packs
- Report a bug: one file with your text, screenshots and the logs, to attach on Nexus
