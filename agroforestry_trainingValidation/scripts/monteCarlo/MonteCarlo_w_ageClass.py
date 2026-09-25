import rasterio
import numpy as np
import os, time, sys
import pandas as pd
import geopandas as gpd
from pathlib import Path

# COT values definition:
# 0: no tree in all years
# 1: tree in 2010 only
# 3: tree in 2016 only
# 4: tree in 2010 and 2016
# 5: tree in 2020 only
# 6: tree in 2010 and 2020
# 8: tree in 2016 and 2020
# 9: tree in all years

# Variables declaration
########################
base_folder = Path('O:\Agroforestry\phase1_nebraska\data\products')     # folder to read grid file and COT files
N = 10              # number of monte carlo repetitions
grid_ID = 15        # sample grid cell ID to run the script
maturity_age = 20   # a tree of age this or higher will be mature
# area_to_carbon_multiplier: 3x3 multiplier matrix to convert ageClass change table to carbon accounting table
area_to_carbon_multiplier = np.ones((3,3))
# age_dist_2016_harvest: big vector containing the age of trees harvested after 2016
age_dist_2016_harvest = np.random.randint(1, 51, size=10_000)
# age_dist_2016_exist: big vector containing the age of trees existed in all years
age_dist_2016_exist = np.random.randint(1, 51, size=10_000)
# read TPR/TNR table for reference grids, which is assumed to be a .csv file placed at the base folder
PPR_NPR_table = pd.read_csv(os.path.join(base_folder,'ppr_npr_table.csv'))

# Program initialization
#########################

# open modelgrid20xx.gpkg files to determine ref_grid_ID for the input grid_ID for each year
modelGrids_2010 = gpd.read_file(str(base_folder / 'modelGrids_2010.gpkg'))
modelGrids_2016 = gpd.read_file(str(base_folder / 'modelGrids_2016.gpkg'))
modelGrids_2020 = gpd.read_file(str(base_folder / 'modelGrids_2020.gpkg'))
try:
    refGrid_2010 = modelGrids_2010[modelGrids_2010['Unique_ID']=='X12-'+str(grid_ID)]['modelGrid'].iloc[0]
    refGrid_2016 = modelGrids_2010[modelGrids_2016['Unique_ID']=='X12-'+str(grid_ID)]['modelGrid'].iloc[0]
    refGrid_2020 = modelGrids_2010[modelGrids_2020['Unique_ID']=='X12-'+str(grid_ID)]['modelGrid'].iloc[0]
except:
    print('No reference grid found for specified input grid ID')
    sys.exit(1)

# Retrieve PPR/NPR values corresponding to the input grid_ID
try:
    [PPR_2010, NPR_2010] = PPR_NPR_table.loc[PPR_NPR_table['Ref_cell_ID'] == refGrid_2010, ['PPR_2010', 'NPR_2010']].values[0]
    [PPR_2016, NPR_2016] = PPR_NPR_table.loc[PPR_NPR_table['Ref_cell_ID'] == refGrid_2010, ['PPR_2016', 'NPR_2016']].values[0]
    [PPR_2020, NPR_2020] = PPR_NPR_table.loc[PPR_NPR_table['Ref_cell_ID'] == refGrid_2010, ['PPR_2020', 'NPR_2020']].values[0]
except:
    print('No PPR/NPR value found for the reference grid associated with selected grid for one or more years.')
    sys.exit(1)

# Open the COT file associated with input grid cell
COT_file = base_folder / ('changeOverTime/X12-'+str(grid_ID)+'_changeOverTime_2.tif')
image = rasterio.open(str(COT_file))
data = image.read(1).astype(np.int8)  # read the first band
# Count unique values
values, counts = np.unique(data, return_counts=True)
print('Raster file statistics:', ','.join(f'{int(a)}:{b}' for a, b in zip(values, counts)))

# Monte carlo workflow execution
#################################

# extract yearly tree maps (0/1 rasters)
map_2010 = (1.0 * ((data == 1) | (data == 4) | (data == 6) | (data == 9))).reshape(-1)
map_2016 = (1.0 * ((data == 3) | (data == 4) | (data == 8) | (data == 9))).reshape(-1)
map_2020 = (1.0 * ((data == 5) | (data == 6) | (data == 8) | (data == 9))).reshape(-1)

size = len(map_2010)

for i in range(N):

    start_time = time.time()

    # Generate a new map 2010
    rand = np.random.rand(size).astype(np.float32)
    flip_0_to_1 = (map_2010 == 0) & (rand > NPR_2010)
    flip_1_to_0 = (map_2010 == 1) & (rand > PPR_2010)
    map_2010[flip_0_to_1] = 1
    map_2010[flip_1_to_0] = 0

    # Generate a new map 2016
    rand = np.random.rand(size).astype(np.float32)
    flip_0_to_1 = (map_2016 == 0) & (rand > NPR_2016)
    flip_1_to_0 = (map_2016 == 1) & (rand > PPR_2016)
    map_2016[flip_0_to_1] = 1
    map_2016[flip_1_to_0] = 0

    # Generate a new map 2020
    rand = np.random.rand(size).astype(np.float32)
    flip_0_to_1 = (map_2020 == 0) & (rand > NPR_2020)
    flip_1_to_0 = (map_2020 == 1) & (rand > PPR_2020)
    map_2020[flip_0_to_1] = 1
    map_2020[flip_1_to_0] = 0

    # Define conditions in age class decision table (see MonteCarlo_workflow_diagram_V4.0)
    cond0 = (map_2010 == 0) & (map_2016 == 0) & (map_2020 == 0)
    cond1 = (map_2010 == 0) & (map_2016 == 0) & (map_2020 == 1)
    cond2 = (map_2010 == 0) & (map_2016 == 1) & (map_2020 == 0)
    cond3 = (map_2010 == 0) & (map_2016 == 1) & (map_2020 == 1)
    cond4 = (map_2010 == 1) & (map_2016 == 0) & (map_2020 == 0)
    cond5 = (map_2010 == 1) & (map_2016 == 0) & (map_2020 == 1)
    cond6 = (map_2010 == 1) & (map_2016 == 1) & (map_2020 == 0)
    cond7 = (map_2010 == 1) & (map_2016 == 1) & (map_2020 == 1)

    # Draw a random age for 110 and 111 cases of the decision table
    age_2010_100 = np.random.choice(age_dist_2016_harvest, size=1)
    age_2010_101 = np.random.choice(age_dist_2016_harvest, size=1)
    age_2016_110 = np.random.choice(age_dist_2016_harvest, size=1)
    age_2016_111 = np.random.choice(age_dist_2016_exist, size=1)

    # Assign age classes for unknown values in decision table (1=young, 2=mature)
    ageClass_2010_100 = 2 if age_2010_100   >= maturity_age else 1
    ageClass_2010_101 = 2 if age_2010_101   >= maturity_age else 1
    ageClass_2010_110 = 2 if age_2016_110-6 >= maturity_age else 1
    ageClass_2010_111 = 2 if age_2016_111-6 >= maturity_age else 1
    ageClass_2016_110 = 2 if age_2016_110   >= maturity_age else 1
    ageClass_2016_111 = 2 if age_2016_111   >= maturity_age else 1
    ageClass_2020_111 = 2 if age_2016_111+4 >= maturity_age else 1

    # Apply rules to create age class maps
    ageClass_2010 = np.select([cond0, cond1, cond2, cond3, cond4, cond5, cond6,cond7],
        [0, 0, 0, 0, ageClass_2016_110, ageClass_2016_110, ageClass_2010_110, ageClass_2010_111])
    ageClass_2016 = np.select([cond0, cond1, cond2, cond3, cond4, cond5, cond6,cond7],
        [0, 0, 1, 1, 0, 0, ageClass_2016_110, ageClass_2016_111])
    ageClass_2020 = np.select([cond0, cond1, cond2, cond3, cond4, cond5, cond6,cond7],
        [0, 1, 0, 1, 0, 1, 0, ageClass_2020_111])

    # Count change combinations using histogram2d and setup the contingency matrix
    # 2010-2016
    counts, _, _ = np.histogram2d(ageClass_2010, ageClass_2016, bins=3)
    change_2010_2016 = np.array([[int(counts[0, 0]), int(counts[0, 1]), int(counts[0, 2])],
                                 [int(counts[1, 0]), int(counts[1, 1]), int(counts[1, 2])],
                                 [int(counts[2, 0]), int(counts[2, 1]), int(counts[2, 2])]])
    # 2016-2020
    counts, _, _ = np.histogram2d(ageClass_2016, ageClass_2020, bins=3)
    change_2016_2020 = np.array([[int(counts[0, 0]), int(counts[0, 1]), int(counts[0, 2])],
                                 [int(counts[1, 0]), int(counts[1, 1]), int(counts[1, 2])],
                                 [int(counts[2, 0]), int(counts[2, 1]), int(counts[2, 2])]])

    # setup carbon accounting tables (3x3 matrix)
    CA_2010_2016 = np.multiply(change_2010_2016, area_to_carbon_multiplier)
    CA_2016_2020 = np.multiply(change_2016_2020, area_to_carbon_multiplier)

    # Calculate final statistics (TBD)

    print('iteration run time: {:.2f} seconds'.format(time.time()-start_time))

# one iteration run time: About 90~120 seconds
