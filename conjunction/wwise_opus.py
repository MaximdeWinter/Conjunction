"""Wwise Opus .wem (codec 0x3041) without Wwise - what the remaster's voices are (5.0 plays no PCM wem: our lines were
silent, a game line in the same file was heard - 30.09.2026).

A game line's wem (vgmstream's wwise.c, OPUSWW): RIFF/WAVE with
    fmt  (0x24): codec 0x3041, channels, 48000, bytes a second, 0, 0, extra size 0x12, samples a frame (960),
                 channel layout (mono 0x00004101), total samples, frame count, pre-skip, version 1, mapping 0
    hash (0x10): Wwise's media hash (not of the data; ours: md5 of the data)
    seek        : u16 size of every Opus packet
    data        : the raw Opus packets, one after another
The packets come from ffmpeg's libopus (Ogg) - its header packets dropped, its pre-skip kept.
"""
import hashlib
import os
import struct
import subprocess
import tempfile

RATE = 48000
FRAME = 960                                             # 20 ms


def _ogg_packets(data):
    """The packets of an Ogg stream (segments joined across pages)."""
    packets, cur, i = [], b"", 0
    while i + 27 <= len(data) and data[i:i + 4] == b"OggS":
        nseg = data[i + 26]
        lacing = data[i + 27:i + 27 + nseg]
        body = i + 27 + nseg
        for lace in lacing:
            cur += data[body:body + lace]
            body += lace
            if lace < 255:
                packets.append(cur)
                cur = b""
        i = body
    return packets


def encode_file(src, bitrate="64k"):
    """An audio file (wav, ogg, mp3 ... anything ffmpeg reads) -> (wem bytes, seconds)."""
    with tempfile.TemporaryDirectory(prefix="conjunction_opus_") as tmp:
        out = os.path.join(tmp, "line.opus")
        subprocess.run(["ffmpeg", "-v", "error", "-y", "-i", src, "-ac", "1", "-ar", str(RATE), "-c:a", "libopus",
                        "-b:a", bitrate, "-frame_duration", "20", "-vbr", "on", out], check=True, capture_output=True)
        ogg = open(out, "rb").read()
    packets = _ogg_packets(ogg)
    head, frames = packets[0], packets[2:]              # OpusHead, OpusTags, then the audio
    if head[:8] != b"OpusHead":
        raise ValueError("ffmpeg gave no Opus stream")
    preskip = struct.unpack_from("<H", head, 10)[0]
    # the last page's granule position: every sample including the pre-skip
    granule = struct.unpack_from("<q", ogg, ogg.rfind(b"OggS") + 6)[0]
    samples = max(0, granule - preskip)
    return wem(frames, samples, preskip), samples / RATE


def wem(frames, samples, preskip):
    """Wwise Opus RIFF around raw Opus packets."""
    data = b"".join(frames)
    seconds = max(samples / RATE, 1e-3)
    fmt = struct.pack("<HHIIHHHHIIIHBB", 0x3041, 1, RATE, int(len(data) / seconds), 0, 0, 0x12, FRAME, 0x00004101,
                      samples, len(frames), preskip, 1, 0)             # version 1, mapping 0 (as the game)
    seek = struct.pack(f"<{len(frames)}H", *(len(f) for f in frames))
    chunks = b""
    for cid, body in ((b"fmt ", fmt), (b"hash", hashlib.md5(data).digest()), (b"seek", seek), (b"data", data)):
        chunks += cid + struct.pack("<I", len(body)) + body + (b"\0" if len(body) & 1 else b"")
    return b"RIFF" + struct.pack("<I", 4 + len(chunks)) + b"WAVE" + chunks
