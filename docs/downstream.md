# Downstream processing, ranking and connection to [Scout](https://github.com/Clinical-Genomics/scout)

## RankScore annotations

The [Scout](https://github.com/Clinical-Genomics/scout) tools was developed to help clinicians to visualise relevant
variations, focusing on rare diseases. However, adding cancer capabilities are on the way, and the first step to add
somatic mutations is to rank them in the VCF to be loaded to Scout. The scores have to be added as a `RankScore` INFO
field, have the format like:

```
chr1    514206  rs1247069502    A       C       .       PASS  ECNT=1;dbSNP=rs1247069502  RankScore=ScoreTest:0 GT:AD:AF  0/1:2,6:0.750 0/0:33,1:0.029
```

## Calculating RankScores with [Pathfindr]()

## Scout as visual interface

