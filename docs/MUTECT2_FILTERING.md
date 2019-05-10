# Filtering Mutect2 (GATK4+) calls

The *de facto* guide to use Mutect2 is at: [(How to) Call somatic mutations using GATK4 Mutect2](https://gatkforums.broadinstitute.org/gatk/discussion/11136/how-to-call-somatic-mutations-using-gatk4-mutect2 ). MuTect 1 and MuTect2 implemented in GATK 3.X versions are not maintained anymore, it is recommended to switch to the GATK4 version though still many of the funcionalities are in beta stage at the time of writing this documentation. Neither Mutect2 nor the downstream processes are multithreaded, but it is possible to do scatter-gather steps. Mutect2 call and filtering in Sarek does use scatter-gather to get Mutect2 raw calls, stat files and pileup statistics. 

## Generating panel-of-normals (PON)

The main point of getting a [panel-of-normals VCF file](https://gatkforums.broadinstitute.org/gatk/discussion/11136/how-to-call-somatic-mutations-using-gatk4-mutect2#2) is to get a collection of common, low allele-frequency variants that are present in most of the *normal* samples and can be mistaken as a somatic one. Usually these are sequencing or alignment artefacts; when generating a PON, it is important to have the same procedure for library preparation, sequencing and alignement for each sample that are used for PON creation. Broad is recommending to have at least 40 samples collected to get a decent WGS sample size from the same laboratory following the same procedure. We can confirm that by using and [bootstrapping](https://en.wikipedia.org/wiki/Bootstrapping_(statistics)#Approach) 5-65 paediatric samples, the power of eliminating false positives started to plateau around 40 samples. 

The PON is a simple VCF file just like dbSNP, and the filtering process annotates the raw Mutect2 calls adding a filter if the call is also in the PON file (and does few other things besides). Hence, this information can be used for other variant-callers also, not restricted to Mutect2 calls. 

## VCF with common SNPs

A set of common biallelic SNPs are used to look at other low-allele frequency variations, Broad is recommending their GnomAD that is for GRCh37 _only_. Sarek uses GRCh38 by default, and we have used the GRCh38 version of [SweGen](https://swefreq.nbis.se/) data that is more relevant to us. The command line to generate the common set was like (using our Singularity container):

```
$ singularity shell /containers/sarek-latest.simg
Singularity sarek-latest.simg:~> gatk SelectVariants  \
                                      --output SweGen.common.biallelic.vcf \
                                      --restrict-alleles-to BIALLELIC \
                                      --select-type-to-include SNP \
                                      --variant SweGen_hg38_stratified.SWAF.vcf.gz \
                                      --reference /references/igenomes/Homo_sapiens/GATK/GRCh38/Sequence/WholeGenomeFasta/Homo_sapiens_assembly38.fasta \
                                      -select AF >0.001
```


## run with or without PON
You can run Mutect2 without having a PON, but there will be no filtering, none of the variants are getting a PASS filter in your VCF file. In fact, the unfiltered Mutect2 results are still saved by Sarek, together with the stats and pileup stats files. This is the default mode, to get a filtered VCF you have to provide a PON at the command line like: 



```
#!/bin/bash -x
$ nextflow run somaticVC.nf -profile cpu16mem96g \
        --sample Preprocessing/Recalibrated/recalibrated.tsv \
        --genome GRCh38 \
        --genome_base /reference \
        --tools mutect2 \
        --containerPath /containers \
        --pon PON.vcf.gz
```

The PON has to be compressed with bgzip and indexed with tabix.




