#!/usr/bin/env bash
# Create a PyTorch virtual environment for the model stage.
#   model/tools/setup_env.sh            CPU-only wheels, into model/.venv
#   model/tools/setup_env.sh cu128      CUDA 12.8 wheels, into model/.venv-cuda
# The system python may have no pip module, so pip is bootstrapped from
# get-pip.py. Caches and build temp go beside the venv rather than into /tmp.
set -euo pipefail
here="$(cd "$(dirname "$0")/.." && pwd)"
flavour="${1:-cpu}"
if [ "$flavour" = "cpu" ]; then venv="$here/.venv"; else venv="$here/.venv-cuda"; fi
index="https://download.pytorch.org/whl/$flavour"
export PIP_CACHE_DIR="$here/.pip-cache"
export TMPDIR="$here/.pip-tmp"
mkdir -p "$PIP_CACHE_DIR" "$TMPDIR"
if [ ! -x "$venv/bin/python" ]; then
  python3 -m venv --without-pip "$venv"
  curl -sS https://bootstrap.pypa.io/get-pip.py -o "$TMPDIR/get-pip.py"
  "$venv/bin/python" "$TMPDIR/get-pip.py" --quiet
fi
"$venv/bin/pip" install --quiet --upgrade pip
"$venv/bin/pip" install --quiet --index-url "$index" --extra-index-url https://pypi.org/simple -r "$here/requirements.txt"
"$venv/bin/python" - <<'PY'
import torch, segmentation_models_pytorch as smp, rasterio, numpy
gpu = torch.cuda.get_device_name(0) if torch.cuda.is_available() else "no GPU visible"
print("torch", torch.__version__, "|", gpu, "| smp", smp.__version__, "| rasterio", rasterio.__version__, "| numpy", numpy.__version__)
PY
rm -rf "$TMPDIR"
echo "Environment ready: $venv"
