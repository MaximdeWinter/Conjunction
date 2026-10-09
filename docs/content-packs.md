# Content packs

A content pack brings things that quests can use. There are two kinds:

- **Mods with things for the world** (furniture, decorations, items, armour, NPCs): any mod becomes a content pack
  with a pack card Conjunction writes into it, see [content-creators.md](content-creators.md). Quests that use its
  things name it, and players who lack it are told what is missing and where to get it.
- **Voice packs**: recordings for dialogues, described below. A quest carries the recordings it uses in its own mod,
  so players get them with the quest.

## Where voice packs are loaded from

- `packs\` in Conjunction's program folder (the samples it comes with)
- `Documents\Conjunction\packs\`

## A voice pack

```
my_voices/
  pack.yml                 id, name, author, version, description
  voices/
    voices.yml             the recordings
    old_man_help.wav
    ...
```

`pack.yml`:

```yaml
id: my_voices
name: My voices
author: someone
version: 1
description: Villagers of a small fishing town.
```

`voices/voices.yml`, one entry per recording:

```yaml
lines:
  - id: old_man_help            # unique in the pack; the line is known as my_voices/old_man_help
    file: old_man_help.wav
    text: "Witcher! Please, help me."   # exactly what is said (the lip sync is made from it)
    speaker: old fisherman
    tags: [male, old, afraid, fisherman]
    lang: en
```

Recordings: wav (8, 16, 24 or 32 bit, float, any rate, mono or stereo); ogg, mp3 and flac when ffmpeg is installed.
The build adds a little silence at the start.

## In a dialogue

A line's speech mark > **Find another** opens the voice search. **Custom** lists the recordings of every loaded pack,
with their words, speaker and tags (a left click on a tag shows only it, a right click adds it to the search).
**Play** listens to one; a click on its text gives it to the line, and the line then says that text.

## In the build

A quest that uses recordings carries them in its own mod: each becomes the game's audio, the lip sync is made from the
recording and its text, and the lines play in every language of the game.
