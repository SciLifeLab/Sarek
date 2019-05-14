#!/usr/bin/env nextflow

/*
kate: syntax groovy; space-indent on; indent-width 2;
================================================================================
=                                 S  A  R  E  K                                =
================================================================================
 New Germline (+ Somatic) Analysis Workflow. Started March 2016.
--------------------------------------------------------------------------------
 @Authors
 Sebastian DiLorenzo <sebastian.dilorenzo@bils.se> [@Sebastian-D]
 Jesper Eisfeldt <jesper.eisfeldt@scilifelab.se> [@J35P312]
 Phil Ewels <phil.ewels@scilifelab.se> [@ewels]
 Maxime Garcia <maxime.garcia@scilifelab.se> [@MaxUlysse]
 Szilveszter Juhos <szilveszter.juhos@scilifelab.se> [@szilvajuhos]
 Max Käller <max.kaller@scilifelab.se> [@gulfshores]
 Malin Larsson <malin.larsson@scilifelab.se> [@malinlarsson]
 Marcel Martin <marcel.martin@scilifelab.se> [@marcelm]
 Björn Nystedt <bjorn.nystedt@scilifelab.se> [@bjornnystedt]
 Pall Olason <pall.olason@scilifelab.se> [@pallolason]
--------------------------------------------------------------------------------
 @Homepage
 http://opensource.scilifelab.se/projects/sarek/
--------------------------------------------------------------------------------
 @Documentation
 https://github.com/SciLifeLab/Sarek/README.md
--------------------------------------------------------------------------------
 Processes overview
 - CalculateContamination - estimates contamination for Mutect2 filtering from stats
 - CreateIntervalBeds - Create and sort intervals into bed files
 - RunMutect2 - Run Mutect2 for Variant Calling
 - FilterMutect2Calls - Filter Mutect2 with panel of normals
 - RunFreeBayes - Run FreeBayes for Variant Calling (Parallelized processes)
 - ConcatVCF - Merge results from paralellized variant callers
 - MergePileupSummaries - merges pileup summaries from scatter-gather pileup stat calculation
 - MergeMutect2Stats - merges Mutect2 stats files
 - PileupSummariesForMutect2 - calculates pileup stats for Mutect2 filtering
 - RunStrelka - Run Strelka for Variant Calling
 - RunStrelkaBP - Run Strelka Best Practices for Variant Calling
 - RunManta - Run Manta for Structural Variant Calling
 - RunSingleManta - Run Manta for Single Structural Variant Calling
 - RunAlleleCount - Run AlleleCount to prepare for ASCAT
 - RunConvertAlleleCounts - Run convertAlleleCounts to prepare for ASCAT
 - RunAscat - Run ASCAT for CNV
 - RunBcftoolsStats - Run BCFTools stats on vcf files
 - RunVcftools - Run VCFTools on vcf files
================================================================================
=                           C O N F I G U R A T I O N                          =
================================================================================
*/

if (params.help) exit 0, helpMessage()
if (!SarekUtils.isAllowedParams(params)) exit 1, "params unknown, see --help for more information"
if (!checkUppmaxProject()) exit 1, "No UPPMAX project ID found! Use --project <UPPMAX Project ID>"
if (params.verbose) SarekUtils.verbose()

// Check for awsbatch profile configuration
// make sure queue is defined
if (workflow.profile == 'awsbatch') {
    if (!params.awsqueue) exit 1, "Provide the job queue for aws batch!"
}

tools = params.tools ? params.tools.split(',').collect{it.trim().toLowerCase()} : []

toolList = defineToolList()
if (!SarekUtils.checkParameterList(tools,toolList)) exit 1, 'Unknown tool(s), see --help for more information'

referenceMap = defineReferenceMap(tools)
if (!SarekUtils.checkReferenceMap(referenceMap)) exit 1, 'Missing Reference file(s), see --help for more information'

if (params.test && params.genome in ['GRCh37', 'GRCh38']) {
  referenceMap.intervals = file("$workflow.projectDir/repeats/tiny_${params.genome}.list")
}

tsvPath = ''
if (params.sample) tsvPath = params.sample
else tsvPath = "${params.outDir}/Preprocessing/Recalibrated/recalibrated.tsv"

// Set up the bamFiles channel

bamFiles = Channel.empty()
if (tsvPath) {
  tsvFile = file(tsvPath)
  bamFiles = SarekUtils.extractBams(tsvFile, "somatic")
} else exit 1, 'No sample were defined, see --help'

(patientGenders, bamFiles) = SarekUtils.extractGenders(bamFiles)

/*
================================================================================
=                               P R O C E S S E S                              =
================================================================================
*/

startMessage()

bamFiles = bamFiles.dump(tag:'BAM')

// separate recalibrateBams by status
bamsNormal = Channel.create()
bamsTumor = Channel.create()

bamFiles
  .choice(bamsTumor, bamsNormal) {it[1] == 0 ? 1 : 0}

bamsNormal = bamsNormal.ifEmpty{exit 1, "No normal sample defined, check TSV file: ${tsvFile}"}
bamsTumor = bamsTumor.ifEmpty{exit 1, "No tumor sample defined, check TSV file: ${tsvFile}"}

// Ascat, Strelka Germline & Manta Germline SV
bamsForAscat = Channel.create()
bamsForSingleManta = Channel.create()

(bamsTumorTemp, bamsTumor) = bamsTumor.into(2)
(bamsNormalTemp, bamsNormal) = bamsNormal.into(2)
(bamsForAscat, bamsForSingleManta) = bamsNormalTemp.mix(bamsTumorTemp).into(2)

// Removing status because not relevant anymore
bamsNormal = bamsNormal.map { idPatient, status, idSample, bam, bai -> [idPatient, idSample, bam, bai] }

bamsTumor = bamsTumor.map { idPatient, status, idSample, bam, bai -> [idPatient, idSample, bam, bai] }

// We know that somatic callers are notoriously slow.
// To speed them up we are chopping the reference into smaller pieces.
// Do variant calling by this intervals, and re-merge the VCFs.
// Since we are on a cluster or a multi-CPU machine, this can parallelize the
// variant call processes and push down the variant call wall clock time significanlty.

process CreateIntervalBeds {
  tag {intervals.fileName}

  input:
    file(intervals) from Channel.value(referenceMap.intervals)

  output:
    file '*.bed' into bedIntervals mode flatten

  script:
  // If the interval file is BED format, the fifth column is interpreted to
  // contain runtime estimates, which is then used to combine short-running jobs
  if (intervals.getName().endsWith('.bed'))
    """
    awk -vFS="\t" '{
      t = \$5  # runtime estimate
      if (t == "") {
        # no runtime estimate in this row, assume default value
        t = (\$3 - \$2) / ${params.nucleotidesPerSecond}
      }
      if (name == "" || (chunk > 600 && (chunk + t) > longest * 1.05)) {
        # start a new chunk
        name = sprintf("%s_%d-%d.bed", \$1, \$2+1, \$3)
        chunk = 0
        longest = 0
      }
      if (t > longest)
        longest = t
      chunk += t
      print \$0 > name
    }' ${intervals}
    """
  else
    """
    awk -vFS="[:-]" '{
      name = sprintf("%s_%d-%d", \$1, \$2, \$3);
      printf("%s\\t%d\\t%d\\n", \$1, \$2-1, \$3) > name ".bed"
    }' ${intervals}
    """
}

bedIntervals = bedIntervals
  .map { intervalFile ->
    def duration = 0.0
    for (line in intervalFile.readLines()) {
      final fields = line.split('\t')
      if (fields.size() >= 5) duration += fields[4].toFloat()
      else {
        start = fields[1].toInteger()
        end = fields[2].toInteger()
        duration += (end - start) / params.nucleotidesPerSecond
      }
    }
    [duration, intervalFile]
  }.toSortedList({ a, b -> b[0] <=> a[0] })
  .flatten().collate(2)
  .map{duration, intervalFile -> intervalFile}

bedIntervals = bedIntervals.dump(tag:'Intervals')

bamsAll = bamsNormal.join(bamsTumor)

// Manta, Strelka and Mutect2 filtering
(bamsForManta, bamsForStrelka, bamsForStrelkaBP, bamsForCalculateContamination, bamsForFilterMutect2, bamsAll) = bamsAll.into(6)

bamsTumorNormalIntervals = bamsAll.spread(bedIntervals)

// Mutect2 calls, FreeBayes and pileups for Mutect2 filtering
(bamsForMT2, bamsFFB, bamsForPileupSummaries) = bamsTumorNormalIntervals.into(3)

process RunMutect2 {

  tag {idSampleTumor + "_vs_" + idSampleNormal + "-" + intervalBed.baseName}

  input:
    set idPatient, idSampleNormal, file(bamNormal), file(baiNormal), idSampleTumor, file(bamTumor), file(baiTumor), file(intervalBed) from bamsForMT2
    set file(genomeFile), file(genomeIndex), file(genomeDict), file(intervals), file(commonSNPs), file(commonSNPsIndex) from Channel.value([
        referenceMap.genomeFile,
        referenceMap.genomeIndex,
        referenceMap.genomeDict,
        referenceMap.intervals,
        referenceMap.commonSNPs,
        referenceMap.commonSNPsIndex
      ])

  output:
		set val("Mutect2"), 
				idPatient, 
				idSampleNormal, 
				idSampleTumor, 
				file("${intervalBed.baseName}_${idSampleTumor}_vs_${idSampleNormal}.vcf") into mutect2Output 
		set idPatient, 
        idSampleNormal,
        idSampleTumor, 
				file("${intervalBed.baseName}_${idSampleTumor}_vs_${idSampleNormal}.vcf.stats") optional true into mutect2Stats

  when: 'mutect2' in tools && !params.onlyQC

  script:
  // please make a panel-of-normals, using at least 40 samples
  // https://gatkforums.broadinstitute.org/gatk/discussion/11136/how-to-call-somatic-mutations-using-gatk4-mutect2
  PON = params.pon ? "--panel-of-normals $params.pon" : ""

  """
  # Get raw calls
  gatk --java-options "-Xmx${task.memory.toGiga()}g" \
    Mutect2 \
    -R ${genomeFile}\
    -I ${bamTumor}  -tumor ${idSampleTumor} \
    -I ${bamNormal} -normal ${idSampleNormal} \
    -L ${intervalBed} \
    --germline-resource ${commonSNPs} \
    ${PON} \
    -O ${intervalBed.baseName}_${idSampleTumor}_vs_${idSampleNormal}.vcf
  """
}

mutect2Output = mutect2Output.groupTuple(by:[0,1,2,3])
(mutect2Output, mutect2OutForStats) = mutect2Output.into(2)

(mutect2Stats,intervalStatsFiles) = mutect2Stats.into(2)
mutect2Stats = mutect2Stats.groupTuple(by:[0,1,2])

process MergeMutect2Stats {
  tag {idSampleTumor + "_vs_" + idSampleNormal}

  publishDir "${params.outDir}/VariantCalling/${idPatient}/Mutect2", mode: params.publishDirMode

  input:
 		set caller,
				idPatient,
				idSampleNormal,
				idSampleTumor,
				file(vcfFiles) from mutect2OutForStats
		set idPatient,
				idSampleNormal, 
				idSampleTumor, 
				file(statsFiles) from mutect2Stats	// @TODO, we are overwriting idPatient, idSampleNormal/Tumor here - it is ugly
    set file(genomeFile), file(genomeIndex), file(genomeDict), file(intervals), file(commonSNPs), file(commonSNPsIndex) from Channel.value([
        referenceMap.genomeFile,
        referenceMap.genomeIndex,
        referenceMap.genomeDict,
        referenceMap.intervals,
        referenceMap.commonSNPs,
        referenceMap.commonSNPsIndex
      ])

  output:
        file("${idSampleTumor}_vs_${idSampleNormal}.vcf.gz.stats") into mergedStatsFile

  when: 'mutect2' in tools && !params.onlyQC

  script:     
	stats = statsFiles.collect{ "-stats ${it}" }.join(' ')
  """
  gatk --java-options "-Xmx${task.memory.toGiga()}g" \
		MergeMutectStats \
		${stats} \
		-O ${idSampleTumor}_vs_${idSampleNormal}.vcf.gz.stats
	"""
}
 
process RunFreeBayes {
  tag {idSampleTumor + "_vs_" + idSampleNormal + "-" + intervalBed.baseName}

  input:
    set idPatient, idSampleNormal, file(bamNormal), file(baiNormal), idSampleTumor, file(bamTumor), file(baiTumor), file(intervalBed) from bamsFFB
    file(genomeFile) from Channel.value(referenceMap.genomeFile)
    file(genomeIndex) from Channel.value(referenceMap.genomeIndex)

  output:
    set val("FreeBayes"), idPatient, idSampleNormal, idSampleTumor, file("${intervalBed.baseName}_${idSampleTumor}_vs_${idSampleNormal}.vcf") into freebayesOutput

  when: 'freebayes' in tools && !params.onlyQC

  script:
  """
  freebayes \
    -f ${genomeFile} \
    --pooled-continuous \
    --pooled-discrete \
    --genotype-qualities \
    --report-genotype-likelihood-max \
    --allele-balance-priors-off \
    --min-alternate-fraction 0.03 \
    --min-repeat-entropy 1 \
    --min-alternate-count 2 \
    -t ${intervalBed} \
    ${bamTumor} \
    ${bamNormal} > ${intervalBed.baseName}_${idSampleTumor}_vs_${idSampleNormal}.vcf
  """
}

freebayesOutput = freebayesOutput.groupTuple(by:[0,1,2,3])

// we are merging the VCFs that are called separatelly for different intervals
// so we can have a single sorted VCF containing all the calls for a given caller

vcfsToMerge = mutect2Output.mix(freebayesOutput)

vcfsToMerge = vcfsToMerge.dump(tag:'VCF to merge')

process ConcatVCF {
  tag {variantCaller + "_" + idSampleTumor + "_vs_" + idSampleNormal}

  publishDir "${params.outDir}/VariantCalling/${idPatient}/${"$variantCaller"}", mode: params.publishDirMode

  input:
    set variantCaller, idPatient, idSampleNormal, idSampleTumor, file(vcFiles) from vcfsToMerge
    file(genomeIndex) from Channel.value(referenceMap.genomeIndex)
    file(targetBED) from Channel.value(params.targetBED ? file(params.targetBED) : "null")

  output:
    // we have this funny *_* pattern to avoid copying the raw calls to publishdir
    set variantCaller, idPatient, idSampleNormal, idSampleTumor, file("*_*.vcf.gz"), file("*_*.vcf.gz.tbi") into vcfConcatenated

  when: ('mutect2' in tools || 'freebayes' in tools) && !params.onlyQC

  script:
  outputFile = 'mutect2' in tools ? "unfiltered_${variantCaller}_${idSampleTumor}_vs_${idSampleNormal}.vcf" : "${variantCaller}_${idSampleTumor}_vs_${idSampleNormal}.vcf"
  options = params.targetBED ? "-t ${targetBED}" : ""
  """
  ${workflow.projectDir}/bin/concatenateVCFs.sh -i ${genomeIndex} -c ${task.cpus} -o ${outputFile} ${options}
  """
}

(vcfConcatenated, vcfConcatenatedForFilter) = vcfConcatenated.into(2)
vcfConcatenated = vcfConcatenated.dump(tag:'VCF')

process PileupSummariesForMutect2 {
  tag {idSampleTumor + "_vs_" + idSampleNormal + "_" + intervalBed.baseName }

  input:
    set idPatient, idSampleNormal, file(bamNormal), file(baiNormal), idSampleTumor, file(bamTumor), file(baiTumor), file(intervalBed) from bamsForPileupSummaries
    set file(commonSNPs), file(commonSNPsIndex) from Channel.value([
        referenceMap.commonSNPs,
        referenceMap.commonSNPsIndex
			])
 		set idPatient,
				idSampleNormal,
				idSampleTumor,
				file(statsFile) from intervalStatsFiles

  output:
		set idPatient,
				idSampleTumor,
    		file("${intervalBed.baseName}_${idSampleTumor}_pileupsummaries.table") into pileupSummaries

  when: 'mutect2' in tools && !params.onlyQC && params.pon

  script:
  """
  # pileup summaries
  gatk --java-options "-Xmx${task.memory.toGiga()}g" \
    GetPileupSummaries \
    -I ${bamTumor} \
    -V ${commonSNPs} \
    -L ${intervalBed} \
    -O ${intervalBed.baseName}_${idSampleTumor}_pileupsummaries.table
	"""
}

pileupSummaries = pileupSummaries.groupTuple(by:[0,1])

process MergePileupSummaries {
  tag {idPatient + "_" + idSampleTumor}

  publishDir "${params.outDir}/VariantCalling/${idPatient}/Mutect2", mode: params.publishDirMode

	input:
		file(genomeDict) from referenceMap.genomeDict
		set idPatient, idSampleTumor, file(pileupSums) from pileupSummaries

	output:
        file("${idPatient}_${idSampleTumor}_pileupsummaries.table.tsv") into mergedPileupFile

  when: 'mutect2' in tools && !params.onlyQC
	script:
	allPileups = pileupSums.collect{ "-I ${it}" }.join(' ')
	"""
  gatk --java-options "-Xmx${task.memory.toGiga()}g" \
		GatherPileupSummaries \
		--sequence-dictionary ${genomeDict} \
		${allPileups} \
		-O ${idPatient}_${idSampleTumor}_pileupsummaries.table.tsv
	"""
}

process CalculateContamination {
  tag {idSampleTumor + "_vs_" + idSampleNormal}

  publishDir "${params.outDir}/VariantCalling/${idPatient}/Mutect2", mode: params.publishDirMode

  input:
    set idPatient, idSampleNormal, file(bamNormal), file(baiNormal), idSampleTumor, file(bamTumor), file(baiTumor) from bamsForCalculateContamination
    file("${idPatient}_${idSampleTumor}_pileupsummaries.table") from mergedPileupFile
  
  output:
    file("${idPatient}_${idSampleTumor}_contamination.table") into contaminationTable

  when: 'mutect2' in tools && !params.onlyQC && params.pon

  script:     
  """
  # calculate contamination
  gatk --java-options "-Xmx${task.memory.toGiga()}g" \
    CalculateContamination \
    -I ${idPatient}_${idSampleTumor}_pileupsummaries.table \
    -O ${idPatient}_${idSampleTumor}_contamination.table
	"""
 }

process FilterMutect2Calls {
  tag {idSampleTumor + "_vs_" + idSampleNormal}

  publishDir "${params.outDir}/VariantCalling/${idPatient}/Mutect2", mode: params.publishDirMode

  input:
    set variantCaller, 
				idPatient, 
				idSampleNormal, 
				idSampleTumor, 
				file("unfiltered_${variantCaller}_${idSampleTumor}_vs_${idSampleNormal}.vcf.gz"), 
				file("unfiltered_${variantCaller}_${idSampleTumor}_vs_${idSampleNormal}.vcf.gz.tbi") from vcfConcatenatedForFilter
    set file(genomeFile), file(genomeIndex), file(genomeDict), file(intervals), file(commonSNPs), file(commonSNPsIndex) from Channel.value([
        referenceMap.genomeFile,
        referenceMap.genomeIndex,
        referenceMap.genomeDict,
        referenceMap.intervals,
        referenceMap.commonSNPs,
        referenceMap.commonSNPsIndex
      ])
    file("${idSampleTumor}_vs_${idSampleNormal}.vcf.gz.stats") from mergedStatsFile
		file("${idSampleTumor}_contamination.table") from contaminationTable
  
  output:
    set val("Mutect2"),
        idPatient,
        idSampleNormal,
        idSampleTumor,
        file("filtered_${variantCaller}_${idSampleTumor}_vs_${idSampleNormal}.vcf.gz"),
        file("filtered_${variantCaller}_${idSampleTumor}_vs_${idSampleNormal}.vcf.gz.tbi"),
        file("filtered_${variantCaller}_${idSampleTumor}_vs_${idSampleNormal}.vcf.gz.filteringStats.tsv") into filteredMutect2Output

  when: 'mutect2' in tools && !params.onlyQC && params.pon

  script:
  """
  # do the actual filtering
  gatk --java-options "-Xmx${task.memory.toGiga()}g" \
    FilterMutectCalls \
    -V unfiltered_${variantCaller}_${idSampleTumor}_vs_${idSampleNormal}.vcf.gz \
    --contamination-table ${idSampleTumor}_contamination.table \
		--stats ${idSampleTumor}_vs_${idSampleNormal}.vcf.gz.stats \
    -R ${genomeFile} \
    -O filtered_${variantCaller}_${idSampleTumor}_vs_${idSampleNormal}.vcf.gz
  """
}

process RunStrelka {
  tag {idSampleTumor + "_vs_" + idSampleNormal}

  publishDir "${params.outDir}/VariantCalling/${idPatient}/Strelka", mode: params.publishDirMode

  input:
    set idPatient, idSampleNormal, file(bamNormal), file(baiNormal), idSampleTumor, file(bamTumor), file(baiTumor) from bamsForStrelka
    file(targetBED) from Channel.value(params.targetBED ? file(params.targetBED) : "null")
    set file(genomeFile), file(genomeIndex), file(genomeDict) from Channel.value([
      referenceMap.genomeFile,
      referenceMap.genomeIndex,
      referenceMap.genomeDict
    ])

  output:
    set val("Strelka"), idPatient, idSampleNormal, idSampleTumor, file("*.vcf.gz"), file("*.vcf.gz.tbi") into strelkaOutput

  when: 'strelka' in tools && !params.onlyQC

  options = params.targetBED ? "--exome --callRegions call_targets.bed.gz" : ""
  """
  ${beforeScript}
  configureStrelkaSomaticWorkflow.py \
  --tumor ${bamTumor} \
  --normal ${bamNormal} \
  --referenceFasta ${genomeFile} \
  ${options} \
  --runDir Strelka

  python Strelka/runWorkflow.py -m local -j ${task.cpus}
  mv Strelka/results/variants/somatic.indels.vcf.gz Strelka_${idSampleTumor}_vs_${idSampleNormal}_somatic_indels.vcf.gz
  mv Strelka/results/variants/somatic.indels.vcf.gz.tbi Strelka_${idSampleTumor}_vs_${idSampleNormal}_somatic_indels.vcf.gz.tbi
  mv Strelka/results/variants/somatic.snvs.vcf.gz Strelka_${idSampleTumor}_vs_${idSampleNormal}_somatic_snvs.vcf.gz
  mv Strelka/results/variants/somatic.snvs.vcf.gz.tbi Strelka_${idSampleTumor}_vs_${idSampleNormal}_somatic_snvs.vcf.gz.tbi
  """
}

strelkaOutput = strelkaOutput.dump(tag:'Strelka')

process RunManta {
  tag {idSampleTumor + "_vs_" + idSampleNormal}

  publishDir "${params.outDir}/VariantCalling/${idPatient}/Manta", mode: params.publishDirMode

  input:
    set idPatient, idSampleNormal, file(bamNormal), file(baiNormal), idSampleTumor, file(bamTumor), file(baiTumor) from bamsForManta
    file(targetBED) from Channel.value(params.targetBED ? file(params.targetBED) : "null")
    set file(genomeFile), file(genomeIndex) from Channel.value([
      referenceMap.genomeFile,
      referenceMap.genomeIndex
    ])

  output:
    set val("Manta"), idPatient, idSampleNormal, idSampleTumor, file("*.vcf.gz"), file("*.vcf.gz.tbi") into mantaOutput
    set idPatient, idSampleNormal, idSampleTumor, file("*.candidateSmallIndels.vcf.gz"), file("*.candidateSmallIndels.vcf.gz.tbi") into mantaToStrelka

  when: 'manta' in tools && !params.onlyQC

  script:
  beforeScript = params.targetBED ? "bgzip --threads ${task.cpus} -c ${targetBED} > call_targets.bed.gz ; tabix call_targets.bed.gz" : ""
  options = params.targetBED ? "--exome --callRegions call_targets.bed.gz" : ""
  """
  ${beforeScript}
  configManta.py \
  --normalBam ${bamNormal} \
  --tumorBam ${bamTumor} \
  --reference ${genomeFile} \
  ${options} \
  --runDir Manta

  python Manta/runWorkflow.py -m local -j ${task.cpus}

  mv Manta/results/variants/candidateSmallIndels.vcf.gz \
    Manta_${idSampleTumor}_vs_${idSampleNormal}.candidateSmallIndels.vcf.gz
  mv Manta/results/variants/candidateSmallIndels.vcf.gz.tbi \
    Manta_${idSampleTumor}_vs_${idSampleNormal}.candidateSmallIndels.vcf.gz.tbi
  mv Manta/results/variants/candidateSV.vcf.gz \
    Manta_${idSampleTumor}_vs_${idSampleNormal}.candidateSV.vcf.gz
  mv Manta/results/variants/candidateSV.vcf.gz.tbi \
    Manta_${idSampleTumor}_vs_${idSampleNormal}.candidateSV.vcf.gz.tbi
  mv Manta/results/variants/diploidSV.vcf.gz \
    Manta_${idSampleTumor}_vs_${idSampleNormal}.diploidSV.vcf.gz
  mv Manta/results/variants/diploidSV.vcf.gz.tbi \
    Manta_${idSampleTumor}_vs_${idSampleNormal}.diploidSV.vcf.gz.tbi
  mv Manta/results/variants/somaticSV.vcf.gz \
    Manta_${idSampleTumor}_vs_${idSampleNormal}.somaticSV.vcf.gz
  mv Manta/results/variants/somaticSV.vcf.gz.tbi \
    Manta_${idSampleTumor}_vs_${idSampleNormal}.somaticSV.vcf.gz.tbi
  """
}

mantaOutput = mantaOutput.dump(tag:'Manta')

process RunSingleManta {
  tag {idSample + " - Tumor-Only"}

  publishDir "${params.outDir}/VariantCalling/${idPatient}/Manta", mode: params.publishDirMode

  input:
    set idPatient, status, idSample, file(bam), file(bai) from bamsForSingleManta
    file(targetBED) from Channel.value(params.targetBED ? file(params.targetBED) : "null")
    set file(genomeFile), file(genomeIndex) from Channel.value([
      referenceMap.genomeFile,
      referenceMap.genomeIndex
    ])

  output:
    set val("Manta"), idPatient, idSample,  file("*.vcf.gz"), file("*.vcf.gz.tbi") into singleMantaOutput

  when: 'manta' in tools && status == 1 && !params.onlyQC

  script:
  beforeScript = params.targetBED ? "bgzip --threads ${task.cpus} -c ${targetBED} > call_targets.bed.gz ; tabix call_targets.bed.gz" : ""
  options = params.targetBED ? "--exome --callRegions call_targets.bed.gz" : ""
  """
  ${beforeScript}
  configManta.py \
  --tumorBam ${bam} \
  --reference ${genomeFile} \
  ${options} \
  --runDir Manta

  python Manta/runWorkflow.py -m local -j ${task.cpus}

  mv Manta/results/variants/candidateSmallIndels.vcf.gz \
    Manta_${idSample}.candidateSmallIndels.vcf.gz
  mv Manta/results/variants/candidateSmallIndels.vcf.gz.tbi \
    Manta_${idSample}.candidateSmallIndels.vcf.gz.tbi
  mv Manta/results/variants/candidateSV.vcf.gz \
    Manta_${idSample}.candidateSV.vcf.gz
  mv Manta/results/variants/candidateSV.vcf.gz.tbi \
    Manta_${idSample}.candidateSV.vcf.gz.tbi
  mv Manta/results/variants/tumorSV.vcf.gz \
    Manta_${idSample}.tumorSV.vcf.gz
  mv Manta/results/variants/tumorSV.vcf.gz.tbi \
    Manta_${idSample}.tumorSV.vcf.gz.tbi
  """
}

singleMantaOutput = singleMantaOutput.dump(tag:'single Manta')

// Running Strelka Best Practice with Manta indel candidates
// For easier joining, remaping channels to idPatient, idSampleNormal, idSampleTumor...

bamsForStrelkaBP = bamsForStrelkaBP.map {
  idPatientNormal, idSampleNormal, bamNormal, baiNormal, idSampleTumor, bamTumor, baiTumor ->
  [idPatientNormal, idSampleNormal, idSampleTumor, bamNormal, baiNormal, bamTumor, baiTumor]
}.join(mantaToStrelka, by:[0,1,2]).map {
  idPatientNormal, idSampleNormal, idSampleTumor, bamNormal, baiNormal, bamTumor, baiTumor, mantaCSI, mantaCSIi ->
  [idPatientNormal, idSampleNormal, bamNormal, baiNormal, idSampleTumor, bamTumor, baiTumor, mantaCSI, mantaCSIi]
}

process RunStrelkaBP {
  tag {idSampleTumor + "_vs_" + idSampleNormal}

  publishDir "${params.outDir}/VariantCalling/${idPatient}/Strelka", mode: params.publishDirMode

  input:
    set idPatient, idSampleNormal, file(bamNormal), file(baiNormal), idSampleTumor, file(bamTumor), file(baiTumor), file(mantaCSI), file(mantaCSIi) from bamsForStrelkaBP
    file(targetBED) from Channel.value(params.targetBED ? file(params.targetBED) : "null")
    set file(genomeFile), file(genomeIndex), file(genomeDict) from Channel.value([
      referenceMap.genomeFile,
      referenceMap.genomeIndex,
      referenceMap.genomeDict
    ])

  output:
    set val("Strelka"), idPatient, idSampleNormal, idSampleTumor, file("*.vcf.gz"), file("*.vcf.gz.tbi") into strelkaBPOutput

  when: 'strelka' in tools && 'manta' in tools && params.strelkaBP && !params.onlyQC

  script:
  beforeScript = params.targetBED ? "bgzip --threads ${task.cpus} -c ${targetBED} > call_targets.bed.gz ; tabix call_targets.bed.gz" : ""
  options = params.targetBED ? "--exome --callRegions call_targets.bed.gz" : ""
  """
  ${beforeScript}
  configureStrelkaSomaticWorkflow.py \
  --tumor ${bamTumor} \
  --normal ${bamNormal} \
  --referenceFasta ${genomeFile} \
  --indelCandidates ${mantaCSI} \
  ${options} \
  --runDir Strelka

  python Strelka/runWorkflow.py -m local -j ${task.cpus}

  mv Strelka/results/variants/somatic.indels.vcf.gz \
    StrelkaBP_${idSampleTumor}_vs_${idSampleNormal}_somatic_indels.vcf.gz
  mv Strelka/results/variants/somatic.indels.vcf.gz.tbi \
    StrelkaBP_${idSampleTumor}_vs_${idSampleNormal}_somatic_indels.vcf.gz.tbi
  mv Strelka/results/variants/somatic.snvs.vcf.gz \
    StrelkaBP_${idSampleTumor}_vs_${idSampleNormal}_somatic_snvs.vcf.gz
  mv Strelka/results/variants/somatic.snvs.vcf.gz.tbi \
    StrelkaBP_${idSampleTumor}_vs_${idSampleNormal}_somatic_snvs.vcf.gz.tbi
  """
}

strelkaBPOutput = strelkaBPOutput.dump(tag:'Strelka BP')

// Run commands and code from Malin Larsson
// Based on Jesper Eisfeldt's code
process RunAlleleCount {
  tag {idSample}

  input:
    set idPatient, status, idSample, file(bam), file(bai) from bamsForAscat
    set file(acLoci), file(genomeFile), file(genomeIndex), file(genomeDict) from Channel.value([
      referenceMap.acLoci,
      referenceMap.genomeFile,
      referenceMap.genomeIndex,
      referenceMap.genomeDict
    ])

  output:
    set idPatient, status, idSample, file("${idSample}.alleleCount") into alleleCountOutput

  when: 'ascat' in tools && !params.onlyQC

  script:
  """
  alleleCounter \
  -l ${acLoci} \
  -r ${genomeFile} \
  -b ${bam} \
  -o ${idSample}.alleleCount;
  """
}

alleleCountNormal = Channel.create()
alleleCountTumor = Channel.create()

alleleCountOutput
  .choice(alleleCountTumor, alleleCountNormal) {it[1] == 0 ? 1 : 0}

alleleCountOutput = alleleCountNormal.combine(alleleCountTumor)

alleleCountOutput = alleleCountOutput.map {
  idPatientNormal, statusNormal, idSampleNormal, alleleCountNormal,
  idPatientTumor,  statusTumor,  idSampleTumor,  alleleCountTumor ->
  [idPatientNormal, idSampleNormal, idSampleTumor, alleleCountNormal, alleleCountTumor]
}

// R script from Malin Larssons bitbucket repo:
// https://bitbucket.org/malinlarsson/somatic_wgs_pipeline
process RunConvertAlleleCounts {
  tag {idSampleTumor + "_vs_" + idSampleNormal}

  publishDir "${params.outDir}/VariantCalling/${idPatient}/ASCAT", mode: params.publishDirMode

  input:
    set idPatient, idSampleNormal, idSampleTumor, file(alleleCountNormal), file(alleleCountTumor) from alleleCountOutput

  output:
    set idPatient, idSampleNormal, idSampleTumor, file("${idSampleNormal}.BAF"), file("${idSampleNormal}.LogR"), file("${idSampleTumor}.BAF"), file("${idSampleTumor}.LogR") into convertAlleleCountsOutput

  when: 'ascat' in tools && !params.onlyQC

  script:
  gender = patientGenders[idPatient]
  """
  convertAlleleCounts.r ${idSampleTumor} ${alleleCountTumor} ${idSampleNormal} ${alleleCountNormal} ${gender}
  """
}

// R scripts from Malin Larssons bitbucket repo:
// https://bitbucket.org/malinlarsson/somatic_wgs_pipeline
process RunAscat {
  tag {idSampleTumor + "_vs_" + idSampleNormal}

  publishDir "${params.outDir}/VariantCalling/${idPatient}/ASCAT", mode: params.publishDirMode

  input:
    set idPatient, idSampleNormal, idSampleTumor, file(bafNormal), file(logrNormal), file(bafTumor), file(logrTumor) from convertAlleleCountsOutput
    file(acLociGC) from Channel.value([referenceMap.acLociGC])

  output:
    set val("ASCAT"), idPatient, idSampleNormal, idSampleTumor, file("${idSampleTumor}.*.{png,txt}") into ascatOutput

  when: 'ascat' in tools && !params.onlyQC

  script:
  """
  # get rid of "chr" string if there is any
  for f in *BAF *LogR; do sed 's/chr//g' \$f > tmpFile; mv tmpFile \$f;done
  run_ascat.r ${bafTumor} ${logrTumor} ${bafNormal} ${logrNormal} ${idSampleTumor} ${baseDir} ${acLociGC}
  """
}

ascatOutput.dump(tag:'ASCAT')

(strelkaIndels, strelkaSNVS) = strelkaOutput.into(2)
(mantaSomaticSV, mantaDiploidSV) = mantaOutput.into(2)

vcfForQC = Channel.empty().mix(
  vcfConcatenated.map {
    variantcaller, idPatient, idSampleNormal, idSampleTumor, vcf, tbi ->
    [variantcaller, vcf]
  },
  mantaDiploidSV.map {
    variantcaller, idPatient, idSampleNormal, idSampleTumor, vcf, tbi ->
    [variantcaller, vcf[2]]
  },
  mantaSomaticSV.map {
    variantcaller, idPatient, idSampleNormal, idSampleTumor, vcf, tbi ->
    [variantcaller, vcf[3]]
  },
  singleMantaOutput.map {
    variantcaller, idPatient, idSample, vcf, tbi ->
    [variantcaller, vcf[2]]
  },
  strelkaIndels.map {
    variantcaller, idPatient, idSampleNormal, idSampleTumor, vcf, tbi ->
    [variantcaller, vcf[0]]
  },
  strelkaSNVS.map {
    variantcaller, idPatient, idSampleNormal, idSampleTumor, vcf, tbi ->
    [variantcaller, vcf[1]]
  })

(vcfForBCFtools, vcfForVCFtools) = vcfForQC.into(2)

process RunBcftoolsStats {
  tag {vcf}

  publishDir "${params.outDir}/Reports/BCFToolsStats", mode: params.publishDirMode

  input:
    set variantCaller, file(vcf) from vcfForBCFtools

  output:
    file ("*.bcf.tools.stats.out") into bcfReport

  when: !params.noReports

  script: QC.bcftools(vcf)
}

bcfReport.dump(tag:'BCFTools')

process RunVcftools {
  tag {"${variantCaller} - ${vcf}"}

  publishDir "${params.outDir}/Reports/VCFTools", mode: params.publishDirMode

  input:
    set variantCaller, file(vcf) from vcfForVCFtools

  output:
    file ("${reducedVCF}.*") into vcfReport

  when: !params.noReports

  script:
    reducedVCF = SarekUtils.reduceVCF(vcf)
    QC.vcftools(vcf)
}

vcfReport.dump(tag:'VCFTools')

/*
================================================================================
=                               F U N C T I O N S                              =
================================================================================
*/

def checkParameterExistence(it, list) {
  // Check parameter existence
  if (!list.contains(it)) {
    println("Unknown parameter: ${it}")
    return false
  }
  return true
}

def checkParamReturnFile(item) {
  params."${item}" = params.genomes[params.genome]."${item}"
	if( !params."${item}" ) exit 1, " Error: file ${item} is missing." 

  return file(params."${item}")
}

def checkUppmaxProject() {
  // check if UPPMAX project number is specified
  return !(workflow.profile == 'slurm' && !params.project)
}

def defineReferenceMap(tools) {
  if (!(params.genome in params.genomes)) exit 1, "Genome ${params.genome} not found in configuration"
  def referenceMap =
  [
    'genomeDict'       : checkParamReturnFile("genomeDict"),
    'genomeFile'       : checkParamReturnFile("genomeFile"),
    'genomeIndex'      : checkParamReturnFile("genomeIndex"),
    'intervals'        : checkParamReturnFile("intervals")
  ]
  if ('ascat' in tools) {
    referenceMap.putAll(
      'acLoci'           : checkParamReturnFile("acLoci"),
      'acLociGC'         : checkParamReturnFile("acLociGC")
    )
  }
  if ('mutect2' in tools) {
    referenceMap.putAll(
      'commonSNPs'       : checkParamReturnFile("commonSNPs"),
      'commonSNPsIndex'  : checkParamReturnFile("commonSNPsIndex")
    )
  }

  return referenceMap
}

def defineToolList() {
  return [
    'ascat',
    'freebayes',
    'haplotypecaller',
    'manta',
    'mutect2',
    'strelka'
  ]
}

def grabRevision() {
  // Return the same string executed from github or not
  return workflow.revision ?: workflow.commitId ?: workflow.scriptId.substring(0,10)
}

def helpMessage() {
  // Display help message
  this.sarekMessage()
  log.info "    Usage:"
  log.info "       nextflow run somaticVC.nf --sample <file.tsv> [--tools TOOL[,TOOL]] --genome <Genome>"
  log.info "    --sample <file.tsv>"
  log.info "       Specify a TSV file containing paths to sample files."
  log.info "    --test"
  log.info "       Use a test sample."
  log.info "    --noReports"
  log.info "       Disable QC tools and MultiQC to generate a HTML report"
  log.info "    --tools"
  log.info "       Option to configure which tools to use in the workflow."
  log.info "         Different tools to be separated by commas."
  log.info "       Possible values are:"
  log.info "         mutect2 (use Mutect2 for VC)"
  log.info "         freebayes (use FreeBayes for VC)"
  log.info "         strelka (use Strelka for VC)"
  log.info "         haplotypecaller (use HaplotypeCaller for normal bams VC)"
  log.info "         manta (use Manta for SV)"
  log.info "         ascat (use Ascat for CNV)"
  log.info "    --genome <Genome>"
  log.info "       Use a specific genome version."
  log.info "       Possible values are:"
  log.info "         GRCh37"
  log.info "         GRCh38 (Default)"
  log.info "         smallGRCh37 (Use a small reference (Tests only))"
  log.info "    --onlyQC"
  log.info "       Run only QC tools and gather reports"
  log.info "    --help"
  log.info "       you're reading it"
}

def minimalInformationMessage() {
  // Minimal information message
  log.info "Command Line: " + workflow.commandLine
  log.info "Profile     : " + workflow.profile
  log.info "Project Dir : " + workflow.projectDir
  log.info "Launch Dir  : " + workflow.launchDir
  log.info "Work Dir    : " + workflow.workDir
  log.info "Out Dir     : " + params.outDir
  log.info "TSV file    : " + tsvFile
  log.info "Genome      : " + params.genome
  log.info "Genome_base : " + params.genome_base
  log.info "Target BED  : " + params.targetBED
  log.info "Tools       : " + tools.join(', ')
  log.info "Containers"
  if (params.repository != "") log.info "  Repository   : " + params.repository
  if (params.containerPath != "") log.info "  ContainerPath: " + params.containerPath
  log.info "  Tag          : " + params.tag
  log.info "Reference files used:"
  log.info "  acLoci      :\n\t" + referenceMap.acLoci
  log.info "  acLociGC    :\n\t" + referenceMap.acLociGC
  log.info "  dbsnp       :\n\t" + referenceMap.dbsnp
  log.info "\t" + referenceMap.dbsnpIndex
  log.info "  genome      :\n\t" + referenceMap.genomeFile
  log.info "\t" + referenceMap.genomeDict
  log.info "\t" + referenceMap.genomeIndex
  log.info "  intervals   :\n\t" + referenceMap.intervals
  log.info "  common SNPs :\n\t" + referenceMap.commonSNPs
  log.info "\t" + referenceMap.commonSNPsIndex
}

def nextflowMessage() {
  // Nextflow message (version + build)
  log.info "N E X T F L O W  ~  version ${workflow.nextflow.version} ${workflow.nextflow.build}"
}

def returnFile(it) {
  // return file if it exists
  if (!file(it).exists()) exit 1, "Missing file in TSV file: ${it}, see --help for more information"
  return file(it)
}

def returnStatus(it) {
  // Return status if it's correct
  // Status should be only 0 or 1
  // 0 being normal
  // 1 being tumor (or relapse or anything that is not normal...)
  if (!(it in [0, 1])) exit 1, "Status is not recognized in TSV file: ${it}, see --help for more information"
  return it
}

def sarekMessage() {
  // Display Sarek message
  log.info "Sarek - Workflow For Somatic And Germline Variations ~ ${workflow.manifest.version} - " + this.grabRevision() + (workflow.commitId ? " [${workflow.commitId}]" : "")
}

def startMessage() {
  // Display start message
  SarekUtils.sarek_ascii()
  this.sarekMessage()
  this.minimalInformationMessage()
}

workflow.onComplete {
  // Display complete message
  this.nextflowMessage()
  this.sarekMessage()
  this.minimalInformationMessage()
  log.info "Completed at: " + workflow.complete
  log.info "Duration    : " + workflow.duration
  log.info "Success     : " + workflow.success
  log.info "Exit status : " + workflow.exitStatus
  log.info "Error report: " + (workflow.errorReport ?: '-')
}

workflow.onError {
  // Display error message
  this.nextflowMessage()
  this.sarekMessage()
  log.info "Workflow execution stopped with the following message:"
  log.info "  " + workflow.errorMessage
}
