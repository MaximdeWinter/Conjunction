"""Tooltips of the whole suite: one look and one registry of texts. A tooltip says only what cannot be seen - a key,
a consequence, what the game does - in one short, plain line. Every control has one.

    from .tooltips import tip
    tip(button, "mode.look")                   # the line from TIPS
    tip(button, title="Ruby", text="...")      # made on the spot (catalog entries, plugins): a title and a text

Qt only shows tooltips of the active window; Conjunction's windows are never active (the game would pause), so the
tooltip is drawn by Conjunction itself: an app-wide filter catches Qt's tooltip event of any widget that has one.
"""
from PySide6 import QtCore, QtGui, QtWidgets

TIPS = {
    # Rules (VORSCHLAG.md, Maxim 01.10.): what it does, in one short sentence; never the label again; the player,
    # not Geralt; no "you"; no long dash. An icon button: its label (one or two words). A shortcut only when it does
    # the same as the control. Glossary: Player, NPC, creature, dialogue, monologue, line, choice, option, condition,
    # fact, branch, parallel track, step, objective, location, object, track, continue, fail, remove, delete.
    # --- the bar
    "mode.look": "Free view. Fly around without interacting with anything",
    "mode.select": "Select objects to change their position and properties",
    "mode.place": "Opens the Asset Browser to place objects in the world",
    "mode.terrain": "Shapes the ground with a brush (visible after Build & Play)",
    # --- the terrain brush (Terrain mode)
    "terrain.raise": "Raises the ground. Hold Shift to lower it",
    "terrain.lower": "Lowers the ground. Hold Shift to raise it",
    "terrain.smooth": "Smooths bumps and edges. Hold Ctrl with any tool to smooth",
    "terrain.flatten": "Pulls the ground towards one height with each stroke",
    "terrain.set": "Sets the ground to an exact height",
    "terrain.ramp": "A straight slope. Press at the start, release at the end (brush size = width)",
    "terrain.noise": "Rough, natural ground",
    "terrain.terrace": "Steps of a fixed height",
    "terrain.size": "Brush size. Mouse wheel changes it",
    "terrain.smaller": "Smaller brush",
    "terrain.bigger": "Bigger brush",
    "terrain.strength": "Strength of one stroke. Shift and mouse wheel change it",
    "terrain.weaker": "Weaker",
    "terrain.stronger": "Stronger",
    "terrain.edge_smooth": "The effect fades softly towards the edge",
    "terrain.edge_linear": "The effect fades evenly towards the edge",
    "terrain.edge_hard": "Full effect up to the edge",
    "terrain.circle": "Round brush",
    "terrain.square": "Square brush",
    "terrain.height": "Target height: where the stroke starts, or the height under the cursor",
    "terrain.extra": "Terrace: step height. Roughen: size of the bumps",
    "terrain.extra_less": "Less",
    "terrain.extra_more": "More",
    "terrain.painted": "Strokes saved in the project for this world",
    "terrain.undo": "Undoes the last stroke (Ctrl+Z)",
    "terrain.reset": "Removes all strokes in this world",
    "opt.edit_existing": "Manipulate the existing objects of the game (Caution: may lead to incompatible mods)",
    "opt.collision": "Enables collision (dragged objects stop at the boundaries of the environment)",
    "opt.snap": "Moved objects always sit on what is below them (the ground or an object)",
    "opt.grid": "Snaps objects to a grid (off, 0.1, 0.25, 0.5, 1, 2 m).",
    "opt.turn": "Rotation per mouse wheel step (1, 5, 10, 15, 45, 90°)",
    "opt.align": "New objects align with the ground below",
    "opt.random": "Gives every new object a random rotation",
    "opt.light": "Time of day while editing (morning, noon, evening, night)",
    "opt.music": "Game music while editing",
    "opt.sound": "Game sound while editing",
    "opt.lamp": "Flashlight on the camera. Hold H and turn the mouse wheel to dim it",
    "opt.markers": "Shows a ring and the name of objects, also through walls (off, quest, all)",
    "opt.senses": "Witcher senses view (clues red, interactive objects highlighted)",
    "opt.speed": "Hold the key and turn the mouse wheel to change the fly speed",
    "bar.speed": "Fly speed. Hold F and turn the mouse wheel to change it",
    "opt.catalog_screen": "Shows the Asset Browser over the game or on a second screen",
    "cat.nav": "Shows the categories. Docked narrow at a side, they fold away by themselves",
    "cat.view": "How assets are shown (icons, list, details, tiles). Ctrl and mouse wheel switch it",
    "cat.sort": "Sort",
    "act.player_here": "Places the player on the ground under the camera",
    "act.panel": "Opens the project: assets, places, the quest, the build",
    "act.build_play": "Builds the project and starts it in the game",
    "act.info": "The quest and location being edited",
    "bar.settings": "Settings",
    "bar.logo": "Conjunction",
    "bar.project": "The current project. Click to rename it, start a new one or open another",
    "menu.file": "New, open, rename and export projects",
    "menu.edit": "Undo, copy, duplicate, delete, keyboard shortcuts.",
    "menu.view": "Windows, markers, light and sound",
    "menu.build": "Build and play, check, export and the libraries",
    "menu.help": "Keyboard shortcuts and bug reports",
    "act.outliner": "Opens the project's locations and their objects",
    "act.story": "The story map. Shows every quest in chronological order",
    "story.search": "Finds quests by title or code (q103, sq303)",
    "story.chip_kind": "Shows or hides this kind of quest. Contracts and treasure hunts start at a notice board "
                       "or a note, so they hang on no other quest",
    "story.chip_game": "Shows or hides the quests of the base game or an expansion",
    "story.fit": "Zooms out to show the whole map",
    "story.graph": "Opens the graph of this quest (every block of the game's quest)",
    "story.starts": "Where a fresh game can start for this quest (CDPR's test starts, else the story's parts)",
    "story.play": "Starts a fresh game there without a save. The running game is quick saved first",
    "story.world_only": "Starts a fresh game in a world without story (a neutral place to build in)",
    "vg.search": "Finds blocks by title, text or name (fact, scene, function)",
    "vg.fit": "Zooms out to show the whole graph",
    "vg.open": "Opens a quest file of the game by its name or file name",
    "vg.handbook": "Every kind of block: what it does and where the game's quests use it",
    "vg.templates": "Shows blocks that are wired like a template as one block. Double click to see its blocks "
                    "(view only, the file stays unchanged)",
    "vg.follow": "With Live on, the graph jumps to the phase the game is running",
    "vg.live": "Lights up the blocks the running game activates (needs the game and TW3SE)",
    "vg.undo": "Undoes the last change",
    "vg.redo": "Redoes the undone change",
    "vg.save": "Keeps the changed file in the project. The build puts it into the project's mod",
    "vg.revert": "Returns to the game's own file",
    "story.fact": "The fact of the chosen quest that this project's quest waits for",
    "story.hook": "This project's quest starts once this quest is over (used from the next build)",
    "story.hook_with": "This project's quest starts as soon as this quest starts (used from the next build)",
    "act.drop": "Drops the selected object onto the ground below",
    "act.play": "Play the game as the player. Press Esc to return to the editor",
    "bar.play_menu": "What the play button does: Play, or Build & Play",
    "act.duplicate": "Places a copy of the selected object",
    "act.delete": "Removes the selected object",
    "bar.bug": "Report a bug",
    "bar.where": "The location being edited and its world",
    "bar.quest": "The quest of this project",
    "bar.doing": "What the next click in the world does",
    # --- library
    "lib.folder": "Opens the folder for quest files (.w3q)",
    "lib.refresh": "Checks for new and deleted quest files",
    "lib.play": "Starts The Witcher 3 with all installed quests",
    "lib.get": "Opens the mod's download page",
    "lib.page": "Opens the pack's page",
    # --- the app: projects, settings, the first start
    "app.bug": "Saves a bug report as one file (attach it on Nexus or send it on Discord)",
    "proj.open": "Starts the game with the editor in the chosen project",
    "proj.name": "Name of the new project",
    "proj.new": "Creates a project: a quest or a place mod",
    "proj.folder": "Adds a project from its folder",
    "set.general.sound_off": "Mutes the game while the editor is open",
    "set.general.check_updates": "At the start: asks Nexus Mods whether Conjunction, TW3SE, the runtime or a content "
                                 "pack has a newer version. Shows it with a link to its page (nothing is downloaded "
                                 "by itself)",
    "set.general.experimental": "Terrain editing and editing the game's quests (Caution: not tested enough, can "
                                "break the game and saves)",
    "set.game.folder": "The folder of The Witcher 3 (the one with bin and content)",
    "set.game.redkit": "The REDkit folder. Used to cook and pack quests",
    "set.game.radish": "The folder of the radish tools. Used to encode quests",
    "set.tools.blender": "blender.exe. Plug-ins open models and animations with it",
    "set.plugins.readme": "What the plug-in does",
    "set.plugins.folder": "Opens Conjunction's plug-ins folder (one folder per plug-in)",
    "set.profile.choice": "The profile that signs what is made from now on",
    "set.profile.name": "Shown in the history (the key stays the same)",
    "set.profile.show": "Opens the folder with the key file (copy it to a new PC, never post it)",
    "set.profile.new": "A second profile with a key of its own (nothing links the two)",
    "set.profile.add": "A key file from another PC (the same profile there and here)",
    "set.profile.check": "Who made a quest file, project or built quest, and whether a profile of this PC marked it",
    "set.profile.how": "What a profile is, what is signed, the key file, staying anonymous",
    "set.profile.timestamp": "On export, sends only a fingerprint of the history to opentimestamps.org (proves when "
                             "the quest existed, nothing else leaves the PC)",
    "origin.file": "A quest file (.w3q) or a bundle",
    "origin.folder": "A project or a built or installed quest",
    "proj.history": "Who made and changed the project, with which tools (signed when a profile is chosen)",
    "proj.search": "Shows only projects whose name or quests have these words",
    "set.plugins.on": "Turns the plug-in on or off (the app at once, the editor in the game at next start)",
    "set.pick_folder": "Choose a folder",
    "set.pick_file": "Choose a file",
    "lib.packs": "Turns a mod with furniture, items or people into a content pack for quests",
    "pack.pick": "A mod folder of the game",
    "pack.folder": "A mod folder anywhere on the disk",
    "pack.name": "Shown to players when a quest needs this mod",
    "pack.version": "Quests made with this version need it or a newer one",
    "pack.author": "Shown next to the name",
    "pack.url": "Where players get the mod when a quest needs it",
    "pack.description": "One line about what the mod adds",
    "pack.write": "Writes the pack card and the table of contents into the mod folder",
    "pack.fbx": "Creates a pack of new furniture from a folder of FBX files and textures",
    "exp.mod_name": "Shown to players when the quest needs this mod",
    "exp.mod_url": "Where players get the mod",
    "exp.mod_version": "The version the quest was made with",
    "pan.places": "The project's locations and objects. Double click to jump there",
    "pan.new_place": "Name of a new location. Its objects are shown and hidden together",
    "pan.export": "Saves the quest as a file to share (.w3q)",
    "pan.export_source": "Puts the whole project into the file (all quests, placed objects, changed objects)",
    # --- bug report
    "bug.text_field": "What happened and what should have happened",
    "bug.screenshot": "Adds a screenshot of the game to draw on",
    "bug.send": "Saves the report as one file (logs, project, system info)",
    "bug.folder": "Shows the saved report in Explorer",
    "bug.copy": "Copies a short report for the Bugs tab on Nexus (it takes text only)",
    "bug.remove": "Remove",
    "bug.pen": "Pen",
    "bug.arrow": "Arrow",
    "bug.box": "Box",
    "bug.text": "Text",
    "bug.colour": "Colour",
    "bug.undo": "Undo",
    # --- the bar's settings
    "set.pin": "Gold: shown in the bar",
    "set.key": "Click, then press a key. Esc clears the key",
    "set.layout": "Drag the buttons into another order. Click again when done",
    # --- catalog
    "cat.search": "Searches the catalog by name, type and style",
    "cat.tab.objects": "Objects to place in the world",
    "cat.tab.items": "Items for inventories, rewards and quest steps",
    "cat.tab.favourites": "Starred objects and items",
    "cat.tab.recent": "Recently placed objects",
    "cat.tree": "Filters the catalog by type (counts include the other filters)",
    "cat.style": "Shows only this style. Right click adds it to the others",
    "cat.trait": "Shows only objects with this trait. Right click adds it to the others",
    "cat.quest": "Includes objects made for the game's own quests",
    "cat.crumb": "Up one level",
    # --- inspector
    "ins.place": "Picks it up for placing",
    "ins.fav": "Favourite",
    "ins.copy": "Copy path",
    "ins.apply": "Moves it to these coordinates",
    "ins.remove_item": "Remove",
    "ins.count": "One more or one less",
    "ins.picture3d": "Shows it in 3D",
    "qb.worldchange": "A change made in the editor to an object the game placed",
    "qb.worldchange_state": "The change holds from this step on, or ends here",
    "world.remove": "Removes it from the world for everyone who has the quest",
    "world.effect_on": "Plays the effect on it whenever it is in the world",
    "world.effect_off": "Stops the effect",
    "world.look": "Gives it another of its appearances",
    "world.drop": "Drops this change. The object is back as the game made it from the next load",
    "ins.look_step": "Steps through the appearances the game picks from when spawning it",
    "ins.view3d": "Drag to rotate, mouse wheel to zoom",
    # --- inspector: the selected object
    "obj.name": "The name quest steps use for it",
    "obj.does": "What the NPC does at this spot",
    "obj.display": "Name shown above the NPC in the game. If left empty, the game's own name",
    "obj.look": "Changes the appearance",
    "obj.add_item": "Adds an item to its inventory (an NPC drops it when killed)",
    # --- look window
    "look.tiles": "Click to enlarge. Double click to use",
    "look.use": "Uses this appearance",
    # --- quest board
    "qb.title": "The quest's name in the journal.",
    "qb.type": "The journal section the quest is listed in",
    "qb.description": "The quest's text in the journal",
    "qb.objective": "The objective in the journal. If left empty, it is made from the step",
    "qb.projects": "This project's quests (they share its people and places) and other projects. The game stays "
                   "open",
    "qb.level": "Suggested level in the journal",
    "qb.after": "When the quest starts: at once, together with a quest of the game, or once one is over (picked in the story map)",
    "qb.quest_start": "When the quest appears in the journal",
    "qb.plays_as": "Player character at quest start",
    "qb.alive_add": "The quest fails if this NPC dies",
    "qb.alive_remove": "Remove",
    "qb.ends_game": "Ends the quest when one of the game's quests reaches this point",
    "qb.ends_game_remove": "Remove",
    "qb.own_add": "Adds an item that only exists in this quest",
    "qb.waitfor": "What the step waits for in the game",
    "dlg.also": "Something that happens at the same time as the line",
    "dlg.mark": "A spot of this talk. A line can put its speaker there (Extras)",
    "dlg.add_mark": "Adds a spot where the player stands now. Lines can put people there",
    "dlg.prop": "A thing of this talk, on one of its spots. A line can show or hide it (Extras)",
    "dlg.also_sound": "A sound of the game, played with the line",
    "dlg.also_hold": "An item the speaker takes into the right hand",
    "dlg.also_appearance": "The speaker's appearance from this line on",
    "qb.waitfor_percent": "Share of the player's health at which the step is done",
    "qb.own_name": "Name in the inventory",
    "qb.own_text": "If left empty, a plain quest item. With text, a readable item",
    "qb.jump_to": "Shows a chapter or branch in the graph",
    "qb.chapter_journal": "Added to the quest's journal entry from this chapter on",
    "qb.chapter_journal_mode": "Add: below the journal text so far. Replace: in place of it",
    "qb.talk_line": "Spoken text (the speaker is shown before it)",
    "qb.talk_line_remove": "Remove",
    "qb.talk_answer": "Option text",
    "qb.talk_answer_end": "Where the quest continues after this option",
    "qb.talk_answer_remove": "Remove",
    "qb.talk_add_line": "Adds a line by the other speaker",
    "qb.talk_add_answer": "Adds an option to the choice",
    "qb.talk_add_reply": "Adds a line after this option",
    "qb.talk_who": "Speaker. Click to switch",
    "blk.goal": "A step the player has to complete (comes with an objective)",
    "blk.action": "Happens automatically",
    "blk.choice": "Splits the quest (either / or, at random, or by a condition)",
    "blk.parallel": "Steps that run alongside the story",
    "blk.chapter": "A heading for a part of the quest",
    "blk.end": "Ends the quest with success or failure",
    "dblk.line": "A spoken line",
    "dblk.choice": "The player picks an option. Each option has its own branch",
    "dblk.if": "Two branches, decided by a condition",
    "qb.end_success": "Ends the quest as completed",
    "qb.end_fail": "Ends the quest as failed",
    "qb.if_by_path": "Decides by a branch taken earlier in this quest",
    "qb.if_by_fact": "Decides by a fact",
    "qb.if_path": "Taken earlier: yes. Otherwise: no",
    "qb.repeat": "Every time: the goal repeats. Its output 'every time' runs each time it is done, the story "
                 "goes on once (arriving again needs leaving first, a fact is waited for again, a talk can start "
                 "again)",
    "qb.again_greet": "What the NPC says when talked to again, before the questions (optional)",
    "qb.again_ask": "A question of this talk that may be asked again (its text and what follows)",
    "qb.again_own": "An own question for the times after the first, asked by the player",
    "qb.again_add": "Adds the question and its answer to what may be asked again",
    "qb.again_remove": "This question is no longer asked again",
    "qb.repeat_until": "When the repeating stops (with the quest, when a fact is set or when the story reaches a "
                       "step)",
    "qb.repeat_fact": "The repeating stops when this fact is set",
    "qb.repeat_node": "The repeating stops when the story reaches this step",
    "qb.race_add": "Adds another racer (an NPC of a location)",
    "qb.race_remove": "This racer does not run",
    "qb.race_pace": "How fast the racers run (easy, normal, hard)",
    "qb.weapon": "The weapon the player draws or sheathes",
    "qb.controls_how": "Blocks what the player can do, or unblocks it again",
    "qb.controls_what": "What is blocked (everything, or only these)",
    "qb.timelapse": "The text on the black screen",
    "qb.highlight": "How the witcher senses show it",
    "qb.target_stop": "They stop attacking this target",
    "qb.notalk_again": "They can be talked to again",
    "qb.look_name": "The appearance of their template, by name",
    "qb.shop_off": "The merchant stops trading",
    "qb.bossbar_off": "Hides the health bar again",
    "qb.cond_add": "Adds another condition (fact, branch, player in an area, item, quest state, time of day, "
                   "someone there, fight)",
    "qb.cond_kind": "What this condition checks",
    "qb.cond_not": "Reverses the condition (it holds when this does not)",
    "qb.cond_remove": "Removes this condition",
    "qb.cond_all": "All conditions must hold",
    "qb.cond_any": "One condition is enough",
    "qb.cond_time": "Time of day as hh:mm (22:00 to 04:00 runs past midnight)",
    "qb.cond_quest": "A quest or objective of the game. Type a part of its name",
    "qb.cond_state": "Running, done or failed",
    "qb.if_fact": "Fact to check (steps and options set facts)",
    "qb.if_op": "Comparison",
    "qb.if_value": "Value to compare with",
    "step.if": "Two branches, decided by an earlier branch or a fact",
    "step.end": "Ends the quest",
    "qb.remove": "Remove",
    "qb.remove_action": "Remove",
    "qb.cancel": "Close",
    "qb.step_kind": "Changes the step type",
    "qb.card_menu": "More",
    "qb.more": "Shows more options",
    "qb.live": "Where the player is in this quest right now",
    "qb.missing": "Required before the quest can be built",
    "qb.test_from": "Builds a test that starts the quest at this step",
    "qb.target": "The NPC, creature or object this step uses",
    "qb.pick_people": "Click an NPC in the world. Esc cancels",
    "qb.pick_creatures": "Click a creature in the world. Esc cancels",
    "qb.pick_things": "Click an object in the world. Esc cancels",
    "qb.pick_loot": "Click what the player loots in the world. Esc cancels",
    "qb.pick_clues": "Click a clue in the world. Esc cancels",
    "qb.pick_containers": "Click a container in the world. Esc cancels",
    "qb.create_people": "Places a new NPC for this step",
    "qb.create_creatures": "Places a new creature for this step",
    "qb.create_things": "Places a new object for this step",
    "qb.create_loot": "Places a new container or body for this step",
    "qb.create_clues": "Places a new clue for this step",
    "qb.create_containers": "Places a new container for this step",
    "qb.search": "All placed objects of this type",
    "qb.search_name": "Filters the list",
    "qb.take": "Uses this object for the step",
    "qb.jump": "Moves the camera to it",
    "qb.mouth": "Lip sync (only some appearances have a face rig)",
    "qb.talking_look": "Switches to an appearance with lip sync",
    "qb.chooser_take": "Picks it up for placing. The quest stays open",
    "qb.chooser_back": "Back",
    "qb.edit_dialogue": "Opens the dialogue editor",
    "qb.place": "Uses this location",
    "qb.spot": "Marks the destination (only visible while editing)",
    "qb.path_clear": "Removes the whole way",
    "qb.path_add": "Draws the way in the world (click adds a point, click on a point moves it, right click "
                   "removes it)",
    "qb.goto_mode": "Arrive at a spot, leave it, come near an NPC wherever they are, or look at someone for a while",
    "qb.radius": "Distance at which the step completes",
    "qb.name_person": "Shown above the person in the game. The quest's steps, dialogues and journal use it too",
    "qb.name_thing": "The object's name in the quest's steps and dialogues",
    "qb.map_mark": "Map marker (a search circle or a pin on the exact spot)",
    "qb.map_radius": "Size of the circle on the map",
    "qb.when": "Arrival only counts at this time of day. Before that, the player waits there",
    "qb.stay": "The quest fails if the player leaves too early",
    "qb.loot_take": "If left empty, opening is enough. With an item, taking it completes the step",
    "qb.use_how": "When the step completes (a used item is consumed)",
    "qb.switch_state": "New state",
    "qb.follow_lead": "Who walks ahead",
    "qb.follow_run": "Walk or run",
    "qb.path_point": "Click to remove the point. The last one is the destination",
    "qb.walk_to": "Click the destination in the world",
    "qb.walk_wait": "The quest waits until they arrive",
    "qb.tut_title": "Heading of the hint box",
    "qb.tut_text": "<<Focus>>, <<Jump>>, <<Attack>> and similar show the icon of that key",
    "qb.clues_order": "Each clue only appears after the previous one was examined",
    "qb.trail_add": "Adds a track from the library, drawn in the world",
    "qb.clue_add": "Adds something to examine (any object, a body, a clue)",
    "qb.clue_swap": "Replaces it with a clue of the same kind at the same spot",
    "qb.clue_how": "Animation the player plays when examining",
    "qb.clue_after": "Comment: a line during play. Monologue: a dialogue with options",
    "qb.clue_talk": "Opens the monologue in the dialogue editor",
    "qb.trail_draw": "Click points in the world, Enter to finish (the track follows the ground)",
    "qb.time": "Game time",
    "qb.time_at": "The next time the clock shows this",
    "qb.wait_mode": "A duration of game time, or until a time of day",
    "qb.count": "Required amount",
    "qb.item": "Chooses the item",
    "qb.item_from": "Where the player gets the item",
    "qb.item_way": "Gives or takes the item",
    "qb.more_items": "Adds another item (all are required)",
    "qb.reward_items": "Adds an item to the reward",
    "qb.kill_add": "Adds a target. The step completes when all are dead",
    "qb.kill_group": "Places a group of one creature type (all must die)",
    "qb.immortal_mode": "How they survive",
    "qb.door_state": "New door state",
    "qb.door_key": "Item required to open it",
    "qb.lock_state": "Locks or unlocks it (At the start: locked from the beginning)",
    "qb.lock_key_goes": "Opening it removes the key from the inventory",
    "qb.fade": "To black or back",
    "qb.fade_color": "The colour the screen fades to",
    "qb.lights_state": "Lights on or off",
    "qb.encounters_point": "Click the middle of the area. Creatures within the radius count",
    "qb.more_targets": "Adds another object. The step does the same to each",
    "qb.lights_slow": "The light fades in or out slowly",
    "qb.presence_state": "Hidden: not drawn, no collision, no interaction. Shown brings it back",
    "qb.encounters_state": "The game's own creatures around this point (stopped and removed, or back on)",
    "qb.weather": "New weather",
    "qb.teleport_here": "Click the destination in the world",
    "qb.travel_here": "Travel to that region first, then click the arrival point",
    "qb.point": "Click in the world",
    "qb.playas_who": "Player character from here on",
    "qb.playas_look": "Ciri's appearance",
    "qb.playas_at": "Click the start point in the world. If left empty, where the player stands",
    "qb.playas_here": "Clears the start point (starts where the player stands)",
    "qb.game_fn": "One of the game's quest functions. Type a part of its name",
    "qb.game_enum": "One of the values the game allows here",
    "qb.wait_fact": "The quest continues once this fact is set",
    "qb.wait_moment": "Waits for a point in one of the game's quests",
    "qb.stands_where": "Click the new position in the world",
    "qb.stands_does": "What they do there",
    "qb.meanwhile": "The parallel track that starts here",
    "qb.lane_end": "The track stops at its end. The story never waits for it",
    "qb.stop_lane": "Parallel track to stop",
    "qb.stop_early": "Comes before its track starts, so it stops nothing. Move it below the start of the track",
    "qb.random_way": "Where this outcome leads",
    "qb.random_remove": "Remove",
    "qb.random_add": "Adds an outcome (all are equally likely)",
    "cat.filters": "Shows the filters (region, style, what it can do)",
    "cast.step": "Opens the card of this step",
    "cast.go": "Jumps there",
    "qb.eye": "Shows its ways and circles in the world. Off: only while this card is open",
    "qb.either_way_add": "Adds a way. Wire a goal to each, the first one done wins",
    "qb.gwent_deck": "Opponent's deck",
    "qb.gwent_hard": "Opponent's skill",
    "qb.gwent_lost": "What happens if the player loses",
    "qb.fistfight_add": "Adds an opponent to the same fight",
    "qb.chapter_title": "Only shown in the editor",
    "qb.chapter_menu": "More",
    "qb.path_name": "Only shown in the editor",
    "qb.path_remove": "Remove",
    "qb.path_then": "What happens at the end of the branch",
    "qb.either_kind": "Option type. The first option completed decides the branch",
    "qb.either_path": "Where this option leads",
    "qb.either_add": "Adds an option",
    "qb.all_add": "Adds a goal (any order)",
    "qb.friendly": "Ends the fight. Off: starts it",
    "qb.say_who": "Speaker",
    "qb.say_gesture": "Gesture while speaking",
    "qb.say_mood": "Facial expression while speaking",
    "qb.says_text": "If left empty, gesture only",
    "qb.says": "Spoken by the player character. If left empty, nothing",
    "qb.says_voice": "A voiced line of the player character",
    "qb.talk_start": "How the dialogue starts (on E, when the player is near, overheard while walking, by an NPC "
                     "call-out, or as a cutscene)",
    "qb.talk_radius": "Distance for the start",
    "qb.talk_call": "Line the NPC calls out. The game continues meanwhile",
    "qb.portrait": "Picture in the journal",
    "qb.person_main": "Lists them with the main characters",
    "qb.add_swap": "Replaces one of the game's dialogues (Caution: may break saves made inside this quest)",
    "qb.swap_remove": "Remove",
    "qb.swap_saves": "Saves made inside this game quest may still expect the original dialogue",
    "qb.swap_edit": "The replacement dialogue",
    "qb.swap_then": "Where the game's quest continues after this dialogue",
    "qb.add_cutscene": "Replaces one of the game's cutscenes wherever it plays (Caution: may lead to "
                       "incompatible mods)",
    "qb.cutscene_old": "The game's cutscene to replace",
    "qb.cutscene_new": "The cutscene that plays instead",
    "qb.cutscene_file": "Plays a custom cutscene file instead",
    "qb.cutscene_remove": "Remove",
    "qb.cutscene_people": "The new cutscene has characters the scene lacks. They stay empty",
    # --- the steps and actions to add
    "step.goto": "The player has to reach a location",
    "step.talk": "The player has to talk to an NPC",
    "step.loot": "The player has to search a container",
    "step.examine": "The player has to examine an object",
    "step.use": "The player has to use an object",
    "step.kill": "The player has to kill one or more targets",
    "step.defeat": "A fight until the opponent yields (Nobody dies)",
    "step.gwent": "A game of gwent. Winning continues the quest",
    "step.fistfight": "A fist fight. Winning continues the quest",
    "step.deliver": "A dialogue in which the player has to hand over an item",
    "step.equip": "The player has to equip one or more items",
    "step.read": "The player has to read a letter or book",
    "step.collect": "The player has to get an item (completes as soon as it is in the inventory)",
    "step.clues": "The player has to find clues with the witcher senses",
    "step.follow": "The player has to follow an NPC or lead them",
    "step.wait": "Game time passes",
    "step.waitfact": "Waits until a fact is set",
    "step.either": "Several options. The first one completed decides the branch",
    "step.all": "Several goals. Completes when all are done",
    "step.chapter": "A heading for a part of the quest",
    "step.say": "A subtitled line. The game continues",
    "step.show": "A location appears",
    "step.hide": "A location disappears",
    "step.reward": "Crowns, experience and items",
    "step.item": "The player gets or loses an item",
    "step.note": "A paragraph in the quest's journal entry",
    "step.hostile": "An NPC attacks the player",
    "step.immortal": "An NPC cannot die, or is only knocked out",
    "step.door": "Opens, closes or locks a door",
    "step.switch": "Turns a lever, fire or lamp on or off",
    "step.lock": "Locks or unlocks an object",
    "step.effect": "Turns fire, smoke or glow of an object on or off",
    "step.sound": "Plays a sound",
    "step.fade": "Fades the screen to black, white or back",
    "step.lights": "Turns candles, torches and lamps on or off",
    "step.presence": "Hides an NPC or object from the world, or shows it again",
    "step.encounters": "Turns the game's own creatures in an area off or on (wolves, drowners)",
    "step.shake": "Shakes the camera",
    "step.weather": "Changes the weather",
    "step.time": "Sets the time of day",
    "step.portal": "A portal that takes the player to a point (two-way if wanted). Stays open from here on",
    "qb.portal_point": "Click the point where the player arrives",
    "qb.portal_two_way": "Back too: a second portal leads back to a point near the first",
    "qb.portal_white": "The screen fades to white in between, like a mage's portal. Off: black",
    "qb.portal_effect": "The effect the portal plays while open",
    "step.teleport": "Moves the player to a point",
    "step.travel": "Moves the player to another region (with a loading screen)",
    "step.playas": "Switches the player character from here on",
    "step.message": "Shows a line on screen",
    "step.autosave": "Saves the game",
    "step.person": "A page in the journal's characters",
    "step.walk": "An NPC walks or runs to a point",
    "step.patrol": "An NPC walks a round between points",
    "step.stands": "An NPC stands elsewhere from now on (also after loading)",
    "step.meanwhile": "Starts a parallel track of steps alongside the story",
    "step.stop": "Stops a parallel track",
    "step.random": "One of several outcomes, picked at random",
    "step.tutorial": "A hint box with key icons",
    "step.game": "One of the game's quest functions",
    "step.fact": "Sets a fact that other steps and options can check",
    # --- game quest windows
    "gq.search": "Searches the game's quests by name or by a word of the point",
    "gq.take": "The quest starts once the game's quest reaches this point (the game's quest stays unchanged)",
    "gs.search": "Searches the game's dialogues by quest or scene name",
    "gs.take": "Uses this dialogue. Its text is rewritten, the game's quest continues as before",
    "gp.search": "Searches the game's quests by name",
    "gp.find": "Filters the points by scene, fact or function",
    "gp.take": "The quest runs right after this point. The game's quest waits for it",
    "gp.saves": "Saves made inside this game quest may no longer fit",
    # --- dialogue
    "dlg.back": "Back",
    "dlg.who": "Speaker",
    "dlg.text": "Enter: next line by the other speaker. Enter on an empty line: done.",
    "dlg.remove": "Remove",
    "dlg.remove_choice": "Remove",
    "dlg.add_line": "Adds a line",
    "dlg.add_choice": "Adds a choice. Each option has its own branch",
    "dlg.add_answer": "Adds an option",
    "dlg.answer": "Spoken by the player",
    "dlg.once": "Once: hidden after it was chosen",
    "dlg.add_condition": "Adds a condition (all conditions must be met)",
    "dlg.thought": "Thought: shown as a subtitle, not spoken",
    "dlg.end": "What happens after this option",
    "dlg.voice": "No voice yet. Choose a voiced line",
    "dlg.voice_set": "Voiced line with lip sync",
    "dlg.voice_find": "Short lines first",
    "dlg.voice_game": "Voiced lines of the game",
    "dlg.voice_custom": "Recordings from the loaded content packs",
    "dlg.custom_find": "Searches by text, speaker or tag",
    "dlg.play": "Play",
    "dlg.custom_take": "Uses this recording with its text",
    "dlg.game_take": "Uses this line with its text",
    "dlg.person": "When they take part in the dialogue",
    "dlg.person_main": "Changes the NPC of the quest step",
    "dlg.person_player": "The player character",
    "dlg.person_scene": "A character of the game's scene",
    "dlg.add_person": "Adds a character to the dialogue",
    "dlg.add_this_person": "Adds them to the dialogue",
    "dlg.fold": "Hides or shows what follows",
    "dlg.only_if": "Shows the option only when the condition is met",
    "dlg.timed": "Time limit for the choice",
    "dlg.add_variant": "Another wording. One variant is picked at random",
    "dlg.variant": "If left empty, it is left out",
    "dlg.does": "Pay, persuade, give or receive something with this option",
    "dlg.item": "Chooses the item",
    "dlg.gesture": "Gesture while speaking",
    "dlg.camera": "The camera for this line, from the game's own shots (wide to extreme close-up)",
    "dlg.mood": "Facial expression while speaking",
    "dlg.pose": "Changes the speaker's pose from this line on (standing, sitting, kneeling, lying)",
    "dlg.look": "Who the speaker looks at during this line",
    "dlg.preview_move": "Plays the camera move with the editor camera in the game",
    "dlg.glide": "Cut to the camera, or move to it from another camera during the line",
    "dlg.own_cam": "A camera of this dialogue. Look through it, set it to the current view or remove it",
    "qb.walk_talk_lines": "The lines they say on the way (in the dialogue editor)",
    "qb.walk_talk_add": "Lines the NPC and the player say while walking, from a point of the path on",
    "qb.notice_game_board": "One of the game's notice boards, nearest first. The notice is added to it",
    "qb.notice_text": "The text of the notice, shown on the board next to its title. Taking the notice continues "
                      "the quest",
    "dlg.player_spot": "Where the player stands in this dialogue (in front of the other person, or an own spot)",
    "dlg.add_cam": "Adds a camera at the current editor view. Lines choose it under Camera",
    "dlg.pose_start":"Pose for the whole dialogue (standing, sitting, kneeling, lying)",
    "dlg.anim_find": "Searches the game's scene animations by name",
    "dlg.add_if": "Lines that depend on a condition",
    "dlg.if_fact": "Fact to check",
    "dlg.if_op": "Comparison",
    "dlg.if_value": "Value to compare with",
    "dlg.remove_if": "Remove",
    "dlg.script": "The game's scene runs this here. Keep it, its quest may wait for it",
    "dlg.remove_random": "Remove",
    # --- item window
    "ic.close": "Close",
    "ic.take": "Uses the item",
    "ic.quest_item": "An item of this quest",
    "ic.own_item": "An item made for this quest. Rename or remove it under In this quest on the Quest tab",
    "qb.quest_graph": "Every block of this quest as the game runs it, in the quest graph. Changes there are kept "
                      "with the project and used by the build",
    "qb.in_quest": "The NPCs, objects and items of this quest and the steps that use them",
    "qb.in_quest_go": "Jumps there",
    "obj.quest_puts_in": "Put into it by the quest when it starts (the items of a Loot step)",
    "qb.own_remove": "Removes the item, also from the steps that use it",
    "ic.new_own": "Creates an item for this quest only",
    "ic.rename": "A new name makes it a new item of this quest",
    "ic.redescribe": "Description in the inventory",
    # --- loot
    "loot.on": "The container also gets random items from a loot table",
    "loot.off": "Only the quest items",
    "loot.actor_on": "Also drops items from a loot table when killed",
    "loot.actor_off": "Only drops the inventory",
    "loot.own": "Back to its default loot table",
    "loot.change": "Chooses another loot table",
    "loot.use": "Uses this loot table",
    # --- panel
    "pan.close": "Close",
    "pan.settings": "Settings",
    "pan.project": "The current project. Rename it, open another one or start a new one",
    "pan.project_name": "The project's name. Press Enter to keep it",
    "browse.list": "Every project and the examples that come with Conjunction. Double click to open",
    "browse.open": "Opens the chosen project. The game starts again with only this project in it (automatic quick save)",
    "browse.folder": "Opens the projects folder in Explorer (projects dropped in show up here)",
    "browse.add": "Adds a project from anywhere (pick its project.yml)",
    "pan.tab.catalog": "The Asset Browser with everything that can be placed",
    "pan.tab.places": "The locations of this quest",
    "pan.tab.quest": "The steps of this quest",
    "pan.tab.build": "Check, build and play the quest",
    "pan.add_place": "Adds a location. Newly placed objects go into it",
    "pan.hide_area": "Draws a hide area in the world (click its corners, Enter to finish). While the player is "
                     "inside, the game draws no foliage, terrain or water (set below, after Build & Play)",
    "area.foliage": "While the player is inside: the game draws no grass, bushes or trees (for a cave or a cellar)",
    "area.terrain": "While the player is inside: the game draws no ground (for a cellar or an own floor)",
    "area.water": "While the player is inside: the game draws no water",
    "area.height": "How far up from its lowest corner the area reaches",
    "area.outline": "Shows the outline in the world (drag a corner, click a line for a new corner, right click a "
                    "corner to remove it)",
    "dlg.rename": "Renames the step (its line in the journal)",
    "dlg.length": "How long the line lasts (seconds). Empty: as long as the voice or the lip sync. Longer: the "
                  "line is said as it is and the scene stays on it",
    "pan.apply": "Saves the values",
    "pan.play": "Builds the quest and restarts the game with it",
    "pan.check": "Checks the quest in seconds without restarting the game",
    "pan.meshes": "Makes every world mesh placeable. Takes a few minutes, once",
    "pan.foliage": "Makes the game's trees, bushes and flowers placeable with their collision. Takes a few "
                   "minutes, once (the game must be closed)",
    "pan.notice_more": "Opens the build log",
    "pan.notice_close": "Close",
    "pan.up": "Move up",
    "pan.down": "Move down",
    "pan.delete": "Remove",
}

STYLE = ("#w3stip{background:rgb(30,30,32);border:1px solid #555;border-radius:0}"
         "QLabel#t{color:#f0f0f0;font:bold 12px}QLabel#b{color:#d0d0d0;font:12px}")
DELAY_MS = 450


def tab_tips(tabbar, keys):
    """One TIPS key per tab of a QTabBar (tabs whose line is None have none)."""
    tabbar.setProperty("cj_tabtips", list(keys))
    for i in range(tabbar.count()):
        tabbar.setTabToolTip(i, (TIPS.get(keys[i]) or "") if i < len(keys) else "")
    return tabbar


def item_tips(view):
    """A list or grid: each entry's display text is the title, its ToolTipRole the text."""
    view.viewport().setProperty("cj_items", True)
    return view


def tip(widget, key=None, title=None, text=None):
    """Give a widget its tooltip: the line of a TIPS key (None or unknown: no tooltip), or a title and a text."""
    if key is not None:
        widget.setProperty("cj_key", key)     # what the widget is, whatever it says (tests find it by this)
        title, text = "", TIPS.get(key)
    if not (title or text):
        widget.setProperty("cj_tip", None)
        widget.setToolTip("")
        return widget
    widget.setProperty("cj_tip", (title or "", text or ""))
    widget.setToolTip(title or text)        # Qt sends the tooltip event only to widgets that have one
    return widget


class Tip(QtWidgets.QWidget):
    def __init__(self):
        super().__init__(None, QtCore.Qt.ToolTip | QtCore.Qt.FramelessWindowHint |
                         QtCore.Qt.WindowDoesNotAcceptFocus | QtCore.Qt.WindowStaysOnTopHint)
        self.setAttribute(QtCore.Qt.WA_TranslucentBackground)
        self.setAttribute(QtCore.Qt.WA_ShowWithoutActivating)
        self.setAttribute(QtCore.Qt.WA_TransparentForMouseEvents)
        frame = QtWidgets.QFrame(self)
        frame.setObjectName("w3stip")
        frame.setStyleSheet(STYLE)
        lay = QtWidgets.QVBoxLayout(frame)
        lay.setContentsMargins(10, 7, 10, 8)
        lay.setSpacing(3)
        self.title = QtWidgets.QLabel()
        self.title.setObjectName("t")
        self.body = QtWidgets.QLabel()
        self.body.setObjectName("b")
        self.body.setWordWrap(True)
        self.body.setMaximumWidth(300)
        lay.addWidget(self.title)
        lay.addWidget(self.body)
        outer = QtWidgets.QVBoxLayout(self)
        outer.setContentsMargins(0, 0, 0, 0)
        outer.addWidget(frame)

    def show_at(self, pos, title, text):
        self.title.setText(title)
        self.title.setVisible(bool(title))
        self.body.setText(text)
        self.body.setVisible(bool(text))
        if text:                                    # one line up to 300 px, wrapped only beyond (Qt picks narrow)
            self.body.setFixedWidth(min(300, self.body.fontMetrics().horizontalAdvance(text) + 6))
        self.adjustSize()
        screen = QtGui.QGuiApplication.screenAt(pos) or QtGui.QGuiApplication.primaryScreen()
        r = screen.geometry()
        x = min(pos.x() + 14, r.right() - self.width() - 4)
        y = pos.y() + 20 if pos.y() + 20 + self.height() < r.bottom() else pos.y() - self.height() - 8
        self.move(x, y)
        self.show()
        self.raise_()


class Tooltips(QtCore.QObject):
    """App-wide: Qt's tooltip events of widgets with a cj_tip become our tooltip."""

    def __init__(self, app):
        super().__init__()
        self.box = Tip()
        app.installEventFilter(self)

    def eventFilter(self, obj, ev):
        t = ev.type()
        if t == QtCore.QEvent.ToolTip and isinstance(obj, QtWidgets.QWidget):
            data = obj.property("cj_tip")
            tabs = obj.property("cj_tabtips")
            view = obj.parent() if obj.property("cj_items") else None
            if tabs and isinstance(obj, QtWidgets.QTabBar):
                i = obj.tabAt(ev.pos())             # a tab bar: one tooltip per tab
                line = TIPS.get(tabs[i]) if 0 <= i < len(tabs) else None
                data = ("", line) if line else None
            elif view is not None:
                ix = view.indexAt(ev.pos())         # a list / grid: the entry under the mouse
                data = (str(ix.data(QtCore.Qt.DisplayRole) or ""), str(ix.data(QtCore.Qt.ToolTipRole) or "")) \
                    if ix.isValid() else None
            if data and any(data):
                self.box.show_at(ev.globalPos(), *data)
                return True
            if tabs or view is not None:
                self.box.hide()
                return True
        elif t in (QtCore.QEvent.Leave, QtCore.QEvent.MouseButtonPress, QtCore.QEvent.Hide,
                   QtCore.QEvent.WindowDeactivate) and self.box.isVisible():
            self.box.hide()
        return False


def install(app):
    """Once per app (the editor, the setup window)."""
    if not hasattr(app, "_cj_tips"):
        app._cj_tips = Tooltips(app)
        app.setAttribute(QtCore.Qt.AA_DontShowIconsInMenus, False)
    return app._cj_tips
