"""Own voice recordings into the game: audio in the game's format, lip sync from the recording, one .w3speech file.

radish packs PCM wem files (a RIFF WAVE, format tag 0xFFFE, 48 kHz mono 16 bit) and CR2W lip sync into a v162 file;
the remaster (5.0) plays neither. With ffmpeg the file is remade as the game's own: v164, Wwise Opus audio
(wwise_opus), the lip sync raw (lipsync).

    build(lines, work, content_dir, lang, log)   lines: [{"id": string id, "text": ..., "source": audio file}]

radish's tools do the rest: phonemes from the recording and its text (pocketsphinx), lip sync animation from the
phonemes, cr2w of it, and the packed <lang>pc.w3speech of the DLC.
"""
import array
import glob
import os
import shutil
import struct
import subprocess

from . import config

RATE = 48000
LEAD = 0.25             # silence before the first sound (radish: prevents a jerked mouth opening)


def read_audio(path):
    """-> (rate, mono samples as floats -1..1). wav (PCM 8/16/24/32 bit, float 32); other formats via ffmpeg."""
    if not path.lower().endswith(".wav"):
        exe = shutil.which("ffmpeg")
        if not exe:
            raise RuntimeError(f"{os.path.basename(path)}: only wav files can be read without ffmpeg")
        raw = subprocess.run([exe, "-v", "error", "-i", path, "-f", "s16le", "-ac", "1", "-ar", str(RATE), "-"],
                             capture_output=True, check=True).stdout
        a = array.array("h")
        a.frombytes(raw[:len(raw) // 2 * 2])
        return RATE, [s / 32768.0 for s in a]
    data = open(path, "rb").read()
    if data[:4] != b"RIFF" or data[8:12] != b"WAVE":
        raise RuntimeError(f"{os.path.basename(path)}: not a wav file")
    i, fmt, pcm = 12, None, None
    while i + 8 <= len(data):
        cid, n = data[i:i + 4], struct.unpack_from("<I", data, i + 4)[0]
        if cid == b"fmt ":
            tag, channels, rate = struct.unpack_from("<HHI", data, i + 8)
            bits = struct.unpack_from("<H", data, i + 22)[0]
            if tag == 0xFFFE and n >= 40:
                tag = struct.unpack_from("<H", data, i + 32)[0]      # the sub format's first two bytes
            fmt = (tag, channels, rate, bits)
        elif cid == b"data":
            pcm = data[i + 8:i + 8 + n]
        i += 8 + n + (n & 1)
    if not fmt or pcm is None:
        raise RuntimeError(f"{os.path.basename(path)}: no audio in the file")
    tag, channels, rate, bits = fmt
    if tag == 3 and bits == 32:
        a = array.array("f")
        a.frombytes(pcm[:len(pcm) // 4 * 4])
        values = list(a)
    elif tag == 1 and bits == 16:
        a = array.array("h")
        a.frombytes(pcm[:len(pcm) // 2 * 2])
        values = [s / 32768.0 for s in a]
    elif tag == 1 and bits == 8:
        values = [(b - 128) / 128.0 for b in pcm]
    elif tag == 1 and bits in (24, 32):
        w = bits // 8
        values = [int.from_bytes(pcm[k:k + w], "little", signed=True) / float(1 << (bits - 1))
                  for k in range(0, len(pcm) - w + 1, w)]
    else:
        raise RuntimeError(f"{os.path.basename(path)}: wav format {tag} / {bits} bit is not supported")
    if channels > 1:                                    # mono: the mean of the channels
        values = [sum(values[k:k + channels]) / channels for k in range(0, len(values) - channels + 1, channels)]
    return rate, values


def resample(values, rate, to=RATE):
    if rate == to or not values:
        return values
    n = int(len(values) * to / rate)
    step = rate / to
    out = []
    last = len(values) - 1
    for k in range(n):
        x = k * step
        j = int(x)
        f = x - j
        out.append(values[j] * (1 - f) + values[min(j + 1, last)] * f)
    return out


def pcm16(values):
    a = array.array("h", (max(-32768, min(32767, int(round(v * 32767)))) for v in values))
    return a.tobytes()


def write_wav(path, values, rate=RATE):
    data = pcm16(values)
    with open(path, "wb") as f:
        f.write(b"RIFF" + struct.pack("<I", 36 + len(data)) + b"WAVE")
        f.write(b"fmt " + struct.pack("<IHHIIHH", 16, 1, 1, rate, rate * 2, 2, 16))
        f.write(b"data" + struct.pack("<I", len(data)) + data)


def write_wem(path, values, rate=RATE):
    """The game's PCM wem (the layout of radish's silence template)."""
    data = pcm16(values)
    fmt = struct.pack("<HHIIHHHHI", 0xFFFE, 1, rate, rate * 2, 2, 16, 6, 0, 4)     # mono, channel mask: centre
    body = b"WAVE" + b"fmt " + struct.pack("<I", len(fmt)) + fmt + b"JUNK" + struct.pack("<I", 4) + b"\0" * 4 + \
        b"data" + struct.pack("<I", len(data)) + data
    with open(path, "wb") as f:
        f.write(b"RIFF" + struct.pack("<I", len(body)) + body)


def prepare(source):
    """-> (48 kHz mono samples with the lead-in silence, seconds)."""
    rate, values = read_audio(source)
    values = [0.0] * int(LEAD * RATE) + resample(values, rate)
    return values, round(len(values) / RATE, 3)


def seconds(source):
    try:
        rate, values = read_audio(source)
        return round(LEAD + len(values) / rate, 3)
    except (OSError, RuntimeError, subprocess.CalledProcessError):
        return 0.0


def _phonemes_end(path):
    """Seconds of the last phoneme of a .phonemes file (its lines: phoneme|start ms|end ms|...)."""
    end = 0
    for ln in open(path, encoding="utf-8"):
        parts = [p.strip() for p in ln.split("|")]
        if len(parts) > 2 and parts[1].isdigit() and parts[2].isdigit():
            end = max(end, int(parts[2]))
    return end / 1000.0


def text_timing(lines, lang="en"):
    """{id: seconds} for lines without a recording: radish times their phonemes from the text alone (the mouth moves
    to it); the line lasts until the last phoneme and a little more."""
    import tempfile
    from .build import run
    lines = [ln for ln in lines if wordy(ln)]           # "..." (a gesture alone): no phonemes to time
    if not lines:
        return {}
    radish = config.load()["radish"]
    with tempfile.TemporaryDirectory(prefix="conjunction_mouth_") as tmp:
        csv = os.path.join(tmp, "lines.csv")
        strings_csv(csv, lines, lang)
        run([os.path.join(radish, "w3speech-phoneme-extractor.exe"), "--strings-file", csv,
             "--generate-from-text-only", "--output-dir", tmp], cwd=radish, log=lambda s: None)
        out = {}
        for ln in lines:
            f = os.path.join(tmp, f"{ln['id']}.phonemes")
            out[ln["id"]] = round(max(1.2, _phonemes_end(f) + 0.45), 3) if os.path.exists(f) else 2.0
        return out


def wordy(line):
    """A line with words (a gesture alone is '...': silence, the mouth stays shut)."""
    return any(c.isalnum() for c in str(line.get("text", "")))


def strings_csv(path, lines, lang="en"):
    with open(path, "w", encoding="utf-8", newline="\n") as f:
        f.write(f";meta[language={lang}]\n; id      |key(hex)|key(str)| text\n")
        for ln in lines:
            f.write(f"{ln['id']}|00000000||{ln['text']}\n")


def build(lines, work, content_dir, lang="en", log=print):
    """Recordings -> <content_dir>/<lang>pc.w3speech. Returns the strings csv of the lines (for the DLC's texts)."""
    from .build import run
    cfg = config.load()
    radish = cfg["radish"]
    work, content_dir = os.path.abspath(work), os.path.abspath(content_dir)      # the tools run in radish's folder
    if os.path.exists(work):
        shutil.rmtree(work)
    wav_dir, wem_dir = os.path.join(work, f"speech.{lang}.wav"), os.path.join(work, f"speech.{lang}.wem")
    os.makedirs(wav_dir)
    os.makedirs(wem_dir)
    csv = os.path.join(work, f"speech.{lang}.csv")
    strings_csv(csv, lines, lang)
    recorded = [ln for ln in lines if ln.get("source")]
    silent = [ln for ln in lines if not ln.get("source")]
    for ln in recorded:
        values, dur = prepare(ln["source"])
        write_wav(os.path.join(wav_dir, f"{ln['id']}.wav"), values)
        write_wem(os.path.join(wem_dir, f"{ln['id']}[{dur:.2f}]line.wem"), values)
    if recorded:
        log(f"[speech] {len(recorded)} recordings: phonemes")
        rec_csv = os.path.join(work, "recorded.csv")
        strings_csv(rec_csv, recorded, lang)
        run([os.path.join(radish, "w3speech-phoneme-extractor.exe"), "--extract", wav_dir, "--strings-file",
             rec_csv], log=log, cwd=radish)
    if silent:
        # lines without a recording: silence as long as the line, the mouth moves to the text
        log(f"[speech] {len(silent)} lines without a recording (the mouth moves to the text)")
        silent_csv = os.path.join(work, "silent.csv")
        spoken = [ln for ln in silent if wordy(ln)]
        if spoken:
            strings_csv(silent_csv, spoken, lang)
            run([os.path.join(radish, "w3speech-phoneme-extractor.exe"), "--strings-file", silent_csv,
                 "--generate-from-text-only", "--output-dir", wav_dir], log=log, cwd=radish)
        for ln in silent:
            dur = float(ln.get("dur") or 2.0)
            write_wem(os.path.join(wem_dir, f"{ln['id']}[{dur:.2f}]line.wem"), [0.0] * int(dur * RATE))
    missing = [ln for ln in recorded if not os.path.exists(os.path.join(wav_dir, f"{ln['id']}.phonemes"))]
    if missing:
        log(f"[speech] No phonemes found in {len(missing)} recordings (they get text timing)")
        only = os.path.join(work, "text_only.csv")
        strings_csv(only, missing, lang)
        run([os.path.join(radish, "w3speech-phoneme-extractor.exe"), "--extract", wav_dir, "--strings-file", only,
             "--generate-from-text-only"], log=log, cwd=radish)
    log("[speech] lip sync")
    run([os.path.join(radish, "w3speech-lipsync-creator.exe"), "--create-lipsync",
         os.path.join(wav_dir, "*.phonemes"), "--output-dir", wem_dir, "--repo-dir",
         os.path.join(radish, "repo.lipsync")], log=log, cwd=radish, harmless=("no match",))
    run([os.path.join(radish, "w3speech.exe"), "--encode-cr2w", wem_dir, "--output-dir", wem_dir], log=log,
        cwd=radish)
    log("[speech] pack")
    out = os.path.join(work, "packed")
    os.makedirs(out)
    run([os.path.join(radish, "w3speech.exe"), "--pack-w3speech", wem_dir, "--language", lang, "--output-dir", out],
        log=log, cwd=radish)
    made = glob.glob(os.path.join(out, "*.w3speech*"))
    if not made:
        raise RuntimeError("radish made no speech file")
    os.makedirs(content_dir, exist_ok=True)
    target = os.path.join(content_dir, f"{lang}pc.w3speech")
    if not shutil.which("ffmpeg"):
        log("[speech] No ffmpeg: the lines stay PCM, which the game (5.0) does not play. Please install ffmpeg")
        shutil.copy(made[0], target)
        return csv
    log("[speech] audio as Wwise Opus, file as v164 (the remaster)")
    open(target, "wb").write(remaster(open(made[0], "rb").read(), wav_dir, lang))
    return csv


def remaster(packed, wav_dir, lang):
    """radish's v162 .w3speech (PCM, CR2W lip sync) -> v164 with Wwise Opus audio (the recording of a line, else its
    silence) and the lip sync in the game's raw form."""
    from . import lipsync as L, w3speech, wwise_opus
    _version, _lang, lines = w3speech.read(packed)
    out = []
    for sid, _audio, dur, lipsync in lines:
        # radish's phoneme extractor renames a recording to <id>[<seconds>].wav
        found = [p for p in (os.path.join(wav_dir, f"{sid}.wav"),) if os.path.exists(p)] + \
            glob.glob(os.path.join(wav_dir, glob.escape(f"{sid}[") + "*].wav"))
        src = found[0] if found else None
        if not src:
            src = os.path.join(wav_dir, f"{sid}.silence.wav")
            write_wav(src, [0.0] * int(dur * RATE))
        audio, _seconds = wwise_opus.encode_file(src)
        out.append((sid, audio, dur, L.to_game(lipsync)))
    return w3speech.write_v164(lang, out)
