"""One-time model download: SenseVoice-Small + FSMN-VAD from ModelScope.

Run:  python3 scripts/pull_models.py
Models cache under ~/.cache/modelscope and load from there afterwards.
"""

import sys


def main() -> int:
    try:
        from funasr import AutoModel
    except ImportError:
        print("funasr is not installed. Run: pip install -r requirements.txt")
        return 1

    import os

    device = os.environ.get("ASR_DEVICE", "cpu")
    print(f"Downloading/loading models on device={device} ...")
    AutoModel(model="iic/SenseVoiceSmall", device=device, disable_update=True)
    AutoModel(model="fsmn-vad", device=device, disable_update=True)
    print("Done. Models are cached for offline use.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
