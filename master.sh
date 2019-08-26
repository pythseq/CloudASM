
########################## Copy and paste within the bash ################################

# GCP global variables
PROJECT_ID="hackensack-tyco"
REGION_ID="us-central1"
ZONE_ID="us-central1-b"
DOCKER_IMAGE="gcr.io/hackensack-tyco/wgbs-asm"

# Big Query variables
DATASET_ID="wgbs_asm" 

# Cloud storage variables
OUTPUT_B="em-encode-deux" # will be created by the script
REF_DATA_B="wgbs-ref-files" # See documentation for what it needs to contain

# Path of where you downloaded the Github scripts
SCRIPTS="$HOME/GITHUB_REPOS/wgbs-asm/"

# Create a bucket with the analysis
gsutil mb -c regional -l $REGION_ID gs://$OUTPUT_B 

# Create a local directory to download files
WD="$HOME/wgbs" && mkdir -p $WD && cd $WD

# Download the meta information about the samples and files to be analyzed.
gsutil cp gs://$INPUT_B/samples.tsv $WD
dos2unix samples.tsv 

# List of samples
awk -F "\t" \
    '{if (NR!=1) \
    print $1}' samples.tsv | uniq > sample_id.txt

echo "There are" $(cat sample_id.txt | wc -l) "samples to be analyzed"

########################## Unzip, rename, and split fastq files ################################

# Create an TSV file with parameters for the job
awk -v INPUT_B="${INPUT_B}" \
    -v OUTPUT_B="${OUTPUT_B}" \
    'BEGIN { FS=OFS="\t" } 
    {if (NR!=1) 
        print "gs://"INPUT_B"/"$1"/"$2, 
              $5".fastq", 
              "gs://"OUTPUT_B"/"$1"/split_fastq/*.fastq" 
     }' \
    samples.tsv > decompress.tsv 

# Add headers to the file
sed -i '1i --input ZIPPED\t--env FASTQ\t--output OUTPUT_FILES' decompress.tsv

# Launch job
dsub \
  --provider google-v2 \
  --project $PROJECT_ID \
  --zones $ZONE_ID \
  --logging gs://$OUTPUT_B/logging/ \
  --disk-size 10 \
  --preemptible \
  --image $DOCKER_IMAGE \
  --command 'gunzip ${ZIPPED} && \
             mv ${ZIPPED%.gz} $(dirname "${ZIPPED}")/${FASTQ} && \
             split -l 1200000 \
                --numeric-suffixes --suffix-length=4 \
                --additional-suffix=.fastq \
                $(dirname "${ZIPPED}")/${FASTQ} \
                $(dirname "${OUTPUT_FILES}")/${FASTQ%fastq}' \
  --tasks decompress.tsv \
  --wait

########################## Trim a pair of fastq shards ################################

# Create an TSV file with parameters for the job
rm -f trim.tsv && touch trim.tsv

# Prepare inputs and outputs for each sample
while read SAMPLE ; do
  # Get the list of split fastq files
  gsutil ls gs://$OUTPUT_B/$SAMPLE/split_fastq > fastq_shard_${SAMPLE}.txt
  
  # Isolate R1 files
  cat fastq_shard_${SAMPLE}.txt | grep R1 > R1_files_${SAMPLE}.txt && sort R1_files_${SAMPLE}.txt
  # Isolate R2 files
  cat fastq_shard_${SAMPLE}.txt | grep R2 > R2_files_${SAMPLE}.txt && sort R2_files_${SAMPLE}.txt
  # Create a file repeating the output dir for the pair
  NB_PAIRS=$(cat R1_files_${SAMPLE}.txt | wc -l)
  rm -f output_dir_${SAMPLE}.txt && touch output_dir_${SAMPLE}.txt 
  for i in `seq 1 $NB_PAIRS` ; do 
    echo 'gs://'$OUTPUT_B'/'$SAMPLE'/trimmed_fastq/*' >> output_dir_${SAMPLE}.txt
  done
  
  # Add the sample's 3 info (R1, R2, output folder) to the TSV file
  paste -d '\t' R1_files_${SAMPLE}.txt R2_files_${SAMPLE}.txt output_dir_${SAMPLE}.txt >> trim.tsv
done < sample_id.txt

# Add headers to the file
sed -i '1i --input R1\t--input R2\t--output FOLDER' trim.tsv

# Print a message in the terminal
echo "There are" $(cat trim.tsv | wc -l) "to be launched"

# Submit job. Make sure you have enough resources
dsub \
  --provider google-v2 \
  --project $PROJECT_ID \
  --zones $ZONE_ID \
  --image $DOCKER_IMAGE \
  --machine-type n1-standard-2 \
  --preemptible \
  --logging gs://$OUTPUT_B/logging/ \
  --command 'trim_galore \
      -a AGATCGGAAGAGCACACGTCTGAAC \
      -a2 AGATCGGAAGAGCGTCGTGTAGGGA \
      --quality 30 \
      --length 40 \
      --paired \
      --retain_unpaired \
      --fastqc \
      ${R1} \
      ${R2} \
      --output_dir $(dirname ${FOLDER})' \
  --tasks trim.tsv \
  --wait


########################## Align a pair of fastq shards ################################

# Prepare TSV file
echo -e "--input R1\t--input R2\t--output OUTPUT_DIR" > align.tsv

# Prepare inputs and outputs for each sample
while read SAMPLE ; do
  # Get the list of split fastq files
  gsutil ls gs://$OUTPUT_B/$SAMPLE/trimmed_fastq/*val*.fq > trimmed_fastq_shard_${SAMPLE}.txt
  
  # Isolate R1 files
  cat trimmed_fastq_shard_${SAMPLE}.txt | grep R1 > R1_files_${SAMPLE}.txt && sort R1_files_${SAMPLE}.txt
  # Isolate R2 files
  cat trimmed_fastq_shard_${SAMPLE}.txt | grep R2 > R2_files_${SAMPLE}.txt && sort R2_files_${SAMPLE}.txt
  
  # Create a file repeating the output dir for the pair
  NB_PAIRS=$(cat R1_files_${SAMPLE}.txt | wc -l)
  rm -f output_dir_${SAMPLE}.txt && touch output_dir_${SAMPLE}.txt 
  for i in `seq 1 $NB_PAIRS` ; do 
    echo 'gs://'$OUTPUT_B'/'$SAMPLE'/aligned_per_chard/*' >> output_dir_${SAMPLE}.txt
  done
  
  # Add the sample's 3 info (R1, R2, output folder) to the TSV file
  paste -d '\t' R1_files_${SAMPLE}.txt R2_files_${SAMPLE}.txt output_dir_${SAMPLE}.txt >> align.tsv
done < sample_id.txt

# Print a message in the terminal
echo "There are" $(cat align.tsv | wc -l) "to be launched"

# Submit job
dsub \
  --provider google-v2 \
  --project $PROJECT_ID \
  --zones $ZONE_ID \
  --image $DOCKER_IMAGE \
  --machine-type n1-standard-16 \
  --preemptible \
  --disk-size 40 \
  --logging gs://$OUTPUT_B/logging/ \
  --input-recursive REF_GENOME="gs://$REF_DATA_B/grc37" \
  --command 'bismark_nozip \
                -q \
                --bowtie2 \
                ${REF_GENOME} \
                -N 1 \
                -1 ${R1} \
                -2 ${R2} \
                --un \
                --score_min L,0,-0.2 \
                --bam \
                --multicore 3 \
                -o $(dirname ${OUTPUT_DIR})' \
  --tasks align.tsv \
  --wait

########################## Split chard's BAM by chromosome ################################

# Prepare TSV file
echo -e "--input BAM\t--output OUTPUT_DIR" > split_bam.tsv

while read SAMPLE ; do
  gsutil ls gs://$OUTPUT_B/$SAMPLE/aligned_per_chard/*.bam > bam_per_chard_${SAMPLE}.txt
  NB_BAM=$(cat bam_per_chard_${SAMPLE}.txt | wc -l)
  rm -f output_dir_${SAMPLE}.txt && touch output_dir_${SAMPLE}.txt
  for i in `seq 1 $NB_BAM` ; do 
    echo 'gs://'$OUTPUT_B'/'$SAMPLE'/bam_per_chard_and_chr/*' >> output_dir_${SAMPLE}.txt
  done
  paste -d '\t' bam_per_chard_${SAMPLE}.txt output_dir_${SAMPLE}.txt >> split_bam.tsv
done < sample_id.txt

# Submit job
dsub \
  --provider google-v2 \
  --project $PROJECT_ID \
  --disk-size 30 \
  --preemptible \
  --zones $ZONE_ID \
  --image $DOCKER_IMAGE \
  --logging gs://$OUTPUT_B/logging/ \
  --script ${SCRIPTS}/split_bam.sh \
  --tasks split_bam.tsv \
  --wait


########################## Merge all BAMs by chromosome, clean them ################################

# Prepare TSV file
echo -e "--env SAMPLE\t--env CHR\t--input BAM_FILES\t--output OUTPUT_DIR" > merge_bam.tsv

while read SAMPLE ; do
  for CHR in `seq 1 22` X Y ; do 
  echo -e "${SAMPLE}\t${CHR}\tgs://$OUTPUT_B/$SAMPLE/bam_per_chard_and_chr/*chr${CHR}.bam\tgs://$OUTPUT_B/$SAMPLE/bam_per_chr/*" >> merge_bam.tsv
  done
done < sample_id.txt

# Print a message in the terminal
echo "There are" $(cat merge_bam.tsv | wc -l) "to be launched"

# Submit job
dsub \
  --provider google-v2 \
  --project $PROJECT_ID \
  --machine-type n1-highmem-8 \
  --preemptible \
  --disk-size 30 \
  --zones $ZONE_ID \
  --image $DOCKER_IMAGE \
  --logging gs://$OUTPUT_B/logging/ \
  --script ${SCRIPTS}/merge_bam.sh \
  --tasks merge_bam.tsv \
  --wait


########################## Re-calibrate BAM  ################################

# This step is required by the variant call Bis-SNP

# Prepare TSV file
echo -e "--env SAMPLE\t--env CHR\t--input BAM\t--output OUTPUT_DIR" > bam_recalibration.tsv

while read SAMPLE ; do
  for CHR in `seq 1 22` X Y ; do 
  echo -e "$SAMPLE\t$CHR\tgs://$OUTPUT_B/$SAMPLE/bam_per_chr/${SAMPLE}_chr${CHR}.bam\tgs://$OUTPUT_B/$SAMPLE/recal_bam_per_chr/*" >> bam_recalibration.tsv
  done
done < sample_id.txt

# Print a message in the terminal
echo "There are" $(tail -n +2 bam_recalibration.tsv | wc -l) "to be launched"

# Re-calibrate the BAM files.
dsub \
  --provider google-v2 \
  --project $PROJECT_ID \
  --machine-type n1-standard-16 \
  --disk-size 200 \
  --zones $ZONE_ID \
  --image $DOCKER_IMAGE \
  --logging gs://$OUTPUT_B/logging/ \
  --input REF_GENOME="gs://$REF_DATA_B/grc37/*" \
  --input VCF="gs://$REF_DATA_B/dbSNP150_grc37_GATK/no_chr_dbSNP150_GRCh37.vcf" \
  --script ${SCRIPTS}/bam_recalibration.sh \
  --tasks bam_recalibration.tsv \
  --wait


########################## Variant call  ################################

# Before doing the variant call, the SAM file is exported in the bucket

# Prepare TSV file
echo -e "--env SAMPLE\t--env CHR\t--input BAM_BAI\t--output OUTPUT_DIR" > variant_call.tsv

while read SAMPLE ; do
  for CHR in `seq 1 22` X Y ; do 
  echo -e "$SAMPLE\t$CHR\tgs://$OUTPUT_B/${SAMPLE}/recal_bam_per_chr/${SAMPLE}_chr${CHR}_recal.ba*\tgs://$OUTPUT_B/${SAMPLE}/variants_per_chr/*" >> variant_call.tsv
  done
done < sample_id.txt


dsub \
  --provider google-v2 \
  --project $PROJECT_ID \
  --machine-type n1-standard-16 \
  --disk-size 500 \
  --zones $ZONE_ID \
  --image $DOCKER_IMAGE \
  --logging gs://$OUTPUT_B/logging/ \
  --input REF_GENOME="gs://$REF_DATA_B/grc37/*" \
  --input VCF="gs://$REF_DATA_B/dbSNP150_grc37_GATK/no_chr_dbSNP150_GRCh37.vcf" \
  --script ${SCRIPTS}/variant_call.sh \
  --tasks variant_call.tsv \
  --wait


########################## TEMP TO BE DELETED ################################

#### TEMP TO BE DELETED

# dsub \
#   --provider google-v2 \
#   --project $PROJECT_ID \
#   --preemptible \
#   --machine-type n1-standard-4 \
#   --disk-size 500 \
#   --zones $ZONE_ID \
#   --image $DOCKER_IMAGE \
#   --logging gs://$OUTPUT_B/logging/ \
#   --input BAM="gs://$OUTPUT_B/${SAMPLE}/recal_bam_per_chr/${SAMPLE}_chr${CHR}_recal.bam" \
#   --input BAI="gs://$OUTPUT_B/${SAMPLE}/recal_bam_per_chr/${SAMPLE}_chr${CHR}_recal.bai" \
#   --output SAM="gs://$OUTPUT_B/${SAMPLE}/recal_bam_per_chr/${SAMPLE}_chr${CHR}_recal.sam" \
#   --command 'samtools view -o \
#                 ${SAM} \
#                 ${BAM}' \
#   --wait
##############


########################## Export recal bam to Big Query ################################

# The SAM file was created by the variant_call script

# Prepare TSV file
echo -e "--env SAMPLE\t--env SAM" > sam_to_bq.tsv

while read SAMPLE ; do
  for CHR in `seq 1 22` X Y ; do 
    echo -e "$SAMPLE\tgs://$OUTPUT_B/${SAMPLE}/recal_bam_per_chr/${SAMPLE}_chr${CHR}_recal.sam" >> sam_to_bq.tsv
  done
  
  # Delete existing SAM on big query
  bq rm -f -t ${PROJECT_ID}:${DATASET_ID}.${SAMPLE}_recal_sam

done < sample_id.txt

# Launch
dsub \
  --provider google-v2 \
  --project $PROJECT_ID \
  --preemptible \
  --zones $ZONE_ID \
  --image $DOCKER_IMAGE \
  --logging gs://$OUTPUT_B/logging/ \
  --env DATASET_ID="${DATASET_ID}" \
  --command 'bq --location=US load \
               --replace=false \
               --source_format=CSV \
               --field_delimiter "\t" \
               ${DATASET_ID}.${SAMPLE}_recal_sam \
               ${SAM} \
               read_id:STRING,flag:INTEGER,chr:STRING,read_start:INTEGER,mapq:INTEGER,cigar:STRING,rnext:STRING,mate_read_start:INTEGER,length:INTEGER,seq:STRING,score:STRING,bismark:STRING,picard_flag:STRING,read_g:STRING,genome_strand:STRING,NM_tag:STRING,meth:STRING,score_before_recal:STRING,read_strand:STRING' \
  --tasks sam_to_bq.tsv \
  --wait

# Delete the SAM files from the bucket
dsub \
  --provider google-v2 \
  --project $PROJECT_ID \
  --preemptible \
  --zones $ZONE_ID \
  --image $DOCKER_IMAGE \
  --logging gs://$OUTPUT_B/logging/ \
  --command 'gsutil rm ${SAM}' \
  --tasks sam_to_bq.tsv \
  --wait

########################## Generate a list of variants per chr, based on CpG positions in the ref genome ################################

# This step filters out the variants that are not at least within a 500bp window of a CpG
# TO IMPROVE, FILTER OUT THE VARIANTS THAT ARE NOT AT LEAST NEAR A WELL ENOUGH COVERED CPG WITH AT LEAST 20% OF NET METHYLATION

# Prepare TSV file
echo -e "--env SAMPLE\t--env CHR" > variant_window.tsv

while read SAMPLE ; do
  for CHR in `seq 1 22` X Y ; do 
  echo -e "$SAMPLE\t$CHR" >> variant_window.tsv
  done
done < sample_id.txt

# Used for testing (to be deleted)
#echo -e "gm12878\t20\ngm12878\t21\ngm12878\t22" >> variant_window.tsv

# Launch job
dsub \
  --provider google-v2 \
  --project $PROJECT_ID \
  --zones $ZONE_ID \
  --preemptible \
  --image $DOCKER_IMAGE \
  --logging gs://$OUTPUT_B/logging/ \
  --env BUCKET="$OUTPUT_B" \
  --env PROJECT_ID="$PROJECT_ID" \
  --env DATASET_ID="$DATASET_ID" \
  --script ${SCRIPTS}/variant_window.sh \
  --tasks variant_window.tsv \
  --wait


########################## Split the variants in 200 shards ################################

# We use the 500bp window created above to qualify for "near"

# Prepare TSV file
echo -e "--env SAMPLE\t--env CHR\t--input VARIANTS_CHR\t--output OUTPUT_DIR" > variant_list.tsv

while read SAMPLE ; do
  for CHR in `seq 1 22` X Y ; do 
  echo -e "${SAMPLE}\t${CHR}\tgs://${OUTPUT_B}/${SAMPLE}/variants_per_chr/${SAMPLE}_chr${CHR}_variants.txt\tgs://$OUTPUT_B/${SAMPLE}/variant_shards/*" >> variant_list.tsv
  done
done < sample_id.txt

dsub \
  --provider google-v2 \
  --project $PROJECT_ID \
  --zones $ZONE_ID \
  --image $DOCKER_IMAGE \
  --logging gs://$OUTPUT_B/logging/ \
  --command 'split -l 200 \
                --numeric-suffixes --suffix-length=6 \
                --additional-suffix=.txt \
                ${VARIANTS_CHR}\
                $(dirname "${OUTPUT_DIR}")/${SAMPLE}_chr${CHR}_variants_' \
  --tasks variant_list.tsv \
  --wait

########################## Create a pair of (REF, ALT) of each BAM for each combination [SAM, snp shard] ################################

# Need SNP ID, chr, position, window of 2000 centered on SNP.
#100,000 SNP x 54 in chr 1

# SAMPLE="gm12878"
# CHR="22"

# dsub \
#   --provider google-v2 \
#   --project $PROJECT_ID \
#   --zones $ZONE_ID \
#   --machine-type n1-standard-4 \
#   --disk-size 20 \
#   --image $DOCKER_IMAGE \
#   --logging gs://$OUTPUT_B/logging/ \
#   --input BAM_BAI="gs://$OUTPUT_B/${SAMPLE}/recal_bam_per_chr/${SAMPLE}_chr${CHR}_recal.ba*" \
#   --input SNP_LIST="gs://$OUTPUT_B/$SAMPLE/variant_shards/split-1-of-50_${SAMPLE}_chr${CHR}.txt" \
#   --input VCF="gs://$OUTPUT_B/$SAMPLE/variants_per_chr/${SAMPLE}_chr${CHR}.vcf" \
#   --output OUTPUT_FOLDER="gs://$OUTPUT_B/$SAMPLE/genotype/*" \
#   --script ${SCRIPTS}/genotype.sh \
#   --tasks genotype.tsv \
#   --wait

