###############################################################################
# Script for classified map generation from input 4-band NAIP imagery using a 
# trained U-Net model. 
# Target: First Batch Testing (naip_batch_1)
###############################################################################
# Shahriar S. Heydari, May 2026, edited dcarver1

import os, json, time, gc
import numpy as np
from PIL import Image
from pathlib import Path
import rasterio
import tensorflow as tf
from tensorflow import keras
from math import ceil

patch_size = 256
stride = 200
inf_size = 384
naip_bands = 4

# Container-relative directory paths mapped to the first batch
input_naip_path = Path('/workspace/data/naip_batch_1')
trained_model_path = Path('/workspace/scripts/unet_classification_104341.keras') #dummy model created to test full wokrflow.
output_base_path = Path('/workspace/outputs/may24_runs')

model_timestamp = trained_model_path.stem.split('_')[-1]
output_folder = output_base_path / model_timestamp
os.makedirs(output_folder, exist_ok=True)

def sliding_window_predict(
    model,
    image,                      
    best_threshold=0.5,         
    patch_size=256,             
    inf_size=384,               
    stride=200,                 
    batch_size=32,              
):
    H, W, C = image.shape
    assert inf_size >= patch_size
    margin = (inf_size - patch_size) // 2

    prob_map = np.zeros((H, W), dtype=np.float32)
    weight_map = np.zeros((H, W), dtype=np.float32)

    eps = 1e-6
    t = 1 - np.abs(np.linspace(-1, 1, patch_size))
    w = np.outer(t, t).astype(np.float32)
    w = w / (w.max() + 1e-12)
    w = np.clip(w, eps, None)   

    y_starts = list(range(0, max(1, H - patch_size + 1), stride))
    x_starts = list(range(0, max(1, W - patch_size + 1), stride))
    if y_starts[-1] != max(0, H - patch_size):
        y_starts.append(max(0, H - patch_size))
    if x_starts[-1] != max(0, W - patch_size):
        x_starts.append(max(0, W - patch_size))

    def extract_inf_patch(img, core_y0, core_x0):
        inf_y0 = core_y0 - margin
        inf_x0 = core_x0 - margin
        inf_y1 = inf_y0 + inf_size
        inf_x1 = inf_x0 + inf_size

        pad_top = max(0, -inf_y0)
        pad_left = max(0, -inf_x0)
        pad_bottom = max(0, inf_y1 - H)
        pad_right = max(0, inf_x1 - W)

        y0c = max(0, inf_y0)
        y1c = min(H, inf_y1)
        x0c = max(0, inf_x0)
        x1c = min(W, inf_x1)

        patch = img[y0c:y1c, x0c:x1c, :]

        if any([pad_top, pad_bottom, pad_left, pad_right]):
            patch = np.pad(
                patch,
                ((pad_top, pad_bottom), (pad_left, pad_right), (0, 0)),
                mode="reflect",
            )
        return patch

    batch_patches = []
    batch_places = []  

    for core_y0 in y_starts:
        for core_x0 in x_starts:
            patch = extract_inf_patch(image, core_y0, core_x0)
            batch_patches.append(patch)
            batch_places.append((core_y0, core_x0))

            if len(batch_patches) == batch_size:
                batch_arr = np.stack(batch_patches, axis=0)
                preds = model.predict(batch_arr, verbose=0)
                if preds.ndim == 3:
                    preds = preds[..., np.newaxis]
                for i, (py, px) in enumerate(batch_places):
                    pred_full = preds[i]  
                    core = pred_full[margin:margin + patch_size, margin:margin + patch_size, 0]
                    yC0, xC0, yC1, xC1 = py, px, py + patch_size, px + patch_size
                    y0_clip, x0_clip = max(0, yC0), max(0, xC0)
                    y1_clip, x1_clip = min(H, yC1), min(W, xC1)
                    cy0, cx0 = y0_clip - yC0, x0_clip - xC0
                    cy1, cx1 = cy0 + (y1_clip - y0_clip), cx0 + (x1_clip - x0_clip)

                    prob_map[y0_clip:y1_clip, x0_clip:x1_clip] += core[cy0:cy1, cx0:cx1] * w[cy0:cy1, cx0:cx1]
                    weight_map[y0_clip:y1_clip, x0_clip:x1_clip] += w[cy0:cy1, cx0:cx1]

                batch_patches = []
                batch_places = []

    if batch_patches:
        batch_arr = np.stack(batch_patches, axis=0)
        preds = model.predict(batch_arr, verbose=0)
        if preds.ndim == 3:
            preds = preds[..., np.newaxis]
        for i, (py, px) in enumerate(batch_places):
            pred_full = preds[i]
            core = pred_full[margin:margin + patch_size, margin:margin + patch_size, 0]
            # Syntax correction applied here: commas instead of semicolons
            yC0, xC0, yC1, xC1 = py, px, py + patch_size, px + patch_size
            y0_clip, x0_clip = max(0, yC0), max(0, xC0)
            y1_clip, x1_clip = min(H, yC1), min(W, xC1)
            cy0, cx0 = y0_clip - yC0, x0_clip - xC0
            cy1, cx1 = cy0 + (y1_clip - y0_clip), cx0 + (x1_clip - x0_clip)
            prob_map[y0_clip:y1_clip, x0_clip:x1_clip] += core[cy0:cy1, cx0:cx1] * w[cy0:cy1, cx0:cx1]
            weight_map[y0_clip:y1_clip, x0_clip:x1_clip] += w[cy0:cy1, cx0:cx1]

    prob_map = np.divide(prob_map, weight_map, out=np.zeros_like(prob_map), where=weight_map > 0)
    binary = (prob_map > best_threshold).astype(np.uint8)
    return binary


###################################
# Main Loop Execution
###################################

print("Loading model...")
model = keras.models.load_model(str(trained_model_path), compile=False)

metadata_json_path = trained_model_path.parent / f"{trained_model_path.stem}_metadata.json"
if metadata_json_path.exists():
    with open(str(metadata_json_path)) as f:
        params = json.load(f)
    best_threshold = params.get('global_best_threshold', 0.5)
else:
    print(f"Warning: Metadata file not found at {metadata_json_path}. Falling back to default threshold 0.5")
    best_threshold = 0.5

print(f"Scanning workspace for NAIP images in {input_naip_path.name}...")
# Scan only within naip_batch_1
all_images = [p for p in input_naip_path.rglob('*.tif') if "modelOutputs" not in p.parts]
print(f"Found {len(all_images)} total images for this test run.")

for image_path in all_images:
    print(f'\nOpening {image_path.name}...')
    start_time = time.time()
    
    try:
        with rasterio.open(str(image_path)) as src: 
            img = src.read().transpose(1, 2, 0).astype(np.float32) / 255.0
            target_crs = src.crs
            target_transform = src.transform
            image_height = src.height
            image_width = src.width

        print(f' -> Image Shape: ({image_height}, {image_width})')

        map_out = sliding_window_predict(
            model, 
            img, 
            best_threshold,
            patch_size=patch_size,
            inf_size=inf_size,
            stride=stride,
            batch_size=32 # adjustment may be require with actually model being utilized as it will take up some amount of vram
        )

        output_image_name = f"{image_path.stem}_pred.tif"
        final_output_path = output_folder / output_image_name

        with rasterio.open(
            str(final_output_path),
            'w',
            driver='GTiff',
            height=map_out.shape[0],
            width=map_out.shape[1],
            count=1,
            dtype=map_out.dtype,
            crs=target_crs,
            transform=target_transform
        ) as dst:
            dst.write(map_out, 1)
            
        print(f"Saved prediction to: {final_output_path.name}")
        print(f"Elapsed time: {time.time() - start_time:.1f} seconds.")
	# clear out image to maintain lower overall memory allocation
        del img
        del map_out
        gc.collect()
    except Exception as e:
        print(f"Error processing file {image_path.name}: {str(e)}")

print("\nAll map generation jobs complete.")
