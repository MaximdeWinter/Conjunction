# Example plug-in

Shows what a plug-in of Conjunction can add. Meant for plug-in authors, not for quests.

- **App page** "Example": a line with the greeting from its settings
- **Panel tab** "Example" in the editor in the game, with a button that picks a campfire to place
- **Catalog entry**: a campfire, listed under Light
- **Quest step** `wait_night`: the quest continues when it is night in the game
- **NPC window**: a section "Example" with the NPC's name and the greeting
- **Settings**: a section "Example" below Plug-ins (Greeting, Loud)

## For plug-in authors

A plug-in is a folder in `Documents\Conjunction\plugins` with two files:

- `plugin.json`: id, name, version, author, description, `requires` (other plug-ins it needs)
- `plugin.py`: `register(api)`, where it adds its pages, panels, settings, quest steps and build steps

Put a `README.md` beside them. Conjunction shows it in Settings > Plug-ins (README).
Everything `api` offers is listed at the top of `conjunction/plugins.py`.
