import requests
import pystac_client
import planetary_computer
from pyproj import Transformer

# 1. Your original UTM coordinates (Example: UTM Zone 18N / EPSG:32618)
# If your previous bounds were in a different UTM zone, update the EPSG code!
# transformer = Transformer.from_crs("epsg:32618", "epsg:4326", always_xy=True)

# Transform min and max corners from UTM to WGS 84 (Lon, Lat)
# min_lon, min_lat = transformer.transform(596500.968, 4834492.478)
# max_lon, max_lat = transformer.transform(597537.968, 4835520.478)

# 2. Define the STAC-compliant bounding box
# bbox_wgs84 = [min_lon, min_lat, max_lon, max_lat]
bbox_wgs84 = [-100.0486762934719849, 45.8187986561736906, -100.0352846224545971, 45.8281873214498248]
year = 2016

# 3. Query the Planetary Computer
catalog = pystac_client.Client.open(
    "https://planetarycomputer.microsoft.com/api/stac/v1",
    modifier=planetary_computer.sign_inplace
)

search = catalog.search(
    collections=["naip"],
    bbox=bbox_wgs84,
    datetime=f"{year}-01-01/{year}-12-31" # Specify your timeframe
)

items = search.item_collection()

if len(items) == 0:
    print("No NAIP scenes found for this bounding box and timeframe.")
else:
    print(f"Found {len(items)} matching scenes. Downloading the first item...")

    # Grab the first matching scene
    item = items[0]

    # NAIP stores the full 4-band image under the asset key 'image'
    image_asset = item.assets["image"]

    # The signed URL grants access to download the file from Azure Blob Storage
    download_url = image_asset.href

    # Define your local output path
    output_filename = f"{item.id}.tif"
    print(f"Downloading file: {output_filename}")

    # 3. Stream the file to disk using requests
    with requests.get(download_url, stream=True) as response:
        response.raise_for_status()  # Check for HTTP errors

        with open(output_filename, "wb") as f:
            for chunk in response.iter_content(chunk_size=8192):
                if chunk:
                    f.write(chunk)

    print(f"Download complete! Saved as: {output_filename}")