import ee
import geemap
import time
from agroforestry.config import *
from googleapiclient.discovery import build
from google_auth_oauthlib.flow import InstalledAppFlow
from google.auth.transport.requests import Request
import os, pickle

ee.Initialize(project='steam-mantis-359002')
# targetGridIDs = ["X12-"+str(x) for x in [558, 559, 560, 561, 562, 603, 604, 605, 606, 607, 648, 649, 650, 651, 652]]
targetGridIDs = [121]#range(725,774,4)
# targetGridIDs = ["X12-"+str(x) for x in range(1,774,4)]#[36, 92, 138, 146, 346, 514, 538, 551, 571]]
years = [2016, 2020]
GDriveFolder = 'G:\\My Drive'
DestinationFolder = 'D:\\Shahriar\\Work_Datasets\\Agroforestry\\NAIP_download'

# Scope for full Drive access
SCOPES = ['https://www.googleapis.com/auth/drive']

# Authenticate and create the Drive API service
def get_drive_service():
    creds = None
    if os.path.exists('token.pickle'):
        with open('token.pickle', 'rb') as token:
            creds = pickle.load(token)
    if not creds or not creds.valid:
        if creds and creds.expired and creds.refresh_token:
            creds.refresh(Request())
        else:
            flow = InstalledAppFlow.from_client_secrets_file('OAuth_credentials.json', SCOPES)
            creds = flow.run_local_server(port=0)
        with open('token.pickle', 'wb') as token:
            pickle.dump(creds, token)
    return build('drive', 'v3', credentials=creds)

def empty_trash():
    service = get_drive_service()
    service.files().emptyTrash().execute()
    print("🗑️ Trash emptied successfully!")


def get_annual_NAIP(year):
    try:
        collection = ee.ImageCollection("USDA/NAIP/DOQQ")
        start_date = ee.Date.fromYMD(year, 1, 1)
        end_date = ee.Date.fromYMD(year, 12, 31)
        naip = collection.filterDate(start_date, end_date).filter(
            ee.Filter.listContains("system:band_names", "N")
        )
        return ee.ImageCollection(naip)
    except Exception as e:
        print(e)


for targetGridID in targetGridIDs:
    for year in years:
        start_time = time.time()
        targetGrid = geemap.gdf_to_ee(grid.loc[grid.Unique_ID == ("X12-"+str(targetGridID))])
        # generate NAIP layer
        naip_collection = get_annual_NAIP(year).filterBounds(targetGrid.geometry())
        naip_mosaic = naip_collection.mosaic()
        export_file_name = "X12-"+str(targetGridID) + "_" + str(year) + "_mosaic"
        print("Saving to Google Drive:", export_file_name)
        task1 = ee.batch.Export.image.toDrive(
            image=naip_mosaic.float(),
            description=export_file_name,
            region=targetGrid.geometry(),
            scale=1,
            maxPixels=1e13
        )
        task1.start()

        targetGrid = geemap.gdf_to_ee(grid.loc[grid.Unique_ID == ("X12-"+str(targetGridID+1))])
        # generate NAIP layer
        naip_collection = get_annual_NAIP(year).filterBounds(targetGrid.geometry())
        naip_mosaic = naip_collection.mosaic()
        export_file_name = "X12-"+str(targetGridID+1) + "_" + str(year) + "_mosaic"
        print("Saving to Google Drive:", export_file_name)
        task2 = ee.batch.Export.image.toDrive(
            image=naip_mosaic.float(),
            description=export_file_name,
            region=targetGrid.geometry(),
            scale=1,
            maxPixels=1e13
        )
        task2.start()

        targetGrid = geemap.gdf_to_ee(grid.loc[grid.Unique_ID == ("X12-"+str(targetGridID+2))])
        # generate NAIP layer
        naip_collection = get_annual_NAIP(year).filterBounds(targetGrid.geometry())
        naip_mosaic = naip_collection.mosaic()
        export_file_name = "X12-"+str(targetGridID+2) + "_" + str(year) + "_mosaic"
        print("Saving to Google Drive:", export_file_name)
        task3 = ee.batch.Export.image.toDrive(
            image=naip_mosaic.float(),
            description=export_file_name,
            region=targetGrid.geometry(),
            scale=1,
            maxPixels=1e13
        )
        task3.start()

        targetGrid = geemap.gdf_to_ee(grid.loc[grid.Unique_ID == ("X12-"+str(targetGridID+3))])
        # generate NAIP layer
        naip_collection = get_annual_NAIP(year).filterBounds(targetGrid.geometry())
        naip_mosaic = naip_collection.mosaic()
        export_file_name = "X12-"+str(targetGridID+3) + "_" + str(year) + "_mosaic"
        print("Saving to Google Drive:", export_file_name)
        task4 = ee.batch.Export.image.toDrive(
            image=naip_mosaic.float(),
            description=export_file_name,
            region=targetGrid.geometry(),
            scale=1,
            maxPixels=1e13
        )
        task4.start()
        print(' - Waiting for data export completion...')
        while ((task1.status()['state'] not in ['COMPLETED', 'FAILED']) or
               (task2.status()['state'] not in ['COMPLETED', 'FAILED']) or
               (task3.status()['state'] not in ['COMPLETED', 'FAILED']) or
               (task4.status()['state'] not in ['COMPLETED', 'FAILED'])):
            time.sleep(30)
        print('Execution time was {:.0f} seconds'.format(time.time()-start_time))

    time.sleep(120)
    # moving last copied files
    try:
        print('Moving downloaded files from Google Drive to destination...')
        os.system('move /Y "' + GDriveFolder + '\\*.tif" ' + DestinationFolder + '> null')
        time.sleep(30)
        empty_trash()
        # _ = input('Please empty GDrive trash and press ENTER.')
    except:
        print(' -> File move FAILED')
        _ = input('Please move files manually to destination folder and empty GDrive trash, then press ENTER.')

        # naipEE = geemap.get_annual_NAIP(year).filterBounds(targetGrid.geometry()).toList(1000)
        # N = naipEE.length().getInfo()
        # for i in range(N):
        #     naipImage = ee.Image(naipEE.get(i))
        #     naip_scale = naipImage.projection().nominalScale().getInfo()
        #     naip_ID = naipImage.get('system:index').getInfo()
        #     print("Saving to Google Drive: " + str(targetGridID) + "_" + str(i) + "_" + naip_ID + ", scale=" + str(naip_scale))
        #     # export image to asset
        #     task = ee.batch.Export.image.toDrive(
        #         image=naipImage.float(),
        #         description=str(targetGridID) + "_" + str(i) + "_" + naip_ID,
        #         region=targetGrid.geometry(),
        #         scale=naip_scale,
        #         # crs= naipEE.projection(),
        #         maxPixels=1e13
        #     )
        #     task.start()
        #     print(' - Waiting for static data export completion...')
        #     while (task.status()['state'] not in ['COMPLETED', 'FAILED']):
        #         time.sleep(30)

# Runtime starting at 9/29/2025, 8:00pm
# C:\Users\sheydari\Python39-Agroforestry\Scripts\python.exe "C:\Users\sheydari\OneDrive - Colostate\Ogle\python\Agroforestry\downloadNAIP.py"
# Saving to Google Drive: X12-571_2010_mosaic
#  - Waiting for data export completion...
# Execution time was 996 seconds
# Saving to Google Drive: X12-346_2010_mosaic
#  - Waiting for data export completion...
# Execution time was 573 seconds
# Saving to Google Drive: X12-538_2010_mosaic
#  - Waiting for data export completion...
# Execution time was 603 seconds
# Saving to Google Drive: X12-551_2010_mosaic
#  - Waiting for data export completion...
# Execution time was 573 seconds
# Saving to Google Drive: X12-138_2010_mosaic
#  - Waiting for data export completion...
# Execution time was 1959 seconds
# Saving to Google Drive: X12-514_2010_mosaic
#  - Waiting for data export completion...
# Execution time was 512 seconds
# Saving to Google Drive: X12-146_2010_mosaic
#  - Waiting for data export completion...
# Execution time was 1025 seconds
# Saving to Google Drive: X12-36_2010_mosaic
#  - Waiting for data export completion...
# Execution time was 633 seconds
# Saving to Google Drive: X12-92_2010_mosaic
#  - Waiting for data export completion...
# Execution time was 904 seconds

# Let's say each grid/year needs 1000 seconds to download and occupies 1.8GB.
# for 773 grid cells (1 year): execution time will be about 240 hours (10 days, but consider at least two weeks for file
# copying/run management) and the space required will be about 1.4TB.
# Due to limited Google Drive space
