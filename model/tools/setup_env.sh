#!/usr/bin/env bash
# Create a PyTorch virtual environment for the model stage.
#   model/tools/setup_env.sh            CPU-only wheels, into model/.venv
#   model/tools/setup_env.sh cu128      CUDA 12.8 wheels, into model/.venv-cuda
#   model/tools/setup_env.sh rocm7.2    ROCm 7.2 wheels (AMD GPU), into model/.venv-rocm
# The flavour is a PyTorch wheel index name (https://download.pytorch.org/whl/<flavour>).
# The ROCm wheels bundle the HIP runtime, so only the amdgpu kernel driver is
# needed on the host, not a system ROCm install.
# TOF_VENV=<dir> puts the venv somewhere else, e.g. on a local disk when the
# repo lives on network storage (GPU wheels are several GB and import slowly
# over NFS). pip's cache and build temp go beside the venv, not into /tmp.
# The system python may have no pip module, so pip is bootstrapped from get-pip.py.
set -euo pipefail
here="$(cd "$(dirname "$0")/.." && pwd)"
flavour="${1:-cpu}"
case "$flavour" in
  cpu)    default_venv="$here/.venv" ;;
  cu*)    default_venv="$here/.venv-cuda" ;;
  rocm*)  default_venv="$here/.venv-rocm" ;;
  *)      echo "unknown flavour '$flavour' (expected cpu, cu<ver> or rocm<ver>)" >&2; exit 2 ;;
esac
venv="${TOF_VENV:-$default_venv}"
index="https://download.pytorch.org/whl/$flavour"
export PIP_CACHE_DIR="$(dirname "$venv")/.pip-cache"
export TMPDIR="$(dirname "$venv")/.pip-tmp"
mkdir -p "$PIP_CACHE_DIR" "$TMPDIR"
if [ ! -x "$venv/bin/python" ]; then
  python3 -m venv --without-pip "$venv"
  curl -sS https://bootstrap.pypa.io/get-pip.py -o "$TMPDIR/get-pip.py"
  "$venv/bin/python" "$TMPDIR/get-pip.py" --quiet
fi
"$venv/bin/pip" install --quiet --upgrade pip
# torch and torchvision come from the flavour index alone: with PyPI as a
# fallback pip takes whichever is newest, and PyPI's build is CUDA, not the
# flavour asked for. Everything else then resolves against the pinned torch.
"$venv/bin/pip" install --quiet --index-url "$index" $(grep -E '^torch(vision)?[><=~]' "$here/requirements.txt")
"$venv/bin/pip" install --quiet --extra-index-url "$index" -r "$here/requirements.txt"
"$venv/bin/python" - <<'PY'
import torch, segmentation_models_pytorch as smp, rasterio, numpy
backend = f"ROCm {torch.version.hip}" if getattr(torch.version, "hip", None) else (f"CUDA {torch.version.cuda}" if torch.version.cuda else "CPU build")
gpu = f"{torch.cuda.get_device_name(0)}, {torch.cuda.get_device_properties(0).total_memory / 1024**3:.0f} GB" if torch.cuda.is_available() else "no GPU visible"
print("torch", torch.__version__, "|", backend, "|", gpu, "| smp", smp.__version__, "| rasterio", rasterio.__version__, "| numpy", numpy.__version__)
PY
rm -rf "$TMPDIR"
echo "Environment ready: $venv"
