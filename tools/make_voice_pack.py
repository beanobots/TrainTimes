#!/usr/bin/env python3
"""Builds the walking voice's asset pack (Kokoro, 8-bit + half) in ios/VoicePack: what Apple
hosts and the phone downloads once, as Leeway installs (prefetch), and ios/VoicePack.aar.

    pip install "misaki[en]" huggingface_hub
    python3 tools/make_voice_words.py names ios/VoicePack     # words.json, first
    python3 tools/make_voice_pack.py ios/VoicePack
    cd ios/VoicePack && xcrun ba-package Manifest.json -o ../VoicePack.aar

Then upload VoicePack.aar in App Store Connect (the app's Asset Packs), or for the simulator,
copy the pack's files into the app's Documents/VoicePack (`VoicePack.devFolder`).

    python3 tools/make_voice_pack.py ios/VoicePack --extras   # needs only huggingface_hub

adds the Prototyping Voice tool's extras for debug builds (`VoiceStyle`), never in the pack:
the half and full models (kokoro-fp16.onnx 163 MB, kokoro-fp32.onnx 326 MB) and more American
voices (voice-<name>.bin). They're left out of Manifest.json's fileSelectors, so ba-package
leaves them out, and out of git (ios/VoicePack/*); copy them into Documents/VoicePack too.

In the pack:
  kokoro.onnx    the model, 8-bit weights with half-precision maths (onnx-community's
                 model_q8f16, 86 MB): Apache 2.0
  voice-female.bin
                 the af_heart voice's style vectors, by phoneme count (510 × 256 floats)
  vocab.json     Kokoro's phoneme-to-id table
  lexicon.tsv    misaki's American dictionaries, gold over silver (Apache 2.0): "word<TAB>
                 phonemes", sorted by UTF-8 bytes so the phone finds a word by binary search
                 without loading it all. Words said two ways ("abuse") keep their usual one.
  words.tsv      every word in the city's names (make_voice_words.py), looked up first
eSpeak (GPL) isn't in it, nor used to make it.
"""
import json, pathlib, shutil, sys

MODEL = ("onnx-community/Kokoro-82M-v1.0-ONNX", "onnx/model_q8f16.onnx")
# The voice, by the name the app asks for it by: Kokoro's American af_heart, 510 × 256 floats.
# The male am_michael was tried on 11/8 and dropped
VOICES = {"female": "voices/af_heart.bin"}
VOICE_REPO = "onnx-community/Kokoro-82M-v1.0-ONNX"
CONFIG = ("hexgrad/Kokoro-82M", "config.json")
# Debug-only extras (--extras), by the file each is copied to: not in the pack
EXTRA_MODELS = {"kokoro-fp16.onnx": "onnx/model_fp16.onnx", "kokoro-fp32.onnx": "onnx/model.onnx"}
EXTRA_VOICES = ["af_bella", "af_nicole", "af_sarah", "am_michael", "am_fenrir", "am_puck", "am_adam"]
# The pack's own files, all Manifest.json lists
PACK = ("kokoro.onnx", "voice-female.bin", "vocab.json", "lexicon.tsv", "words.tsv")


def extras(target):
    """The bigger models and other voices, for debug builds' Voice tool: no misaki needed."""
    from huggingface_hub import hf_hub_download

    target.mkdir(parents=True, exist_ok=True)
    files = dict(EXTRA_MODELS)
    files.update({f"voice-{name}.bin": f"voices/{name}.bin" for name in EXTRA_VOICES})
    for name, path in files.items():
        shutil.copyfile(hf_hub_download(VOICE_REPO, path), target / name)
        print(f"{name:22} {(target / name).stat().st_size / 1e6:6.1f} MB")


def main(target):
    import importlib.resources
    from huggingface_hub import hf_hub_download
    from misaki import data

    target.mkdir(parents=True, exist_ok=True)
    shutil.copyfile(hf_hub_download(*MODEL), target / "kokoro.onnx")
    for name, path in VOICES.items():
        shutil.copyfile(hf_hub_download(VOICE_REPO, path), target / f"voice-{name}.bin")
    for old in ("voice.bin", "voice-male.bin"):
        (target / old).unlink(missing_ok=True)
    vocab = json.load(open(hf_hub_download(*CONFIG)))["vocab"]
    with open(target / "vocab.json", "w") as file:
        json.dump(vocab, file, ensure_ascii=False, separators=(",", ":"))

    entries = {}
    for name in ("us_silver.json", "us_gold.json"):  # gold last, over silver
        with importlib.resources.open_text(data, name) as file:
            for word, phonemes in json.load(file).items():
                if isinstance(phonemes, dict):
                    phonemes = phonemes.get("DEFAULT")
                if phonemes and "\t" not in word and "\n" not in word:
                    entries[word] = phonemes
    lines = sorted((f"{w}\t{p}".encode() for w, p in entries.items()))
    (target / "lexicon.tsv").write_bytes(b"\n".join(lines) + b"\n")

    words = json.load(open(target / "words.json"))
    lines = sorted(f"{w}\t{p}".encode() for w, p in words.items())
    (target / "words.tsv").write_bytes(b"\n".join(lines) + b"\n")

    manifest = {
        "assetPackID": "VoicePack",
        # Downloaded as Leeway installs, and again with an update that changes it, finishing in
        # the background: the voice is there for a first walk, without holding up the app
        "downloadPolicy": {"prefetch": {"installationEventTypes": ["firstInstallation", "subsequentUpdate"]}},
        "fileSelectors": [{"file": name} for name in PACK],
        "platforms": ["iOS"],
    }
    with open(target / "Manifest.json", "w") as file:
        json.dump(manifest, file, indent=2)
    for name in ("kokoro.onnx", "voice-female.bin", "lexicon.tsv", "words.tsv"):
        print(f"{name:12} {(target / name).stat().st_size / 1e6:6.1f} MB")
    print(f"{len(entries)} dictionary words, {len(words)} city words")


if __name__ == "__main__":
    if "--extras" in sys.argv[2:]:
        extras(pathlib.Path(sys.argv[1]))
    else:
        main(pathlib.Path(sys.argv[1]))
