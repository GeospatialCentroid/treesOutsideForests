"""The network, its loss, and checkpoint I/O."""
from __future__ import annotations

from pathlib import Path

import segmentation_models_pytorch as smp
import torch
from torch import nn


def build_model(encoder: str, encoder_weights: str | None, in_channels: int = 4) -> nn.Module:
    """U-Net with a pretrained encoder. segmentation_models_pytorch adapts the
    first convolution to 4 bands by reusing the RGB filters and scaling them,
    so the ImageNet initialisation still helps despite the extra NIR band."""
    return smp.Unet(encoder_name=encoder, encoder_weights=encoder_weights or None,
                    in_channels=in_channels, classes=1, activation=None)


class BCEDiceLoss(nn.Module):
    """Half binary cross-entropy, half soft Dice, on logits. Cross-entropy keeps
    per-pixel calibration; Dice keeps the rare tree class from being ignored."""

    def __init__(self):
        super().__init__()
        self.bce = nn.BCEWithLogitsLoss()
        self.dice = smp.losses.DiceLoss(mode="binary", from_logits=True)

    def forward(self, logits: torch.Tensor, target: torch.Tensor) -> torch.Tensor:
        return 0.5 * self.bce(logits, target) + 0.5 * self.dice(logits, target)


def save_checkpoint(path: Path, model: nn.Module, meta: dict) -> None:
    state = {k: v.detach().cpu() for k, v in model.state_dict().items()}
    torch.save({"state_dict": state, "meta": meta}, path)


def load_checkpoint(path: Path) -> tuple[nn.Module, dict]:
    ck = torch.load(path, map_location="cpu", weights_only=False)
    meta = ck["meta"]
    model = build_model(meta["encoder"], None, in_channels=4)
    model.load_state_dict(ck["state_dict"])
    model.eval()
    return model, meta
