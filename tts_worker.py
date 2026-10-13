"""Persistent Piper worker.

stdin:  JSON lines  {"cmd": "speak", "gen": int, "idx": int, "text": str}
                    {"cmd": "cancel", "below": int}   -> skip jobs with gen < below
stdout: frames      <u32 gen><u32 idx><u32 length><length bytes of raw s16le mono PCM>
        A frame with idx == READY carries the sample rate as its u32 payload.
"""
import json
import queue
import struct
import sys
import threading

from piper import PiperVoice

READY = 0xFFFFFFFE


def main() -> None:
    voice = PiperVoice.load(sys.argv[1])
    out = sys.stdout.buffer
    jobs: "queue.Queue[dict | None]" = queue.Queue()
    min_gen = [0]

    def write_frame(gen: int, idx: int, payload: bytes) -> None:
        out.write(struct.pack("<III", gen, idx, len(payload)))
        out.write(payload)
        out.flush()

    def reader() -> None:
        for line in sys.stdin:
            try:
                msg = json.loads(line)
            except ValueError:
                continue
            if msg.get("cmd") == "cancel":
                min_gen[0] = max(min_gen[0], int(msg.get("below", 0)))
            elif msg.get("cmd") == "speak":
                jobs.put(msg)
        jobs.put(None)

    threading.Thread(target=reader, daemon=True).start()
    write_frame(0, READY, struct.pack("<I", voice.config.sample_rate))

    while (job := jobs.get()) is not None:
        gen, idx = int(job["gen"]), int(job["idx"])
        if gen < min_gen[0]:
            continue
        pcm = bytearray()
        try:
            for chunk in voice.synthesize(job["text"]):
                if gen < min_gen[0]:
                    break
                pcm += chunk.audio_int16_bytes
        except Exception as exc:  # keep the worker alive on bad input
            print(f"synthesis failed: {exc}", file=sys.stderr, flush=True)
            pcm = bytearray()
        if gen >= min_gen[0]:
            write_frame(gen, idx, bytes(pcm))


if __name__ == "__main__":
    main()
