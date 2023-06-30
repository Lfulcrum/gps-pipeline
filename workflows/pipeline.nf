// Import process modules
include { PREPROCESS; READ_QC } from "$projectDir/modules/preprocess"
include { ASSEMBLY_UNICYCLER; ASSEMBLY_SHOVILL; ASSEMBLY_ASSESS; ASSEMBLY_QC } from "$projectDir/modules/assembly"
include { CREATE_REF_GENOME_BWA_DB; MAPPING; SAM_TO_SORTED_BAM; SNP_CALL; HET_SNP_COUNT; MAPPING_QC } from "$projectDir/modules/mapping"
include { GET_KRAKEN_DB; TAXONOMY; TAXONOMY_QC } from "$projectDir/modules/taxonomy"
include { OVERALL_QC } from "$projectDir/modules/overall_qc"
include { GET_POPPUNK_DB; GET_POPPUNK_EXT_CLUSTERS; LINEAGE } from "$projectDir/modules/lineage"
include { GET_SEROBA_DB; CREATE_SEROBA_DB; SEROTYPE } from "$projectDir/modules/serotype"
include { MLST } from "$projectDir/modules/mlst"
include { PBP_RESISTANCE; GET_PBP_RESISTANCE; CREATE_ARIBA_DB; OTHER_RESISTANCE; GET_OTHER_RESISTANCE } from "$projectDir/modules/amr"

// Main pipeline workflow
workflow PIPELINE {
    main:
    // Get path and prefix of Reference Genome BWA Database, generate from assembly if necessary
    ref_genome_bwa_db = CREATE_REF_GENOME_BWA_DB(params.ref_genome, params.ref_genome_bwa_db_local)

    // Get path to Kraken2 Database, download if necessary
    kraken2_db = GET_KRAKEN_DB(params.kraken2_db_remote, params.kraken2_db_local)

    // Get path to SeroBA Databases, clone and rebuild if necessary
    GET_SEROBA_DB(params.seroba_remote, params.seroba_local, params.seroba_kmer)
    seroba_db = CREATE_SEROBA_DB(params.seroba_remote, params.seroba_local, GET_SEROBA_DB.out.create_db, params.seroba_kmer)

    // Get paths to PopPUNK Database and External Clusters, download if necessary
    poppunk_db = GET_POPPUNK_DB(params.poppunk_db_remote, params.poppunk_local)
    poppunk_ext_clusters = GET_POPPUNK_EXT_CLUSTERS(params.poppunk_ext_remote, params.poppunk_local)

    // Get path to ARIBA database, generate from reference sequences and metadata if ncessary
    ariba_db = CREATE_ARIBA_DB(params.ariba_ref, params.ariba_metadata, params.ariba_db_local)

    // Get read pairs into Channel raw_read_pairs_ch
    raw_read_pairs_ch = Channel.fromFilePairs("$params.reads/*_{,R}{1,2}{,_001}.{fq,fastq}{,.gz}", checkIfExists: true)

    // Preprocess read pairs
    // Output into Channels PREPROCESS.out.processed_reads & PREPROCESS.out.json
    PREPROCESS(raw_read_pairs_ch)

    // From Channel PREPROCESS.out.json, provide Read QC status
    // Output into Channel READ_QC_PASSED_READS_ch
    READ_QC(PREPROCESS.out.json, params.length_low, params.depth)

    // From Channel PREPROCESS.out.processed_reads, only output reads of samples passed Read QC based on Channel READ_QC.out.result
    READ_QC_PASSED_READS_ch = READ_QC.out.result.join(PREPROCESS.out.processed_reads, failOnDuplicate: true, failOnMismatch: true)
                        .filter { it[1] == 'PASS' }
                        .map { it[0, 2..-1] }

    // From Channel READ_QC_PASSED_READS_ch, assemble the preprocess read pairs
    // Output into Channel ASSEMBLY_ch, and hardlink the assemblies to $params.output directory
    switch (params.assembler) {
        case 'shovill':
            ASSEMBLY_ch = ASSEMBLY_SHOVILL(READ_QC_PASSED_READS_ch, params.min_contig_length)
            break

        case 'unicycler':
            ASSEMBLY_ch = ASSEMBLY_UNICYCLER(READ_QC_PASSED_READS_ch, params.min_contig_length)
            break
    }

    // From Channel ASSEMBLY_ch, assess assembly quality
    ASSEMBLY_ASSESS(ASSEMBLY_ch)

    // From Channel ASSEMBLY_ASSESS.out.report and Channel READ_QC.out.bases, provide Assembly QC status
    // Output into Channels ASSEMBLY_QC.out.detailed_result & ASSEMBLY_QC.out.result
    ASSEMBLY_QC(
        ASSEMBLY_ASSESS.out.report
        .join(READ_QC.out.bases, failOnDuplicate: true),
        params.contigs,
        params.length_low,
        params.length_high,
        params.depth
    )

    // From Channel READ_QC_PASSED_READS_ch map reads to reference
    // Output into Channel MAPPING.out.sam
    MAPPING(ref_genome_bwa_db, READ_QC_PASSED_READS_ch)

    // From Channel MAPPING.out.sam, Convert SAM into sorted BAM and calculate reference coverage
    // Output into Channels SAM_TO_SORTED_BAM.out.bam and SAM_TO_SORTED_BAM.out.ref_coverage
    SAM_TO_SORTED_BAM(MAPPING.out.sam, params.lite)

    // From Channel SAM_TO_SORTED_BAM.out.bam calculates non-cluster Het-SNP site count
    // Output into Channel HET_SNP_COUNT.out.result
    SNP_CALL(params.ref_genome, SAM_TO_SORTED_BAM.out.bam, params.lite) | HET_SNP_COUNT

    // Merge Channels SAM_TO_SORTED_BAM.out.ref_coverage & HET_SNP_COUNT.out.result to provide Mapping QC Status
    // Output into Channels MAPPING_QC.out.detailed_result & MAPPING_QC.out.result
    MAPPING_QC(
        SAM_TO_SORTED_BAM.out.ref_coverage
        .join(HET_SNP_COUNT.out.result, failOnDuplicate: true, failOnMismatch: true),
        params.ref_coverage,
        params.het_snp_site
    )

    // From Channel READ_QC_PASSED_READS_ch assess Streptococcus pneumoniae percentage in reads
    // Output into Channels TAXONOMY.out.detailed_result & TAXONOMY.out.result report
    TAXONOMY(kraken2_db, params.kraken2_memory_mapping, READ_QC_PASSED_READS_ch)

    // From Channel TAXONOMY.out.report, provide taxonomy QC status
    // Output into Channels TAXONOMY_QC.out.detailed_result & TAXONOMY_QC.out.result report
    TAXONOMY_QC(TAXONOMY.out.report, params.spneumo_percentage)

    // Merge Channels ASSEMBLY_QC.out.result & MAPPING_QC.out.result & TAXONOMY_QC.out.result to provide Overall QC Status
    // Output into Channel OVERALL_QC.out.result
    OVERALL_QC(
        ASSEMBLY_QC.out.result
        .join(MAPPING_QC.out.result, failOnDuplicate: true, remainder: true)
        .join(TAXONOMY_QC.out.result, failOnDuplicate: true)
    )

    // From Channel READ_QC_PASSED_READS_ch, only output reads of samples passed overall QC based on Channel OVERALL_QC.out.result
    OVERALL_QC_PASSED_READS_ch = OVERALL_QC.out.result.join(READ_QC_PASSED_READS_ch, failOnDuplicate: true)
                        .filter { it[1] == 'PASS' }
                        .map { it[0, 2..-1] }

    // From Channel ASSEMBLY_ch, only output assemblies of samples passed overall QC based on Channel OVERALL_QC.out.result
    OVERALL_QC_PASSED_ASSEMBLIES_ch = OVERALL_QC.out.result.join(ASSEMBLY_ch, failOnDuplicate: true)
                            .filter { it[1] == 'PASS' }
                            .map { it[0, 2..-1] }

    // From Channel OVERALL_QC_PASSED_ASSEMBLIES_ch, generate PopPUNK query file containing assemblies of samples passed overall QC
    // Output into POPPUNK_QFILE
    POPPUNK_QFILE = OVERALL_QC_PASSED_ASSEMBLIES_ch
                    .map { it.join'\t' }
                    .collectFile(name: 'qfile.txt', newLine: true)

    // From generated POPPUNK_QFILE, assign GPSC to samples passed overall QC
    LINEAGE(poppunk_db, poppunk_ext_clusters, POPPUNK_QFILE)

    // From Channel OVERALL_QC_PASSED_READS_ch, serotype the preprocess reads of samples passed overall QC
    // Output into Channel SEROTYPE.out.result
    SEROTYPE(seroba_db, OVERALL_QC_PASSED_READS_ch)

    // From Channel OVERALL_QC_PASSED_ASSEMBLIES_ch, PubMLST typing the assemblies of samples passed overall QC
    // Output into Channel MLST.out.result
    MLST(OVERALL_QC_PASSED_ASSEMBLIES_ch)

    // From Channel OVERALL_QC_PASSED_ASSEMBLIES_ch, assign PBP genes and estimate MIC (minimum inhibitory concentration) for 6 Beta-lactam antibiotics
    // Output into Channel GET_PBP_RESISTANCE.out.result
    PBP_RESISTANCE(OVERALL_QC_PASSED_ASSEMBLIES_ch)
    GET_PBP_RESISTANCE(PBP_RESISTANCE.out.json)

    // From Channel OVERALL_QC_PASSED_ASSEMBLIES_ch, infer resistance (also determinants if any) of other antimicrobials
    // Output into Channel GET_OTHER_RESISTANCE.out.result
    OTHER_RESISTANCE(ariba_db, OVERALL_QC_PASSED_READS_ch)
    OTHER_RESISTANCE.out.reports.view()
    GET_OTHER_RESISTANCE(OTHER_RESISTANCE.out.reports)

    // Generate results.csv by sorted sample_id based on merged Channels
    // READ_QC.out.result, ASSEMBLY_QC.out.result, MAPPING_QC.out.result, TAXONOMY_QC.out.result, OVERALL_QC.out.result,
    // READ_QC.out.bases, ASSEMBLY_QC.out.info, MAPPING_QC.out.info, TAXONOMY_QC.out.percentage
    // LINEAGE.out.csv,
    // SEROTYPE.out.result,
    // MLST.out.result,
    // GET_PBP_RESISTANCE.out.result,
    // GET_OTHER_RESISTANCE.out.result
    //
    // Replace null with approiate amount of "_" items when sample_id does not exist in that output (i.e. QC rejected)
    READ_QC.out.result
    .join(ASSEMBLY_QC.out.result, failOnDuplicate: true, remainder: true)
        .map { (it[-1] == null) ? it[0..-2] + ['_'] : it }
    .join(MAPPING_QC.out.result, failOnDuplicate: true, remainder: true)
        .map { (it[-1] == null) ? it[0..-2] + ['_'] : it }
    .join(TAXONOMY_QC.out.result, failOnDuplicate: true, remainder: true)
        .map { (it[-1] == null) ? it[0..-2] + ['_'] : it }
    .join(OVERALL_QC.out.result, failOnDuplicate: true, remainder: true)
        .map { (it[-1] == null) ? it[0..-2] + ['FAIL'] : it }
    .join(READ_QC.out.bases, failOnDuplicate: true, failOnMismatch: true)
    .join(ASSEMBLY_QC.out.info, failOnDuplicate: true, remainder: true)
        .map { (it[-1] == null) ? it[0..-2] + ['_'] * 3 : it }
    .join(MAPPING_QC.out.info, failOnDuplicate: true, remainder: true)
        .map { (it[-1] == null) ? it[0..-2] + ['_'] * 2 : it }
    .join(TAXONOMY_QC.out.percentage, failOnDuplicate: true, remainder: true)
        .map { (it[-1] == null) ? it[0..-2] + ['_'] : it }
    .join(LINEAGE.out.csv.splitCsv(skip: 1), failOnDuplicate: true, remainder: true)
        .map { (it[-1] == null) ? it[0..-2] + ['_'] : it }
    .join(SEROTYPE.out.result, failOnDuplicate: true, remainder: true)
        .map { (it[-1] == null) ? it[0..-2] + ['_'] : it }
    .join(MLST.out.result, failOnDuplicate: true, remainder: true)
        .map { (it[-1] == null) ? it[0..-2] + ['_'] * 8 : it }
    .join(GET_PBP_RESISTANCE.out.result, failOnDuplicate: true, remainder: true)
        .map { (it[-1] == null) ? it[0..-2] + ['_'] * 18 : it }
    // .join(GET_OTHER_RESISTANCE.out, failOnDuplicate: true, remainder: true)
    //     .map { (it[-1] == null) ? it[0..-2] + ['_'] * 20 : it }
    .map { it.collect {"\"$it\""}.join',' }
    .collectFile(
        name: 'results.csv',
        storeDir: "$params.output",
        seed: [
                'Sample_ID',
                'Read_QC', 'Assembly_QC', 'Mapping_QC', 'Taxonomy_QC', 'Overall_QC',
                'Bases', 
                'Contigs#' , 'Assembly_Length', 'Seq_Depth', 
                'Ref_Cov_%', 'Het-SNP#' , 
                'S.Pneumo_%', 
                'GPSC',
                'Serotype',
                'ST', 'aroE', 'gdh', 'gki', 'recP', 'spi', 'xpt', 'ddl',
                'pbp1a', 'pbp2b', 'pbp2x', 'AMO_MIC', 'AMO_Res', 'CFT_MIC', 'CFT_Res(Meningital)', 'CFT_Res(Non-meningital)', 'TAX_MIC', 'TAX_Res(Meningital)', 'TAX_Res(Non-meningital)', 'CFX_MIC', 'CFX_Res', 'MER_MIC', 'MER_Res', 'PEN_MIC', 'PEN_Res(Meningital)', 'PEN_Res(Non-meningital)', 
                // 'CHL_Res', 'CHL_Determinant', 'CLI_Res', 'CLI_Determinant', 'ERY_Res', 'ERY_Determinant', 'FQ_Res', 'FQ_Determinant', 'KAN_Res', 'KAN_Determinant', 'LZO_Res', 'LZO_Determinant', 'TET_Res', 'TET_Determinant', 'TMP_Res', 'TMP_Determinant', 'SMX_Res', 'SMX_Determinant', 'COT_Res', 'COT_Determinant'
            ].join(','),
        sort: { it.split(',')[0] },
        newLine: true
    )

    // Pass to SAVE_INFO sub-workflow
    DATABASES_INFO = ref_genome_bwa_db.map { it[0] }
                    .merge(ariba_db.map { it[0] })
                    .merge(kraken2_db)
                    .merge(seroba_db.map { it[0] })
                    .merge(poppunk_db.map { it[0] })
                    .merge(poppunk_ext_clusters)
                    .map {
                        [
                            bwa_db_path: it[0],
                            ariba_db_path: it[1],
                            kraken2_db_path: it[2],
                            seroba_db_path: it[3],
                            poppunk_db_path: it[4]
                        ]
                    }

    emit:
    databases_info = DATABASES_INFO
}
