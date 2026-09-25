import os, json, time
import numpy as np
from PIL import Image
# from tqdm import tqdm
from pathlib import Path
import rasterio
import tensorflow as tf
from tensorflow import keras
from math import ceil

patch_size = 256
stride = 200
inf_size = 384
input_files = Path('/nfs/rubelscratch/30days/Shahriar/unet_training_data/Nebraska+LRR_F/validation').rglob('*naip.tif')
trained_model_path = Path('/nfs/ugrad/sheydari/Agroforestry/run_data/unet_classification_resnet34_122257.keras')
output_path = Path('/nfs/ogle/Agroforestry/phase2_sampling/shahriar/LRR_F-predicted')
naip_bands = 4
model_timestamp = trained_model_path.stem.split('_')[-1]

def sliding_window_predict(
    model,
    image,                      # full HxWxC numpy array (float32, normalized to [0,1])
    best_threshold=0.5,          # optimum threshold for probability to binary conversion
    patch_size=256,             # training/core size
    inf_size=384,               # inference window size (must be >= patch_size and same parity)
    stride=200,                 # sliding stride for cores
    batch_size=1,               # number of patches to predict at once (increase for speed)
):
    """
    Sliding-window inference:
      - extract inf_size x inf_size windows
      - predict on them
      - crop center patch_size x patch_size from the prediction
      - blend (weighted average) into output mosaic

    Returns:
      prob_map: H x W float32 probability map
    """

    H, W, C = image.shape
    assert inf_size >= patch_size
    margin = (inf_size - patch_size) // 2

    # Prepare output maps
    prob_map = np.zeros((H, W), dtype=np.float32)
    weight_map = np.zeros((H, W), dtype=np.float32)

    # Precompute blending window (patch_size x patch_size)
    # parabolic weighting
    # yy = np.linspace(-1, 1, patch_size)
    # xx = np.linspace(-1, 1, patch_size)
    # xv, yv = np.meshgrid(xx, yy)
    # w = (1 - (xv**2 + yv**2))
    # w = np.clip(w, 0, None)
    # w = w / (w.max() + 1e-12)  # normalize to 1

    # triangular weighting
    eps = 1e-6
    t = 1 - np.abs(np.linspace(-1, 1, patch_size))
    w = np.outer(t, t).astype(np.float32)
    w = w / (w.max() + 1e-12)
    w = np.clip(w, eps, None)   # <<< prevents zeros at patch edges


    # uniform weighting
    # w = np.ones((patch_size, patch_size), dtype=np.float32)

    # Compute core (crop) start positions so that last patch covers the image end
    y_starts = list(range(0, max(1, H - patch_size + 1), stride))
    x_starts = list(range(0, max(1, W - patch_size + 1), stride))
    # ensure last tile aligns to end
    if y_starts[-1] != max(0, H - patch_size):
        y_starts.append(max(0, H - patch_size))
    if x_starts[-1] != max(0, W - patch_size):
        x_starts.append(max(0, W - patch_size))

    # Helper to extract an inf_size patch centered on core at (y0,x0)
    def extract_inf_patch(img, core_y0, core_x0):
        # want core region [core_y0:core_y0+patch_size]
        inf_y0 = core_y0 - margin
        inf_x0 = core_x0 - margin
        inf_y1 = inf_y0 + inf_size
        inf_x1 = inf_x0 + inf_size

        # compute needed pads (top, bottom, left, right)
        pad_top = max(0, -inf_y0)
        pad_left = max(0, -inf_x0)
        pad_bottom = max(0, inf_y1 - H)
        pad_right = max(0, inf_x1 - W)

        # crop available region
        y0c = max(0, inf_y0)
        y1c = min(H, inf_y1)
        x0c = max(0, inf_x0)
        x1c = min(W, inf_x1)

        patch = img[y0c:y1c, x0c:x1c, :]

        # reflect-pad to exact shape
        if any([pad_top, pad_bottom, pad_left, pad_right]):
            patch = np.pad(
                patch,
                (
                    (pad_top, pad_bottom),
                    (pad_left, pad_right),
                    (0, 0),
                ),
                mode="reflect",
            )

        # safety: ensure shape
        assert patch.shape == (inf_size, inf_size, C), f"patch shape {patch.shape} != {(inf_size,inf_size,C)}"
        return patch

    # Collect patches in batches to predict
    batch_patches = []
    batch_places = []  # store (core_y0, core_x0) for each patch in batch

    for core_y0 in y_starts:
        for core_x0 in x_starts:
            patch = extract_inf_patch(image, core_y0, core_x0)
            batch_patches.append(patch)
            batch_places.append((core_y0, core_x0))

            # if batch full or last, run predict
            if len(batch_patches) == batch_size:
                batch_arr = np.stack(batch_patches, axis=0)
                preds = model.predict(batch_arr, verbose=0)
                # handle preds shape: (B, inf_size, inf_size, 1) or (B, inf_size, inf_size)
                if preds.ndim == 3:
                    preds = preds[..., np.newaxis]
                for i, (py, px) in enumerate(batch_places):
                    pred_full = preds[i]  # (inf_size, inf_size, channels)
                    core = pred_full[margin:margin + patch_size, margin:margin + patch_size, 0]
                    # placement coords in final image
                    yC0 = py
                    xC0 = px
                    yC1 = py + patch_size
                    xC1 = px + patch_size

                    # clip if at edges
                    y0_clip = max(0, yC0)
                    x0_clip = max(0, xC0)
                    y1_clip = min(H, yC1)
                    x1_clip = min(W, xC1)

                    cy0 = y0_clip - yC0
                    cx0 = x0_clip - xC0
                    cy1 = cy0 + (y1_clip - y0_clip)
                    cx1 = cx0 + (x1_clip - x0_clip)

                    prob_map[y0_clip:y1_clip, x0_clip:x1_clip] += core[cy0:cy1, cx0:cx1] * w[cy0:cy1, cx0:cx1]
                    weight_map[y0_clip:y1_clip, x0_clip:x1_clip] += w[cy0:cy1, cx0:cx1]

                # reset batch
                batch_patches = []
                batch_places = []

    # any remaining patches
    if batch_patches:
        batch_arr = np.stack(batch_patches, axis=0)
        preds = model.predict(batch_arr, verbose=0)
        if preds.ndim == 3:
            preds = preds[..., np.newaxis]
        for i, (py, px) in enumerate(batch_places):
            pred_full = preds[i]
            core = pred_full[margin:margin + patch_size, margin:margin + patch_size, 0]
            yC0 = py; xC0 = px; yC1 = py + patch_size; xC1 = px + patch_size
            y0_clip = max(0, yC0); x0_clip = max(0, xC0)
            y1_clip = min(H, yC1); x1_clip = min(W, xC1)
            cy0 = y0_clip - yC0; cx0 = x0_clip - xC0
            cy1 = cy0 + (y1_clip - y0_clip); cx1 = cx0 + (x1_clip - x0_clip)
            prob_map[y0_clip:y1_clip, x0_clip:x1_clip] += core[cy0:cy1, cx0:cx1] * w[cy0:cy1, cx0:cx1]
            weight_map[y0_clip:y1_clip, x0_clip:x1_clip] += w[cy0:cy1, cx0:cx1]

    # finalize
    prob_map = np.divide(prob_map, weight_map, out=np.zeros_like(prob_map), where=weight_map > 0)
    binary = (prob_map > best_threshold).astype(np.uint8)
    return binary


###################################
# Main body
###################################

output_folder = output_path / f'{model_timestamp}'
os.makedirs(output_folder, exist_ok=True)
model = keras.models.load_model(str(trained_model_path), compile=False)  # compile=False for inference only
timestamp = str(trained_model_path)[-12:-6]
with open(str(trained_model_path.parent / trained_model_path.stem) + '_metadata.json') as f:
    params = json.load(f)
best_threshold = params['global_best_threshold']

for image in input_files:
    print(f'Opening {image}...')
    start_time = time.time()
    with rasterio.open(str(image)) as src:
        img = src.read().transpose(1, 2, 0).astype(np.float32) / 255.0
        target_crs = src.crs
        target_transform = src.transform
        image_height = src.height
        image_width = src.width

    full_shape = (image_height, image_width)
    print(f' -> image shape: {full_shape}')
    map = sliding_window_predict(model, img, best_threshold,
                                      patch_size=256,
                                      inf_size=384,
                                      stride=200,
                                      batch_size=32)  # try 1,2,4,8 depending on GPU mem

    test_image_name = image.stem
    output_file = output_folder / (test_image_name + '_pred')

    # Save stitched mask
    with rasterio.open(
        str(output_file) + '.tif',
        'w',
        driver='GTiff',
        height=map.shape[0],
        width=map.shape[1],
        count=1,
        dtype=map.dtype,
        crs=target_crs,
        transform=target_transform,
        compress='DEFLATE',
        zlevel=9
#        tiled=True,
#        blockxsize=512,
#        blockysize=512
    ) as dst:
        dst.write(map, 1)
    print("✅ Stitched prediction saved to {}. Elapsed time was {:.3f} seconds.".format(output_path, time.time()-start_time))

