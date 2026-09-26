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


class TverskyLoss(nn.Module):
    """Half BCE, half Tversky (beta above 0.5 weights false positives more than
    false negatives), optionally focal (gamma above 1 sharpens on hard patches).
    With beta 0.5 and gamma 1 the Tversky half is the soft Dice of BCEDiceLoss."""

    def __init__(self, beta: float = 0.7, gamma: float = 1.0, bce_weight: float = 0.5):
        super().__init__()
        self.bce = nn.BCEWithLogitsLoss()
        self.tversky = smp.losses.TverskyLoss(mode="binary", from_logits=True, alpha=1.0 - beta, beta=beta, gamma=gamma)
        self.w = bce_weight

    def forward(self, logits: torch.Tensor, target: torch.Tensor) -> torch.Tensor:
        return self.w * self.bce(logits, target) + (1.0 - self.w) * self.tversky(logits, target)


def build_loss(cm: dict) -> nn.Module:
    """The training loss from config keys: loss = bce_dice (default) | tversky |
    focal_tversky, with tversky_beta and focal_gamma."""
    name = str(cm.get("loss", "bce_dice"))
    if name == "bce_dice":
        return BCEDiceLoss()
    if name == "tversky":
        return TverskyLoss(beta=float(cm.get("tversky_beta", 0.7)), gamma=1.0)
    if name == "focal_tversky":
        return TverskyLoss(beta=float(cm.get("tversky_beta", 0.7)), gamma=float(cm.get("focal_gamma", 1.33)))
    raise ValueError(f"unknown loss {name!r}: use bce_dice, tversky or focal_tversky")


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
