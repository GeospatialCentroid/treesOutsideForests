###############################################################################
# Script for training and testing a U-Net model using 4-band NAIP imagery.
###############################################################################
# Shahriar S. Heydari, May 2026

import os, json
from pathlib import Path
from datetime import datetime
import numpy as np
import matplotlib.pyplot as plt
import rasterio
import random
import tensorflow as tf
from tensorflow import keras
from keras.layers import Input

os.environ['SM_FRAMEWORK'] = 'tf.keras'
import segmentation_models as sm
from PIL import Image
from sklearn.metrics import f1_score, accuracy_score

naip_bands = 4
train_images_path = Path('D:/Shahriar/Work_Datasets/Agroforestry/matched_naip_validation_final/training').glob('*naip.tif')
train_masks_path = Path('D:/Shahriar/Work_Datasets/Agroforestry/matched_naip_validation_final/training').glob('*mask.tif')
val_images_path = Path('D:/Shahriar/Work_Datasets/Agroforestry/matched_naip_validation_final/validation').glob('*naip.tif')
val_masks_path = Path('D:/Shahriar/Work_Datasets/Agroforestry/matched_naip_validation_final/validation').glob('*mask.tif')
test_images_path = Path('D:/Shahriar/Work_Datasets/Agroforestry/matched_naip_validation_final/test').glob('*naip.tif')
test_masks_path = Path('D:/Shahriar/Work_Datasets/Agroforestry/matched_naip_validation_final/test').glob('*mask.tif')
trained_model_path = None  # Path(r'D:\Shahriar\Work_Datasets\Agroforestry\Unet_test\training_outputs\20250923\unet_classification_111347.keras')
dayStamp = datetime.now().strftime("%Y%m%d")
output_dir = Path(f"D:/Shahriar/Work_Datasets/Agroforestry/Unet_test/training_outputs/{dayStamp}")
base_name = "unet_classification"  # change this to your project name
os.makedirs(output_dir, exist_ok=True)

min_epochs = 1
max_epochs = 5
model_fit_verbose = 2
min_delta = 0.01
patience = 2

patch_size = 256
stride = 256
foreground_threshold = 0.5
batch_size = 32
augment_flag = True
mask_noData = 255
img_noData = np.nan
num_f1_thresholds = 25

# only Adam and RMSprop supported
# optimizer_config = {
#     "name": "Adam",
#     "learning_rate": 5e-5,
#     "clipnorm": 1.0,
#     "amsgrad": True,
#     "beta_1": 0.9,
#     "beta_2": 0.999,
#     "epsilon": 1e-7
# }
optimizer_config = {
   "name": "RMSprop",
   "learning_rate": 1e-4,
   "clipnorm": 1.0,
}

OPTIMIZERS = {
    "Adam": tf.keras.optimizers.Adam,
    "RMSprop": tf.keras.optimizers.RMSprop
}


#################################################
# Helper functions and classes
#################################################

def read_image(path):
    with rasterio.open(path) as src:
        img = src.read()  # (bands, H, W)
        img = np.transpose(img, (1, 2, 0))  # → (H, W, bands)
    return img


def read_mask(path):
    with rasterio.open(path) as src:
        mask = src.read(1)  # read first band only → (H, W)
    mask = np.expand_dims(mask, axis=-1)  # → (H, W, 1)
    return mask

def compute_test_metrics(model, dataset, threshold):
    y_true_all = []
    y_pred_all = []

    for x, y in dataset:
        probs = model(x, training=False)
        probs = tf.squeeze(probs, axis=-1)

        y_true_all.append(y.numpy().ravel())
        y_pred_all.append((probs.numpy().ravel() >= threshold).astype(np.uint8))

    y_true_all = np.concatenate(y_true_all)
    y_pred_all = np.concatenate(y_pred_all)

    acc = accuracy_score(y_true_all, y_pred_all)
    f1  = f1_score(y_true_all, y_pred_all)

    return acc, f1

class PatchDataset:
    def __init__(self, image_files, mask_files,
                 patch_size=256, stride=128,
                 foreground_thresh=0.05, augment=False, test_data_flag=False):
        self.patch_size = patch_size
        self.stride = stride
        self.augment = augment
        self.test_data_flag = test_data_flag

        # Load images into memory (can be swapped for lazy load)
        self.images = [read_image(f) for f in image_files]
        self.masks = [read_mask(f) for f in mask_files]
        self.image_file_names = [Path(f).stem for f in image_files]

        # Build patch index with filtering
        self.index = self.build_index(foreground_thresh)

    def build_index(self, fg_thresh):
        fg_patches, bg_patches, all_patches = [], [], []

        for img_id, mask in enumerate(self.masks):
            img = self.images[img_id]  # corresponding image
            H, W, C = img.shape
            H2, W2, C2 = mask.shape
            fname = self.image_file_names[img_id]
            if (H != H2) or (W != W2):
                print(f'mask/image mismatch for file {fname}, H={H}, H2={H2}, W={W}, W2={W2}')
            if C != naip_bands:
                print(f'Image {fname} has different number of bands than it should be, therefore it was skipped.')
                continue
            for y in range(0, H - self.patch_size + 1, self.stride):
                for x in range(0, W - self.patch_size + 1, self.stride):
                    mask_patch = mask[y:y + self.patch_size, x:x + self.patch_size]
                    img_patch = img[y:y + self.patch_size, x:x + self.patch_size]

                    # Skip if mask contains NoData
                    if (mask_patch == mask_noData).any():
                        continue

                    # Skip if image patch contains NaNs
                    if np.isnan(img_patch).any():
                        continue

                    # Optional: skip if image patch is all zeros (completely empty)
                    if np.all(img_patch == 0):
                        continue

                    record = (img_id, x, y, fname)  # , noData_flag, fg_ratio))

                    if self.test_data_flag:
                        all_patches.append(record)
                    else:
                        fg_ratio = (mask_patch > 0).mean()
                        if fg_ratio >= fg_thresh:
                            fg_patches.append(record)
                        elif fg_ratio == 0:
                            bg_patches.append(record)

        if not self.test_data_flag:
            # Balance background vs foreground
            n = len(fg_patches)
            bg_sample = random.sample(bg_patches, min(n, len(bg_patches)))
            all_patches = fg_patches + bg_sample

        random.shuffle(all_patches)
        return all_patches

    def generator(self):
        for img_id, x, y, fname in self.index:
            img = self.images[img_id][y:y + self.patch_size, x:x + self.patch_size]
            mask = self.masks[img_id][y:y + self.patch_size, x:x + self.patch_size]

            # Normalize image to [0,1]
            img = img.astype(np.float32) / 255.0
            mask = mask.astype(np.float32)

            yield img, mask, fname

    def get_tf_dataset(self, batch_size=8, shuffle=True, repeat=True):
        ds = tf.data.Dataset.from_generator(
            self.generator,
            output_signature=(
                tf.TensorSpec(shape=(self.patch_size, self.patch_size, naip_bands), dtype=tf.float32),
                tf.TensorSpec(shape=(self.patch_size, self.patch_size, 1), dtype=tf.float32),
                tf.TensorSpec(shape=(), dtype=tf.string)  # file name
            )
        )
        if shuffle:
            ds = ds.shuffle(buffer_size=2048)  # len(self.index))

        if self.augment:
            # Apply augmentations only to img,mask
            def aug(img, mask, fname):
                img, mask = self.augment_fn(img, mask)
                return img, mask, fname

            ds = ds.map(aug, num_parallel_calls=tf.data.AUTOTUNE)

        if repeat:
            ds = ds.repeat().batch(batch_size).prefetch(tf.data.AUTOTUNE)
        else:
            ds = ds.batch(batch_size).prefetch(tf.data.AUTOTUNE)

        return ds

    def augment_fn(self, img, mask):

        # Random flip
        if tf.random.uniform(()) > 0.5:
            img = tf.image.flip_left_right(img)
            mask = tf.image.flip_left_right(mask)
        if tf.random.uniform(()) > 0.5:
            img = tf.image.flip_up_down(img)
            mask = tf.image.flip_up_down(mask)

        # Random 90° rotation
        k = tf.random.uniform((), minval=0, maxval=4, dtype=tf.int32)
        img = tf.image.rot90(img, k)
        mask = tf.image.rot90(mask, k)

        # # Random color jitter (image/RGB bands only)
        # img is float32 in [0,1]
        rgb = img[..., :3]
        nir = img[..., 3:]
        rgb = tf.image.random_brightness(rgb, max_delta=0.1)  # Random brightness: ±0.1 (10% of range)
        rgb = tf.image.random_contrast(rgb, lower=0.8, upper=1.2)  # Random contrast: 80–120%
        rgb = tf.image.random_hue(rgb, 0.05)  # Random hue: ±0.05
        img = tf.concat([rgb, nir], axis=-1)

        img = tf.clip_by_value(img, 0.0, 1.0)  # Clip to [0,1]
        mask = tf.where(mask > 0, 1.0, 0.0)  # Ensure mask stays {0,1}

        return img, mask

class GlobalF1BestThresholdCallback(tf.keras.callbacks.Callback):
    """
    Computes global F1 on the validation set at each epoch by sweeping thresholds,
    and stores the best F1 and corresponding threshold in logs.
    Can be used with EarlyStopping.
    """

    def __init__(self, val_dataset, val_steps, n_thresholds=50, metric_name="val_global_f1"):
        super().__init__()
        self.val_dataset = val_dataset
        self.metric_name = metric_name
        self.val_steps = val_steps
        self.n_thresholds = n_thresholds
        self.best_threshold = None
        self.best_f1 = None

    # def on_epoch_end(self, epoch, logs=None):
    #
    #     thresholds = np.linspace(0, 1, self.n_thresholds)
    #     tp = np.zeros_like(thresholds, dtype=np.int64)
    #     fp = np.zeros_like(thresholds, dtype=np.int64)
    #     fn = np.zeros_like(thresholds, dtype=np.int64)
    #
    #     for x, y in self.val_dataset.take(self.val_steps):  # batches
    #         probs = model(x, training=False).numpy().ravel()
    #         labels = y.numpy().ravel()
    #         preds_all = (probs[None, :] > thresholds[:, None])
    #         tp += (preds_all & (labels[None, :] == 1)).sum(axis=1)
    #         fp += (preds_all & (labels[None, :] == 0)).sum(axis=1)
    #         fn += ((~preds_all) & (labels[None, :] == 1)).sum(axis=1)
    #
    #     precision = tp / np.maximum(tp + fp, 1)
    #     recall = tp / np.maximum(tp + fn, 1)
    #     f1 = 2 * precision * recall / np.maximum(precision + recall, 1e-9)
    #
    #     best_idx = np.argmax(f1)
    #     best_threshold = thresholds[best_idx]
    #     best_f1 = f1[best_idx]
    #
    #     # store into logs for EarlyStopping
    #     if logs is not None:
    #         logs[self.metric_name] = best_f1
    #         logs[self.metric_name + "_threshold"] = best_threshold
    #
    #     # print(f"\nEpoch {epoch + 1} – {self.metric_name}={best_f1:.4f} at threshold={best_threshold:.3f}")

    def on_train_end(self, logs=None):
        print("\nComputing GLOBAL validation F1 once (after early stopping)...")

        thresholds = np.linspace(0, 1, self.n_thresholds)
        tp = np.zeros_like(thresholds, dtype=np.int64)
        fp = np.zeros_like(thresholds, dtype=np.int64)
        fn = np.zeros_like(thresholds, dtype=np.int64)

        for x, y in self.val_dataset.take(self.val_steps):  # batches
            probs = model(x, training=False).numpy().ravel()
            labels = y.numpy().ravel()
            preds_all = (probs[None, :] > thresholds[:, None])
            tp += (preds_all & (labels[None, :] == 1)).sum(axis=1)
            fp += (preds_all & (labels[None, :] == 0)).sum(axis=1)
            fn += ((~preds_all) & (labels[None, :] == 1)).sum(axis=1)

        precision = tp / np.maximum(tp + fp, 1)
        recall = tp / np.maximum(tp + fn, 1)
        f1 = 2 * precision * recall / np.maximum(precision + recall, 1e-9)

        best_idx = np.argmax(f1)
        best_threshold = thresholds[best_idx]
        best_f1 = f1[best_idx]

        self.best_f1 = best_f1
        self.best_threshold = best_threshold

        print(f"✔ Best GLOBAL val F1: {best_f1:.4f} at threshold={best_threshold:.3f}")

def check_dataset(ds, max_batches=100):
    """
    Checks a tf.data.Dataset for NaNs, Infs, and unexpected mask values.
    Args:
        ds: tf.data.Dataset yielding (image, mask)
        max_batches: max number of batches to check
    """
    for i, (img_batch, mask_batch, filenames_batch) in enumerate(ds.take(max_batches)):
        # Check image
        if np.isnan(img_batch.numpy()).any() or np.isinf(img_batch.numpy()).any():
            print(f"NaN or Inf detected in images at batch {i}")
            return False
        if img_batch.numpy().min() < 0 or img_batch.numpy().max() > 1:
            print(f"Image values out of [0,1] range at batch {i}")
            return False

        # Check mask
        unique_vals = np.unique(mask_batch.numpy())
        if not np.all(np.isin(unique_vals, [0, 1])):
            print(f"Unexpected mask values {unique_vals} at batch {i}")
            return False

    print("Dataset looks clean!")
    return True


def record_results(history, final_stat, run_params, plot_path, metadata_path):

    def make_json_safe(obj):
        if isinstance(obj, (np.generic,)):  # np.float32, np.int64 etc.
            return obj.item()
        if isinstance(obj, (np.ndarray,)):
            return obj.tolist()
        # add more cases if needed
        return obj

    loss = history['loss']
    val_loss = history['val_loss']
    acc = history['accuracy']
    val_f1_score = history['val_f1-score']

    epochs = range(1, len(loss) + 1)

    # epoch to start patience, assuming early stopping has happened for sure
    terminate_val_f1_epoch = len(epochs) - run_params['early_stopping']['patience']

    fig, axes = plt.subplots(2, 2, figsize=(12, 8))

    # Train loss
    axes[0, 0].plot(epochs, loss, 'b-', label='Train Loss')
    axes[0, 0].set_title("Training Loss")
    axes[0, 0].set_xlabel("Epochs")
    axes[0, 0].set_ylabel("Loss")
    axes[0, 0].legend()
    axes[0, 0].grid(True)

    # Validation loss
    axes[0, 1].plot(epochs, val_loss, 'r-', label='Validation Loss')
    axes[0, 1].set_title("Validation Loss")
    axes[0, 1].set_xlabel("Epochs")
    axes[0, 1].set_ylabel("Loss")
    axes[0, 1].legend()
    axes[0, 1].grid(True)

    # Train Accuracy
    axes[1, 0].plot(epochs, acc, 'b-', label='Train Accuracy')
    axes[1, 0].set_title("Training Accuracy")
    axes[1, 0].set_xlabel("Epochs")
    axes[1, 0].set_ylabel("Accuracy")
    axes[1, 0].legend()
    axes[1, 0].grid(True)

    # Validation Accuracy
    axes[1, 1].plot(epochs, val_f1_score, 'r-', label='Validation F1 score')
    axes[1, 1].scatter(terminate_val_f1_epoch, val_loss[terminate_val_f1_epoch - 1],
                       color='black', marker='o', s=60, label='Early stopping Epoch')
    axes[1, 1].set_title("Validation F1 score")
    axes[1, 1].set_xlabel("Epochs")
    axes[1, 1].set_ylabel("F1 score")
    axes[1, 1].legend()
    axes[1, 1].grid(True)

    plt.suptitle("Training Progress", fontsize=16)
    plt.tight_layout()
    plt.savefig(str(plot_path), dpi=300)

    # Early-stopping performance values
    es_params = {}
    for key in history.keys():
        es_params[key] = float(history[key][terminate_val_f1_epoch - 1])

    params = {
        "patch_size": patch_size,
        "stride": stride,
        "foreground_threshold": foreground_threshold,
        "batch_size": batch_size,
        "augment_flag": augment_flag,
        "number of training patches": run_params['num_training_patches'],
        "number of validation patches": run_params['num_validation_patches'],
        "optimizer": run_params['optimizer_params'],
        "early_stopping": run_params['early_stopping'],
        "training_start": start_time.isoformat(),
        "training_end": end_time.isoformat(),
        "elapsed_time": elapsed.total_seconds(),
        "epochs_run": len(history['loss']),
        "early_stopping_point_performance": es_params,
        "global_F1_value": final_stat['best_f1'],
        "global_best_threshold": final_stat['best_threshold'],
        "test_dataset_accuracy": final_stat['test_acc'],
        "test_dataset_F1_value": final_stat['test_f1']
    }

    with open(str(metadata_path), "w") as f:
        json.dump(params, f, indent=2, default=make_json_safe)


#################################################
# Main body
#################################################

start_time = datetime.now()

if trained_model_path is not None:

    model = keras.models.load_model(str(trained_model_path), compile=False)  # compile=False for inference only
    timestamp = str(trained_model_path)[-12:-6]
    with open(str(trained_model_path.parent / trained_model_path.stem) + '_metadata.json') as f:
        params = json.load(f)
        global_best_threshold = params['global_best_threshold']

    print('Creating test dataset...')
    test_image_files = [str(p) for p in test_images_path]
    test_image_files.sort()
    test_mask_files = [str(p) for p in test_masks_path]
    test_mask_files.sort()

    test_patches = PatchDataset(test_image_files, test_mask_files,
                               patch_size=patch_size, stride=patch_size,
                               foreground_thresh=foreground_threshold,
                               augment=False, test_data_flag=True)

    num_test_patches = len(test_patches.index)
    print("Number of extracted test patches:", num_test_patches)

    test_dataset = test_patches.get_tf_dataset(batch_size, shuffle=False, repeat=False)
    test_ds = test_dataset.map(lambda img, mask, fname: (img, mask))

    test_acc, test_f1 = compute_test_metrics(
        model,
        test_ds,
        threshold=global_best_threshold
    )
    print('Test data accuracy: {:.3f}, test data F1 value: {:.3f}.'.format(test_acc, test_f1))

else:

    print('Creating train/validation/test dataset...')

    train_image_files = [str(p) for p in train_images_path]
    train_image_files.sort()
    train_mask_files = [str(p) for p in train_masks_path]
    train_mask_files.sort()

    # check noData values for the first image and mask and update corresponding variables if needed, assuming
    # the same setting for all images and masks
    with rasterio.open(train_image_files[0]) as src:
        img_noData = src.nodata
    with rasterio.open(train_mask_files[0]) as src:
        mask_noData = src.nodata

    train_patches = PatchDataset(train_image_files, train_mask_files,
                                 patch_size=patch_size, stride=stride,
                                 foreground_thresh=foreground_threshold,
                                 augment=augment_flag)
    num_train_patches = len(train_patches.index)
    print("Number of extracted training patches:", num_train_patches)
    steps_per_epoch = num_train_patches // batch_size

    val_image_files = [str(p) for p in val_images_path]
    val_image_files.sort()
    val_mask_files = [str(p) for p in val_masks_path]
    val_mask_files.sort()

    val_patches = PatchDataset(val_image_files, val_mask_files,
                               patch_size=patch_size, stride=stride,
                               foreground_thresh=foreground_threshold,
                               augment=False)

    num_val_patches = len(val_patches.index)
    print("Number of extracted validation patches:", num_val_patches)
    validation_steps = num_val_patches // batch_size

    test_image_files = [str(p) for p in test_images_path]
    test_image_files.sort()
    test_mask_files = [str(p) for p in test_masks_path]
    test_mask_files.sort()

    test_patches = PatchDataset(test_image_files, test_mask_files,
                               patch_size=patch_size, stride=patch_size,
                               foreground_thresh=foreground_threshold,
                               augment=False, test_data_flag=True)

    num_test_patches = len(test_patches.index)
    print("Number of extracted test patches:", num_test_patches)

    # Create TensorFlow datasets
    train_dataset = train_patches.get_tf_dataset(batch_size, shuffle=True, repeat=True)
    val_dataset = val_patches.get_tf_dataset(batch_size, shuffle=False, repeat=False)
    test_dataset = test_patches.get_tf_dataset(batch_size, shuffle=False, repeat=False)
    val_dataset_copy = val_patches.get_tf_dataset(batch_size, shuffle=False, repeat=False)

    # Run the check on training dataset
    # print('Checking 100 random patches from train and validation datasets...')
    # check_dataset(train_dataset)
    # check_dataset(val_dataset)

    # Create datasets without file names for training
    train_ds = train_dataset.map(lambda img, mask, fname: (img, mask))
    val_ds = val_dataset.map(lambda img, mask, fname: (img, mask))
    test_ds = test_dataset.map(lambda img, mask, fname: (img, mask))
    val_for_metric = val_dataset_copy.map(lambda img, mask, fname: (img, mask))

    opt_name = optimizer_config.pop("name")
    optimizer = OPTIMIZERS[opt_name](**optimizer_config)

    run_params = {
        'num_training_patches': num_train_patches,
        'num_validation_patches': num_val_patches,
        "min_epochs": min_epochs,
        "max_epochs": max_epochs,
        "early_stopping": {
            "min_delta": min_delta,
            "patience": patience
        },
        "optimizer_params": {"name": opt_name, **optimizer_config}
        # Add again the optimizer name that was dropped by pop
    }

    model = sm.Unet(
        backbone_name="resnet34",
        input_shape=(None, None, naip_bands),
        encoder_weights=None,
        classes=1,
        activation="sigmoid",
    )

    for layer in model.layers:
        if isinstance(layer, tf.keras.layers.BatchNormalization):
            layer.trainable = False

    # Define the two base losses
    bce = sm.losses.BinaryCELoss()
    dice = sm.losses.DiceLoss()


    # Define a combined loss function
    def bce_dice_loss(y_true, y_pred):
        return 0.5 * bce(y_true, y_pred) + 0.5 * dice(y_true, y_pred)


    optimizer = tf.keras.optimizers.Adam(
        learning_rate=run_params['optimizer_params']['learning_rate'],
        clipnorm=run_params['optimizer_params'].get("clipnorm", None)
    )

    # Compile the model
    model.compile(
        optimizer=optimizer,  # tf.keras.optimizers.RMSprop(1e-5),#, clipnorm=1.0),
        loss=bce_dice_loss,  # sm.losses.BinaryFocalLoss() , sm.losses.DiceLoss(), sm.losses.BinaryCELoss()
        metrics=[
            'accuracy',  # pixel-wise accuracy
            sm.metrics.FScore(),
            sm.metrics.IOUScore(),
            # sm.metrics.FScore(threshold=0.1, name="f1_10"),
        ]
    )

    # Callbacks
    early_stop = tf.keras.callbacks.EarlyStopping(
        monitor='val_f1-score',
        min_delta=run_params['early_stopping']['min_delta'],
        patience=run_params['early_stopping']['patience'],
        mode='max',
        restore_best_weights=True
    )
    globalF1_cb = GlobalF1BestThresholdCallback(val_for_metric, validation_steps, n_thresholds=num_f1_thresholds)

    # Train
    # First set of epochs (no early stopping)
    history1 = model.fit(
        train_ds,
        validation_data=val_ds,
        epochs=min_epochs,
        # callbacks=[val_cb],
        steps_per_epoch=steps_per_epoch,
        validation_steps=validation_steps,
        verbose=model_fit_verbose
    )

    # Then continue with EarlyStopping
    history2 = model.fit(
        train_ds,
        validation_data=val_ds,
        epochs=max_epochs,  # max total epochs
        initial_epoch=min_epochs,  # start from minimum-epoch-trained model
        callbacks=[early_stop, globalF1_cb],
        steps_per_epoch=steps_per_epoch,
        validation_steps=validation_steps,
        verbose=model_fit_verbose
    )

    combined_history = {}
    for key in history2.history.keys():
        try:
            combined_history[key] = history1.history[key] + history2.history[key]
        except:
            combined_history[key] = history2.history[key]

    global_best_threshold = globalF1_cb.best_threshold
    test_acc, test_f1 = compute_test_metrics(
        model,
        test_ds,
        threshold=global_best_threshold
    )
    print('Test data accuracy: {:.3f}, test data F1 value: {:.3f}.'.format(test_acc, test_f1))
    final_statistics = {
        "best_f1": globalF1_cb.best_f1,
        "best_threshold": globalF1_cb.best_threshold,
        "test_acc": test_acc,
        "test_f1": test_f1
    }

    end_time = datetime.now()
    elapsed = end_time - start_time  # timedelta object

    timestamp = datetime.now().strftime("%H%M%S")
    # ==== Save final model ====
    model_path = os.path.join(output_dir, f"{base_name}_{timestamp}.keras")
    model.save(model_path)
    print(f"✅ Final model saved to {model_path}")

    # ==== Plot training progress ====
    plot_path = output_dir / f"{base_name}_{timestamp}_plot.png"
    summary_path = output_dir / f"{base_name}_{timestamp}_metadata.json"
    record_results(combined_history, final_statistics, run_params, plot_path, summary_path)



