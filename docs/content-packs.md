# Content packs

A content pack brings things that quests can use. There are two kinds:

- **Mods with things for the world** (furniture, decorations, items, armour, NPCs), with a pack card, see
  [content-creators.md](content-creators.md).
- **Voice packs**: recordings for dialogues. A quest carries the recordings it uses, so players get them with it.

## Where voice packs are loaded from

`Documents\conjunction\packs\`, one folder per pack.

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

Recordings: wav (8, 16, 24 or 32 bit, float, any rate, mono or stereo); ogg, mp3 and flac with ffmpeg.

A quest with recordings needs [ffmpeg](https://ffmpeg.org) on your PC (its folder in the PATH) when you build it.

## In a dialogue

**Voice** under a line opens the voice search. **Game** lists the game's spoken lines with the line's words, voices
that fit the person first. **Custom** lists the recordings of every loaded pack (a left click on a tag shows only it,
a right click adds it to the search). **Play** listens to one; a click on its text gives it to the line.

The build makes the game's audio and the lip sync from each recording, in every language of the game.
