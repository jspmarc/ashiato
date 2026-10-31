"""Pre-download the OCR models at image build time.

Run in the worker Docker stage so the first real task does not have to
download ~130 MB of model weights.
"""

from app.core.ocr import init_models

if __name__ == "__main__":
    init_models()
