#!/usr/bin/env nextflow

/*
 * Sample run data for MuTect1
 * use like (on milou):
 * ./nextflow run Mutect1.nf --tumor_bam ~/dev/chr17_testdata/HCC1143.tumor.bam --normal_bam ~/dev/chr17_testdata/HCC1143.normal.bam
 */

tumorBam    = file(params.tumorBam)
normalBam   = file(params.normalBam)
genomeFile  = file(params.genome)
genomeIndex = file(params.genomeidx)
cosmic      = file(params.cosmic)
cosmicIndex = file(params.cosmicidx)
dbsnp       = file(params.dbsnp)
dbsnpIndex  = file(params.dbsnpidx)
mutect1Home = ${params.mutect1Home}

process Mutect1 {

  cpus 2

  input:
  file genomeFile
  file genomeIndex
  file tumorBam
  file tumorBai
  file normalBam
  file normalBai

  output:
  file '*.mutect1.vcf' into mutect1Vcf
  file '*.mutect1.out' into mutect1Out

  """
  java -jar ${params.mutect1Home}/muTect-1.1.5.jar \
  --analysis_type MuTect \
  --reference_sequence ${params.genome} \
  --cosmic ${params.cosmic} \
  --dbsnp ${params.dbsnp} \
  --input_file:normal ${normal_bam} \
  --input_file:tumor ${tumor_bam} \
  --out test.mutect1.out \
  --vcf test.mutect1.vcf \
  -L 17:1000000-2000000
  """
}
