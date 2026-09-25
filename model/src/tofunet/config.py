"""Repository root, config.yml and the memory guard shared by every script."""
from __future__ import annotations

import logging
import os
import sys
import time
from pathlib import Path

import psutil
import yaml


def repo_root() -> Path:
    """The repository root: the nearest ancestor holding config.yml."""
    here = Path(__file__).resolve()
    for p in [here, *here.parents]:
        if (p / "config.yml").exists() and (p / "treesOutsideForests.Rproj").exists():
            return p
    raise RuntimeError("config.yml not found above " + str(here))


ROOT = repo_root()


def load_config() -> dict:
    with open(ROOT / "config.yml") as f:
        return yaml.safe_load(f)


def tof_path(rel: str | os.PathLike) -> Path:
    """A repo-relative path from config.yml as an absolute one."""
    p = Path(rel)
    return p if p.is_absolute() else ROOT / p


def setup_logging(log_file: Path | None = None) -> logging.Logger:
    fmt = "%(asctime)s  %(message)s"
    handlers: list[logging.Handler] = [logging.StreamHandler(sys.stdout)]
    if log_file is not None:
        log_file.parent.mkdir(parents=True, exist_ok=True)
        handlers.append(logging.FileHandler(log_file))
    logging.basicConfig(level=logging.INFO, format=fmt, datefmt="%H:%M:%S", handlers=handlers, force=True)
    return logging.getLogger("tofunet")


def available_gb() -> float:
    return psutil.virtual_memory().available / 1024**3


def memory_guard(min_available_gb: float, log: logging.Logger, wait_minutes: float = 10.0,
                 what: str = "the next step") -> None:
    """Block until the machine has `min_available_gb` free, or raise after `wait_minutes`.

    Another memory-hungry service shares this machine, so training must never
    take the last gigabytes. Free memory is checked before every expensive step
    and the process waits rather than pushing the machine into the OOM killer.
    """
    deadline = time.time() + wait_minutes * 60
    while True:
        avail = available_gb()
        if avail >= min_available_gb:
            return
        if time.time() > deadline:
            raise MemoryError(
                f"Only {avail:.1f} GB available for {wait_minutes:.0f} min "
                f"(need {min_available_gb:.0f} GB before {what}); stopping rather than risking an OOM."
            )
        log.warning("%.1f GB available, below the %.0f GB floor; waiting before %s.", avail, min_available_gb, what)
        time.sleep(30)


def process_rss_gb() -> float:
    return psutil.Process().memory_info().rss / 1024**3


def pick_device(requested: str = "auto"):
    """'auto' takes the GPU when CUDA is available, else the CPU; 'cuda', 'cuda:1'
    or 'cpu' force a choice. Returns (torch.device, description)."""
    import torch
    if requested == "auto":
        requested = "cuda" if torch.cuda.is_available() else "cpu"
    dev = torch.device(requested)
    if dev.type == "cuda":
        if not torch.cuda.is_available():
            raise RuntimeError("CUDA requested but no GPU is visible to torch.")
        i = dev.index if dev.index is not None else torch.cuda.current_device()
        props = torch.cuda.get_device_properties(i)
        desc = f"{props.name}, {props.total_memory / 1024**3:.0f} GB"
    else:
        desc = "CPU"
    return dev, desc
