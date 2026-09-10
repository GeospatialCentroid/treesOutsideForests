# treesOutsideForests

Pipeline for estimating trees outside forests (TOF) by USDA Land Resource Region,
from NAIP imagery. Merged from four GeospatialCentroid repos with full history.

| Folder        | Stage                                                | Former repo            |
|---------------|------------------------------------------------------|------------------------|
| `masks/`      | Annual forest and urban masks per LRR (NLCD, Census) | agroforestry_Masks     |
| `naip/`       | NAIP acquisition and SNIC segmentation over AOIs     | naipScrape             |
| `sampling/`   | Grid generation, attribution, and sample designs     | agroforestrySampling   |
| `allocation/` | Neyman allocation of sample budgets across MLRAs     | neymanSampling         |

Each folder keeps its own README describing that stage. Large data are not tracked;
see each stage's README for the expected data layout.
