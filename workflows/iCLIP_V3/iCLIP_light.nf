"""
Author : Wilfried Guiblet. Blame him if it fails.
Update of : https://github.com/NCI-RBL/iCLIP

* Overview *
- Multiplexed samples are split based on provided barcodes and named using provide manifests, maximum 10 samples
- Adaptors are stripped from samples
- Samples are unzipped and split into smaller fastq files to increase speed
- Samples are aligned using NovaAlign
- SAM and BAM files are created
- Samples are merged
* Requirements *
- Read specific input requirements, and execution information on the Wikipage
located at: TBD

"""

// Necessary for syntax
nextflow.enable.dsl=2


// Create channels from the input paths
//bamfiles = Channel.fromPath(params.bamfiles)

//rawfiles = Channel.fromPath('rawfiles/toy*.fastq.gz').view { "value: $it" }
rawfiles_ch = Channel.fromList(params.rawfilesnames)//.view { "value: $it" }
samplefiles_ch = Channel.fromList(params.samplenames)//.view { "value: $it" }

//fastqfiles = Channel.fromPath('${params.workdir}/01_preprocess/01_fastq/*.fastq.gz')
//bamfiles = Channel.fromPath('bamfiles/*bam')
//bedfiles = Channel.fromPath('03_peaks/01_bed/*bed')

// Create a channel with a unique value. Useful for processes that do not iterate through multiple samples.
unique_ch = Channel.fromList(['unique'])



// ************* The following parameters are imported from the file: nextflow.parameters.yaml *************


params.threads = '4' // Threads to use for multithreading. Use carefully. Needs to be transfered to yaml.

// Convert rRNA selection and splice junction selection from Y/N to TRUE/FALSE
if (params.include_rRNA=="Y") {params.rrna_flag = "TRUE"}
else {params.rrna_flag = "FALSE"}
if (params.splicejunction=="Y") {params.sp_junc = "TRUE"}
else {params.sp_junc = "FALSE"}
//


params.a_config = "${params.workdir}/config/annotation_config.txt"

//params.count_threshold = params.min_reads_mapped

params.manorm_w = params.MANormWidth
params.manorm_d = params.MNormDistance

if( params.min_reads_mapped > 1) {
    println "Count_threshold must be a decimal value, representing a percentage."
}


// determine which umi separator to use
if(params.multiplexflag == 'Y') {
    // demultiplexing ades rbc: to all demux files;
    params.umi_sep = "rbc:"}
else{
    // external demux uses an _
    params.umi_sep = params.umiSeparator}





// ************* End of parameter importation *************


process Create_Project_Annotations {
    """
    Generate annotation table once per project.
    """

    //container 'wilfriedguiblet/iclip:v3.0' // Use a Docker container

    input:
        val unique

    output:
        val unique

    shell:
        """
        Rscript !{params.workdir}/workflow/scripts/04_annotation.R \\
          --ref_species !{params.reference} \\
          --refseq_rRNA !{params.rrna_flag} \\
          --alias_path !{params."${params.reference}".aliaspath} \\
          --gencode_path !{params."${params.reference}".gencodepath} \\
          --refseq_path !{params."${params.reference}".refseqpath} \\
          --canonical_path !{params."${params.reference}".can_path} \\
          --intron_path !{params."${params.reference}".intronpath} \\
          --rmsk_path !{params."${params.reference}".rmskpath} \\
          --custom_path !{params."${params.reference}".additionalannopath} \\
          --out_dir !{params.workdir}/04_annotation/01_project/ \\
          --reftable_path !{params.a_config} 
        """
}

process Init_ReadCounts_Reportfile {

    input:
        val unique

    output:
        val unique

    shell:
        """
        # create output file
        if [[ -f !{params.workdir}/00_QC/02_SamStats/qc_read_count_raw_values.txt ]]; then rm !{params.workdir}/00_QC/02_SamStats/qc_read_count_raw_values.txt ; fi 
        touch !{params.workdir}/00_QC/02_SamStats/qc_read_count_raw_values.txt
        """
}


process QC_Barcode {
    """
    Barcodes will be reviewed to ensure uniformtiy amongst samples.
    - generate counts of barcodes and output to text file
    - run python script that determines barcode expected and generates mismatches based on input
    - output barplot with top barcode counts

    --mpid clip3 must be changed to be a variable etracted from relevant manifest
    """

    input:
        tuple val(unique), val(rawfile)

    output:
        val rawfile

    shell:    
        """
        set -exo pipefail

        gunzip -c !{params.rawdir}/!{rawfile}.fastq.gz \\
            | awk 'NR%4==2 {{print substr(\$0, !{params.qc_barcode.start_pos}, !{params.qc_barcode.barcode_length});}}' \\
            | LC_ALL=C sort --buffer-size=!{params.qc_barcode.memory} --parallel=!{params.qc_barcode.threads} --temporary-directory='!{params.tempdir}' -n \\
            | uniq -c > !{params.workdir}/00_QC/01_Barcodes/!{rawfile}.test_barcode_counts.txt;        

        Rscript !{params.workdir}/workflow/scripts/02_barcode_qc.R \\
            --sample_manifest !{params.manifests.samples} \\
            --multiplex_manifest !{params.manifests.multiplex} \\
            --barcode_input !{params.workdir}/00_QC/01_Barcodes/!{rawfile}_barcode_counts.txt \\
            --mismatch !{params.mismatch} \\
            --mpid clip3 \\
            --output_dir !{params.workdir}/00_QC/01_Barcodes/ \\
            --qc_dir !{params.workdir}/00_QC/01_Barcodes/
        """

}

process Demultiplex {
    """
    https://github.com/ulelab/ultraplex

    NOTE: our SLURM system does not allow the use of --sbatchcompression which is recommended
    for increase in speed with --ultra. When the --sbatchcompression is used on our system, files 
    do not get compressed and will be transferred using a significant amount of disc space. 

    file_name                   multiplex
    SIM_iCLIP_S1_R1_001.fastq   SIM_iCLIP_S1
    multiplex       sample          group       barcode     adaptor
    SIM_iCLIP_S1    Ro_Clip         CLIP        NNNTGGCNN   AGATCGGAAGAGCGGTTCAG
    SIM_iCLIP_S1    Control_Clip    CNTRL       NNNCGGANN   AGATCGGAAGAGCGGTTCAG
    """

    input:
        val rawfile

    output:
        val rawfile

    shell:
        """
        set -exo pipefail
        
        # run ultraplex to remove adaptors, separate barcodes
        # output files to tmp scratch dir
        ultraplex \\
            --threads !{params.demultiplex.threads} \\
            --barcodes !{params.manifests.barcode} \\
            --directory !{params.workdir}/01_preprocess/01_fastq/ \\
            --inputfastq !{params.workdir}/rawfiles/!{rawfile}.fastq.gz \\
            --final_min_length !{params.demultiplex.filterlength} \\
            --phredquality !{params.demultiplex.phredQuality} \\
            --fiveprimemismatches !{params.mismatch} \\
            --ultra 
        """

}



process Star {
    """
    STAR Alignment
    https://github.com/alexdobin/STAR/releases

    """
    ///container 'wilfriedguiblet/iclip:v3.0'

    input:
        tuple val(rawfile), val(samplefile)

    output:
        val samplefile

    shell:
        """
        set -exo pipefail

        
        # STAR cannot handle sorting large files - allow samtools to sort output files
        STAR \\
        --runThreadN !{params.STAR.threads} \\
        --runMode alignReads \\
        --genomeDir !{params."${params.reference}".stardir} \\
        --sjdbGTFfile !{params."${params.reference}".stargtf} \\
        --readFilesCommand zcat \\
        --readFilesIn !{params.workdir}/01_preprocess/01_fastq/ultraplex_demux_!{samplefile}.fastq.gz \\
        --outFileNamePrefix !{params.workdir}/01_preprocess/02_alignment/!{samplefile}_ \\
        --outReadsUnmapped Fastx \\
        --outSAMtype BAM Unsorted \\
        --alignEndsType !{params.STAR.alignEndsType} \\
        --alignIntronMax !{params.STAR.alignIntronMax} \\
        --alignSJDBoverhangMin !{params.STAR.alignSJDBoverhangMin} \\
        --alignSJoverhangMin !{params.STAR.alignSJoverhangMin} \\
        --alignTranscriptsPerReadNmax !{params.STAR.alignTranscriptsPerReadNmax} \\
        --alignWindowsPerReadNmax !{params.STAR.alignWindowsPerReadNmax} \\
        --limitBAMsortRAM !{params.STAR.bamlimit} \\
        --limitOutSJcollapsed !{params.STAR.limitOutSJcollapsed} \\
        --outFilterMatchNmin !{params.STAR.outFilterMatchNmin} \\
        --outFilterMatchNminOverLread !{params.STAR.outFilterMatchNminOverLread} \\
        --outFilterMismatchNmax !{params.STAR.outFilterMismatchNmax} \\
        --outFilterMismatchNoverReadLmax !{params.STAR.outFilterMismatchNoverReadLmax} \\
        --outFilterMultimapNmax !{params.STAR.outFilterMultimapNmax} \\
        --outFilterMultimapScoreRange !{params.STAR.outFilterMultimapScoreRange} \\
        --outFilterScoreMin !{params.STAR.outFilterScoreMin} \\
        --outFilterType !{params.STAR.outFilterType} \\
        --outSAMattributes !{params.STAR.outSAMattributes} \\
        --outSAMunmapped !{params.STAR.outSAMunmapped} \\
        --outSJfilterCountTotalMin !{params.STAR.outSJfilterCountTotalMin.replace(",", " ")} \\
        --outSJfilterOverhangMin !{params.STAR.outSJfilterOverhangMin.replace(",", " ")} \\
        --outSJfilterReads !{params.STAR.outSJfilterReads} \\
        --seedMultimapNmax !{params.STAR.seedMultimapNmax} \\
        --seedNoneLociPerWindow !{params.STAR.seedNoneLociPerWindow} \\
        --seedPerReadNmax !{params.STAR.seedPerReadNmax} \\
        --seedPerWindowNmax !{params.STAR.seedPerWindowNmax} \\
        --sjdbScore !{params.STAR.sjdbScore} \\
        --winAnchorMultimapNmax !{params.STAR.winAnchorMultimapNmax} \\
        --quantMode !{params.STAR.quantmod}

        # sort file
        samtools sort -m 80G -T !{params.workdir}/01_preprocess/02_alignment/ !{params.workdir}/01_preprocess/02_alignment/!{samplefile}_Aligned.out.bam -o !{params.workdir}/01_preprocess/02_alignment/!{samplefile}_Aligned.sortedByCoord.out.bam

        # move final log file to output
        mv !{params.workdir}/01_preprocess/02_alignment/!{samplefile}_Log.final.out !{params.workdir}/log/STAR/!{samplefile}.log
        
        # move mates to unmapped file
        touch !{params.workdir}/01_preprocess/02_alignment/!{samplefile}.unmapped.out
        for f in !{params.workdir}/01_preprocess/02_alignment/!{samplefile}_Unmapped.out.mate*; do cat \$f >> !{params.workdir}/01_preprocess/02_alignment/!{samplefile}.unmapped.out; done
        """

}

process Index_Stats{
    """
    sort, index files
    run samstats on files
    """

    input:
        val samplefile

    output:
        val samplefile
    
    shell:
        """
        set -exo pipefail
        
        # Index
        cp !{params.workdir}/01_preprocess/02_alignment/!{samplefile}_Aligned.sortedByCoord.out.bam !{params.workdir}/02_bam/01_merged/!{samplefile}.si.bam
        samtools index -@ !{params.threads} !{params.workdir}/02_bam/01_merged/!{samplefile}.si.bam;
        
        # Run samstats
        samtools stats --threads !{params.threads} !{params.workdir}/02_bam/01_merged/!{samplefile}.si.bam > !{params.workdir}/00_QC/02_SamStats/!{samplefile}_samstats.txt
        """

}



process Check_ReadCounts {
    """
    In a recent project the incorrect species was selected and nearly 80% of all reads in all samples (N=6) were not mapped. 
    Rather than continuing with this type of potential low-quality sample, the pipeline should stop.

    http://www.htslib.org/doc/samtools-stats.html
    """

    input:
        val samplefile

    output:
        val samplefile

    shell:
        """
        for f in !{params.workdir}/00_QC/02_SamStats/!{samplefile}_samstats.txt; do
            # check samstats file to determine number of reads and reads mapped
            raw_count=`cat \$f | grep "raw total sequences" | awk -F"\t" '{{print \$3}}'`
            mapped_count=`cat \$f | grep "reads mapped:" | awk -F"\t" '{{print \$3}}'`
            found_percentage=\$((\$mapped_count / \$raw_count))

            # check the count against the set count_threshold, if counts found are lower than expected, fail
            fail=0
            if [ 1 -eq "\$(echo "\${{found_percentage}} < !{params.min_reads_mapped}" | bc)" ]; then
                flag="sample failed"
                fail=\$((fail + 1))
            else
                flag="sample passed"
            fi
            
            # put data into output
            echo "\$f\t\$found_percentage\t\$flag" >> !{params.workdir}/00_QC/02_SamStats/qc_read_count_raw_values.txt
        done

        # create output file
if [ 1 -eq "\$(echo "\${{fail}} > 0" | bc)" ]; then
            echo "Check sample log !{params.workdir}/00_QC/02_SamStats/qc_read_count_raw_values.txt to review what sample(s) failed" > !{params.workdir}/00_QC/02_SamStats/qc_read_count_check_fail.txt
        else
            touch !{params.workdir}/00_QC/02_SamStats/qc_read_count_check_pass.txt
        fi
        """


}




// rule multiqc:

// rule qc_troubleshoot:



process DeDup {
    """
    deduplicate reads
    sort,index dedup.bam file
    get header of dedup file
    """

    input:
        val samplefile

    output:
        val samplefile

    shell:
        """
        set -exo pipefail
 
        # Run UMI Tools Deduplication
        echo "Using the following UMI seperator: !{params.umi_sep}"
        umi_tools dedup \\
            -I !{params.workdir}/02_bam/01_merged/!{samplefile}.si.bam \\
            --method unique \\
            --multimapping-detection-method=NH \\
            --umi-separator=!{params.umi_sep} \\
            -S !{params.workdir}/temp/!{samplefile}.unmasked.bam \\
            --log2stderr;
        
        # Sort and Index
        samtools sort --threads !{params.threads} -m 10G -T !{params.workdir}/temp/ \\
            !{params.workdir}/temp/!{samplefile}.unmasked.bam \\
            -o !{params.workdir}/02_bam/02_dedup/!{samplefile}.dedup.si.bam;
        samtools index -@ !{params.threads} !{params.workdir}/02_bam/02_dedup/!{samplefile}.dedup.si.bam;
        """

}

process Remove_Spliced_Reads {
    """
    Remove spliced reads from genome-wide alignment.
    Spliced reads create spliced peaks and will be dealt with by mapping against the transcriptome.
    """

    input:
        val samplefile

    output:
        val samplefile

    shell:
        """
        samtools view -h !{params.workdir}/02_bam/02_dedup/!{samplefile}.dedup.si.bam | awk -v OFS="\t" '\$0 ~ /^@/{print \$0;next;} \$6 !~ /N/' | samtools view -b > !{params.workdir}/02_bam/02_dedup/!{samplefile}.filtered.bam
        samtools index -@ !{params.threads} !{params.workdir}/02_bam/02_dedup/!{samplefile}.filtered.bam
        """
}

process CTK_Peak_Calling {
    """
    Alternative peak calling using CTK.
    """

    container 'wilfriedguiblet/iclip:v3.0'

    input:
        val samplefile

    output:
        val samplefile

    shell:

        """
        export PERL5LIB=/opt/conda/lib/czplib
        bedtools bamtobed -i /data2/02_bam/02_dedup/!{samplefile}.filtered.bam > /data2/03_peaks/01_bed/!{samplefile}.bed

        /opt/conda/lib/ctk/tag2peak.pl \
        -big -ss \
        -p 0.001 --multi-test\
        --valley-seeking \
        --valley-depth 0.9 \
        /data2/03_peaks/01_bed/!{samplefile}.bed /data2/03_peaks/01_bed/!{samplefile}.peaks.bed \
        --out-boundary /data2/03_peaks/01_bed/!{samplefile}.peaks.boundary.bed \
        --out-half-PH /data2/03_peaks/01_bed/!{samplefile}.peaks.halfPH.bed \
        --multi-test
        """

}

process Create_Safs {
    """
    Reformat BED into SAF.
    """

    input:
        val samplefile

    output:
        val samplefile

    shell:
        """
        set -exo pipefail
        awk '{{OFS="\\t"; print \$1":"\$2"-"\$3"_"\$6,\$1,\$2,\$3,\$6}}' !{params.workdir}/03_peaks/01_bed/!{samplefile}.peaks.boundary.bed > !{params.workdir}/03_peaks/02_SAF/!{samplefile}.saf
        """
}

process Feature_Counts {
    """
    Unique reads (fractional counts correctly count splice reads for each peak.
    When peaks counts are combined for peaks connected by splicing in Rscript)
    Include Multimap reads - MM reads given fractional count based on # of mapping
    locations. All spliced reads also get fractional count. So Unique reads can get
    fractional count when spliced peaks combined in R script the summed counts give
    whole count for the unique alignement in combined peak.
    http://manpages.ubuntu.com/manpages/bionic/man1/featureCounts.1.html
    Output summary
    - Differences within any folder (allreadpeaks or uniquereadpeaks) should ONLY be the counts column -
    as this represent the number of peaks that were uniquely identified (uniqueCounts) or the number of peaks MM (allFracMMCounts)
    - Differences within folders (03_allreadpeaks, 03_uniquereadpeaks) will be the peaks identified, as the first takes
    all reads as input and the second takes only unique reads as input
    """

    container 'wilfriedguiblet/iclip:v3.0'

    input:
        val samplefile

    output:
        val samplefile

    shell:
        """
        set -exo pipefail
        # Run for allreadpeaks
        featureCounts -F SAF \\
            -a /data2/03_peaks/02_SAF/!{samplefile}.saf \\
            -O \\
            -J \\
            --fraction \\
            --minOverlap 1 \\
            -s 1 \\
            -T !{params.featureCounts.threads} \\
            -o /data2/03_peaks/03_counts/!{samplefile}_ALLreadpeaks_uniqueCounts.txt \\
            /data2/bamfiles/!{samplefile}.dedup.si.bam;
        featureCounts -F SAF \\
            -a /data2/03_peaks/02_SAF/!{samplefile}.saf \\
            -M \\
            -O \\
            -J \\
            --fraction \\
            --minOverlap 1 \\
            -s 1 \\
            -T !{params.featureCounts.threads} \\
            -o /data2/03_peaks/03_counts/!{samplefile}_ALLreadpeaks_FracMMCounts.txt \\
            /data2/bamfiles/!{samplefile}.dedup.si.bam;
        featureCounts -F SAF \\
            -a /data2/03_peaks/02_SAF/!{samplefile}.saf \\
            -M \\
            -O \\
            --minOverlap 1 \\
            -s 1 \\
            -T !{params.featureCounts.threads} \\
            -o /data2/03_peaks/03_counts/!{samplefile}_ALLreadpeaks_totalCounts.txt \\
            /data2/bamfiles/!{samplefile}.dedup.si.bam;
        """
}

process Alternate_Path {
    """
    Place-holder name - bypassing peak junction and maybe more
    """

    input:
        val samplefile

    output:
        val samplefile

    shell:
        """
        # Usage: script input1 input2 input3 output
        python !{params.workdir}/workflow/scripts/05_countmerger.py \\
                    --uniqueCountsFile !{params.workdir}/03_peaks/03_counts/!{samplefile}_ALLreadpeaks_uniqueCounts.txt \\
                    --FracMMCountsFile !{params.workdir}/03_peaks/03_counts/!{samplefile}_ALLreadpeaks_FracMMCounts.txt \\
                    --totalCountsFile !{params.workdir}/03_peaks/03_counts/!{samplefile}_ALLreadpeaks_totalCounts.txt \\
                    --outName !{params.workdir}/04_annotation/02_peaks/!{samplefile}_!{params.peakid}readPeaks_AllRegions.txt
        """
}

process Peak_Junction {
    """
    find peak junctions, annotations peaks, merges junction and annotation information
    """

    input:
        val samplefile

    output:
        val samplefile

    shell:
        """
        #bash script to run bedtools and get site2peak lookuptable
        bash !{params.workdir}/workflow/scripts/05_get_site2peak_lookup.sh \\
             !{params.workdir}/03_peaks/03_counts/!{samplefile}_!{params.peakid}readpeaks_FracMMCounts.txt.jcounts \\
             !{params.workdir}/03_peaks/03_counts/!{samplefile}_!{params.peakid}readpeaks_FracMMCounts.txt \\
             !{samplefile}_!{params.peakid} \\
             !{params.workdir}/04_annotation/02_peaks/ \\
             !{params.workdir}/workflow/scripts/05_jcounts2peakconnections.py


        # above bash script will create {output.splice_table}
        Rscript !{params.workdir}/workflow/scripts/05_Anno_junctions.R \\
            --rscript !{params.workdir}/workflow/scripts/05_peak_annotation_functions_V2.3.R \\
            --peak_type !{params.peakid} \\
            --peak_unique !{params.workdir}/03_peaks/03_counts/!{samplefile}_!{params.peakid}readpeaks_uniqueCounts.txt \\
            --peak_all !{params.workdir}/03_peaks/03_counts/!{samplefile}_!{params.peakid}readpeaks_FracMMCounts.txt \\
            --peak_total !{params.workdir}/03_peaks/03_counts/!{samplefile}_!{params.peakid}readpeaks_totalCounts.txt \\
            --join_junction !{params.sp_junc} \\
            --anno_anchor !{params.AnnoAnchor} \\
            --read_depth !{params.mincount} \\
            --demethod !{params.DEmethod} \\
            --sample_id !{samplefile} \\
            --ref_species !{params.reference} \\
            --splice_table !{params.workdir}/04_annotation/02_peaks/!{samplefile}_!{params.peakid}_connected_peaks.txt \\
            --tmp_dir !{params.workdir}/01_preprocess/07_rscripts/ \\
            --out_dir !{params.workdir}/04_annotation/02_peaks/ \\
            --out_file !{params.workdir}/04_annotation/02_peaks/!{samplefile}_!{params.peakid}readPeaks_AllRegions.txt \\
            --out_dir_DEP !{params.workdir}/05_demethod/01_input/ \\
            --output_file_error !{params.workdir}/04_annotation/read_depth_error.txt
        """

}

process Peak_Transcripts {
    """
    find peak junctions, annotations peaks, merges junction and annotation information
    why is this the same description as Peak_Junction ?
    """

    input:
        val samplefile

    output:
        val samplefile

    shell:
        """
        Rscript !{params.workdir}/workflow/scripts/05_Anno_Transcript.R \\
            --rscript !{params.workdir}/workflow/scripts/05_peak_annotation_functions_V2.3.R \\
            --peak_type !{params.peakid} \\
            --anno_anchor !{params.AnnoAnchor} \\
            --read_depth !{params.mincount} \\
            --sample_id !{samplefile} \\
            --ref_species !{params.reference} \\
            --anno_dir !{params.workdir}/04_annotation/01_project/ \\
            --reftable_path !{params.a_config} \\
            --gencode_path !{params."${params.reference}".gencodepath} \\
            --intron_path !{params."${params.reference}".intronpath} \\
            --rmsk_path !{params."${params.reference}".rmskpath} \\
            --tmp_dir !{params.workdir}/01_preprocess/07_rscripts/ \\
            --out_dir !{params.workdir}/04_annotation/02_peaks/ \\
            --out_file !{params.workdir}/04_annotation/02_peaks/!{samplefile}_!{params.peakid}readPeaks_AllRegions_transcripts_SameStrand.txt \\
            --anno_strand "SameStrand"

        Rscript !{params.workdir}/workflow/scripts/05_Anno_Transcript.R \\
            --rscript !{params.workdir}/workflow/scripts/05_peak_annotation_functions_V2.3.R \\
            --peak_type !{params.peakid} \\
            --anno_anchor !{params.AnnoAnchor} \\
            --read_depth !{params.mincount} \\
            --sample_id !{samplefile} \\
            --ref_species !{params.reference} \\
            --anno_dir !{params.workdir}/04_annotation/01_project/ \\
            --reftable_path !{params.a_config} \\
            --gencode_path !{params."${params.reference}".gencodepath} \\
            --intron_path !{params."${params.reference}".intronpath} \\
            --rmsk_path !{params."${params.reference}".rmskpath} \\
            --tmp_dir !{params.workdir}/01_preprocess/07_rscripts/ \\
            --out_dir !{params.workdir}/04_annotation/02_peaks/ \\
            --out_file !{params.workdir}/04_annotation/02_peaks/!{samplefile}_!{params.peakid}readPeaks_AllRegions_transcripts_OppoStrand.txt \\
            --anno_strand "OppoStrand"
        """

}

process Peak_ExonIntron {
    """
    find peak junctions, annotations peaks, merges junction and annotation information
    why is this the same description as Peak_Junction ?
    """

    input:
        val samplefile

    output:
        val samplefile

    shell:
        """
        Rscript !{params.workdir}/workflow/scripts/05_Anno_ExonIntron.R \\
            --rscript !{params.workdir}/workflow/scripts/05_peak_annotation_functions_V2.3.R \\
            --peak_type !{params.peakid} \\
            --anno_anchor !{params.AnnoAnchor} \\
            --read_depth !{params.mincount} \\
            --sample_id !{samplefile} \\
            --ref_species !{params.reference} \\
            --anno_dir !{params.workdir}/04_annotation/01_project/ \\
            --reftable_path !{params.a_config} \\
            --gencode_path !{params."${params.reference}".gencodepath} \\
            --intron_path !{params."${params.reference}".intronpath} \\
            --rmsk_path !{params."${params.reference}".rmskpath} \\
            --tmp_dir !{params.workdir}/01_preprocess/07_rscripts/same \\
            --out_dir !{params.workdir}/04_annotation/02_peaks/ \\
            --out_file !{params.workdir}/04_annotation/02_peaks/!{samplefile}_!{params.peakid}readPeaks_AllRegions_IntronExon_SameStrand.txt \\
            --anno_strand "SameStrand" 

        Rscript !{params.workdir}/workflow/scripts/05_Anno_ExonIntron.R \\
            --rscript !{params.workdir}/workflow/scripts/05_peak_annotation_functions_V2.3.R \\
            --peak_type !{params.peakid} \\
            --anno_anchor !{params.AnnoAnchor} \\
            --read_depth !{params.mincount} \\
            --sample_id !{samplefile} \\
            --ref_species !{params.reference} \\
            --anno_dir !{params.workdir}/04_annotation/01_project/ \\
            --reftable_path !{params.a_config} \\
            --gencode_path !{params."${params.reference}".gencodepath} \\
            --intron_path !{params."${params.reference}".intronpath} \\
            --rmsk_path !{params."${params.reference}".rmskpath} \\
            --tmp_dir !{params.workdir}/01_preprocess/07_rscripts/oppo \\
            --out_dir !{params.workdir}/04_annotation/02_peaks/ \\
            --out_file !{params.workdir}/04_annotation/02_peaks/!{samplefile}_!{params.peakid}readPeaks_AllRegions_IntronExon_OppoStrand.txt \\
            --anno_strand "OppoStrand"
        """
}


process Peak_RMSK {
    """
    find peak junctions, annotations peaks, merges junction and annotation information
    why is this the same description as Peak_Junction ?
    """

    input:
        val samplefile

    output:
        val samplefile

    shell:
        """
        Rscript !{params.workdir}/workflow/scripts/05_Anno_RMSK.R \\
            --rscript !{params.workdir}/workflow/scripts/05_peak_annotation_functions_V2.3.R \\
            --peak_type !{params.peakid} \\
            --anno_anchor !{params.AnnoAnchor} \\
            --read_depth !{params.mincount} \\
            --sample_id !{samplefile} \\
            --ref_species !{params.reference} \\
            --anno_dir !{params.workdir}/04_annotation/01_project/ \\
            --reftable_path !{params.a_config} \\
            --gencode_path !{params."${params.reference}".gencodepath} \\
            --intron_path !{params."${params.reference}".intronpath} \\
            --rmsk_path !{params."${params.reference}".rmskpath} \\
            --tmp_dir !{params.workdir}/01_preprocess/07_rscripts/ \\
            --out_dir !{params.workdir}/04_annotation/02_peaks/ \\
            --out_file !{params.workdir}/04_annotation/02_peaks/!{samplefile}_!{params.peakid}readPeaks_AllRegions_RMSK_SameStrand.txt \\
            --anno_strand "SameStrand"

        Rscript !{params.workdir}/workflow/scripts/05_Anno_RMSK.R \\
            --rscript !{params.workdir}/workflow/scripts/05_peak_annotation_functions_V2.3.R \\
            --peak_type !{params.peakid} \\
            --anno_anchor !{params.AnnoAnchor} \\
            --read_depth !{params.mincount} \\
            --sample_id !{samplefile} \\
            --ref_species !{params.reference} \\
            --anno_dir !{params.workdir}/04_annotation/01_project/ \\
            --reftable_path !{params.a_config} \\
            --gencode_path !{params."${params.reference}".gencodepath} \\
            --intron_path !{params."${params.reference}".intronpath} \\
            --rmsk_path !{params."${params.reference}".rmskpath} \\
            --tmp_dir !{params.workdir}/01_preprocess/07_rscripts/ \\
            --out_dir !{params.workdir}/04_annotation/02_peaks/ \\
            --out_file !{params.workdir}/04_annotation/02_peaks/!{samplefile}_!{params.peakid}readPeaks_AllRegions_RMSK_OppoStrand.txt \\
            --anno_strand "OppoStrand"
        """
}

process Peak_Process {
    """
    find peak junctions, annotations peaks, merges junction and annotation information
    why is this the same description as Peak_Junction ?
    """

    input:
        val samplefile

    output:
        val samplefile

    shell:
        """
        Rscript !{params.workdir}/workflow/scripts/05_Anno_Process.R \\
            --rscript !{params.workdir}/workflow/scripts/05_peak_annotation_functions_V2.3.R \\
            --peak_type !{params.peakid} \\
            --anno_anchor !{params.AnnoAnchor} \\
            --read_depth !{params.mincount} \\
            --sample_id !{samplefile} \\
            --ref_species !{params.reference} \\
            --tmp_dir !{params.workdir}/01_preprocess/07_rscripts/ \\
            --out_dir !{params.workdir}/04_annotation/02_peaks/ \\
            --out_file !{params.workdir}/04_annotation/02_peaks/!{samplefile}_!{params.peakid}readPeaks_annotation_complete.txt
        """

}


process Annotation_Report {
    """
    generates an HTML report for peak annotations
    """

    input:
        val samplefile

    output:
        val samplefile

    shell:
        """
        Rscript -e 'library(rmarkdown); \
        rmarkdown::render("!{params.workdir}/workflow/scripts/06_annotation.Rmd",
            output_file = "!{params.workdir}/04_annotation/!{samplefile}_!{params.peakid}readPeaks_final_report.html", \
            params= list(samplename = "!{samplefile}", \
                peak_in = "!{params.workdir}/04_annotation/02_peaks/!{samplefile}_!{params.peakid}readPeaks_annotation_complete.txt", \
                output_table = "!{params.workdir}/04_annotation/!{samplefile}_annotation_!{params.peakid}readPeaks_final_table.txt", \
                readdepth = "!{params.mincount}", \
                PeakIdnt = "!{params.peakid}"))'
        """        

}




MANORM_constrasts = Channel.of( ['YKO_Clip3', 'Ro_Clip3'], ['Y1KO_Clip3', 'Ro_Clip3'], ['Y3KO_Clip3', 'Ro_Clip3'] ) 

process MANORM_analysis {

    input:
       tuple val(sample), val(background)

    output:
        tuple val(sample), val(background)

    shell:
        """
        manorm \\
            --p1 "!{params.workdir}/03_peaks/01_bed/!{sample}.peaks.boundary.bed" \\
            --p2 "!{params.workdir}/03_peaks/01_bed/!{background}.peaks.boundary.bed" \\
            --r1 "!{params.workdir}/03_peaks/01_bed/!{sample}.bed" \\
            --r2 "!{params.workdir}/03_peaks/01_bed/!{background}.bed" \\
            --s1 0 \\
            --s2 0 \\
            -p 1 \\
            -m 0 \\
            -w !{params.manorm_w} \\
            -d !{params.manorm_d} \\
            -s \\
            -o !{params.workdir}/05_demethod/02_analysis/!{sample}_vs_!{background} \\
            --name1 !{sample} \\
            --name2 !{background}


        awk -v OFS='\t' '{print \$1,\$2,\$3,\$4}' !{params.workdir}/05_demethod/02_analysis/!{sample}_vs_!{background}/output_filters/!{sample}_M_above_0.0_biased_peaks.bed > !{params.workdir}/05_demethod/02_analysis/!{sample}.manorm.bed

        
        # rename MANORM final output file
        #mv {params.base}{wildcards.group_id}_all_MAvalues.xls {output.mavals}

        # rename individual file names for each sample
        #mv {params.base}{params.gid_1}_MAvalues.xls {params.base}{params.gid_1}_{params.peak_id}readPeaks_MAvalues.xls
        #mv {params.base}{params.gid_2}_MAvalues.xls {params.base}{params.gid_2}_{params.peak_id}readPeaks_MAvalues.xls

        # mv folders of figures, filters, tracks to new location
        # remove folders if they already exist
        #if [[ -d {params.base}output_figures_{params.peak_id}readPeaks ]]; then rm -r {params.base}output_figures_{params.peak_id}readPeaks; fi
        #if [[ -d {params.base}output_filters_{params.peak_id}readPeaks ]]; then rm -r {params.base}output_filters_{params.peak_id}readPeaks; fi
        #if [[ -d {params.base}output_tracks_{params.peak_id}readPeaks ]]; then rm -r {params.base}output_tracks_{params.peak_id}readPeaks; fi
        #mv {params.base}output_figures {params.base}output_figures_{params.peak_id}readPeaks
        #mv {params.base}output_filters {params.base}output_filters_{params.peak_id}readPeaks
        #mv {params.base}output_tracks {params.base}output_tracks_{params.peak_id}readPeaks
        """    

}

process Manorm_Report {

    input:
       tuple val(sample), val(background)

    output:
        tuple val(sample), val(background)

    shell:
        """
        set -exo pipefail
        
        ### for sample vs Bg compairson
        featureCounts -F SAF \\
            -a out_dir,'03_peaks','02_SAF','{gid_1}_' + peak_id + 'readPeaks.SAF' \\
            -O \\
            --fraction \\
            --minOverlap 1 \\
            -s 1 \\
            -T {threads} \\
            -o {output.bkUniqcountsmplPk} \\
            {params.bkbam}
        featureCounts -F SAF \\
            -a {params.smplSAF} \\
            -M \\
            -O \\
            --fraction \\
            --minOverlap 1 \\
            -s 1 \\
            -T {threads} \\
            -o {output.bkMMcountsmplPk} \\
            {params.bkbam}
        Rscript {params.script} \\
            --samplename {params.gid_1} \\
            --background {params.gid_2} \\
            --peak_anno_g1 {params.anno_dir}/{params.gid_1}_annotation_{params.peak_id}readPeaks_final_table.txt \\
            --peak_anno_g2 {params.anno_dir}/{params.gid_2}_annotation_{params.peak_id}readPeaks_final_table.txt \\
            --Smplpeak_bkgroundCount_MM {output.bkMMcountsmplPk} \\
            --Smplpeak_bkgroundCount_unique {output.bkUniqcountsmplPk} \\
            --pos_manorm {params.de_dir}/{wildcards.group_id}/{wildcards.group_id}_P/{params.gid_1}_{params.peak_id}readPeaks_MAvalues.xls \\
            --neg_manorm {params.de_dir}/{wildcards.group_id}/{wildcards.group_id}_N/{params.gid_1}_{params.peak_id}readPeaks_MAvalues.xls \\
            --output_file {output.post_proc}
        
        ### for Bg vs sample compairson
        featureCounts -F SAF \\
            -a {params.bkSAF} \\
            -O \\
            --fraction \\
            --minOverlap 1 \\
            -s 1 \\
            -T {threads} \\
            -o {output.smplUniqcountbkPk} \\
            {params.smplbam}
        featureCounts -F SAF \\
            -a {params.bkSAF} \\
            -M \\
            -O \\
            --fraction \\
            --minOverlap 1 \\
            -s 1 \\
            -T {threads} \\
            -o {output.smplMMcountbkPk} \\
            {params.smplbam}
        Rscript {params.script} \\
            --samplename {params.gid_2} \\
            --background {params.gid_1} \\
            --peak_anno_g1 {params.anno_dir}/{params.gid_2}_annotation_{params.peak_id}readPeaks_final_table.txt \\
            --peak_anno_g2 {params.anno_dir}/{params.gid_1}_annotation_{params.peak_id}readPeaks_final_table.txt \\
            --Smplpeak_bkgroundCount_MM {output.smplMMcountbkPk} \\
            --Smplpeak_bkgroundCount_unique {output.smplUniqcountbkPk} \\
            --pos_manorm {params.de_dir}/{wildcards.group_id}/{wildcards.group_id}_P/{params.gid_2}_{params.peak_id}readPeaks_MAvalues.xls \\
            --neg_manorm {params.de_dir}/{wildcards.group_id}/{wildcards.group_id}_N/{params.gid_2}_{params.peak_id}readPeaks_MAvalues.xls \\
            --output_file {output.post_procRev}
        """

}


workflow {
    //Create_Project_Annotations(create_unique)
    //Init_ReadCounts_Reportfile(create_unique)
    //QC_Barcode(rawfiles)
    //Demultiplex(rawfiles)
    //Star(bamfiles)
    //Index_Stats(Star.out)
    //Check_ReadCounts(Index_Stats.out)
    //DeDup(Check_ReadCounts.out)
    //Remove_Spliced_Reads(DeDup.out)
    //CTK_Peak_Calling(Remove_Spliced_Reads.out)
    //Create_Safs(CTK_Peak_Calling.out)
    //Feature_Counts(Create_Safs.out)
    //Alternate_Path(Feature_Counts.out)
    //Peak_Junction(Feature_Counts.out)
    //Peak_Transcripts(Peak_Junction.out)
    //Peak_ExonIntron(Peak_Transcripts.out)
    //Peak_RMSK(Peak_ExonIntron.out)
    //Peak_Process(Peak_RMSK.out)
    //Annotation_Report(Peak_Process.out)
    //Annotation_Report(bedfiles)
    //MANORM_analysis(MANORM_constrasts)

    Create_Project_Annotations(unique_ch) | Init_ReadCounts_Reportfile

    rawfiles_tuple = Init_ReadCounts_Reportfile.out.combine(rawfiles_ch)
    QC_Barcode(rawfiles_tuple) | Demultiplex

    samplefiles_tuple = Demultiplex.out.combine(samplefiles_ch)
    Star(samplefiles_tuple) | Index_Stats | Check_ReadCounts | DeDup | Remove_Spliced_Reads | CTK_Peak_Calling | Create_Safs | Feature_Counts | Alternate_Path

    Peak_Transcripts(Alternate_Path.out)
    Peak_ExonIntron(Alternate_Path.out)
    Peak_RMSK(Alternate_Path.out)

    collapsed_channel = Peak_Transcripts.out.concat(Peak_ExonIntron.out, Peak_RMSK.out).unique()

    //Peak_Process(collapsed_channel) | Annotation_Report

    //samplefiles_tuple.view()
    
}
