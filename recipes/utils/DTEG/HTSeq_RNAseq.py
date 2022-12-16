#!/usr/bin/env python

import sys, os

folder,file,mismatch= sys.argv[1], sys.argv[2], sys.argv[3]

GFFfilepath= '/mnt/rnabl-work/Guiblet/CCBRRBL8/index/hg19/CanonicalTranscriptKnownGeneCoding.gtf'

ROOTPATH= '/mnt/rnabl-work/Guiblet/CCBRRBL8/%s/%s' %(folder,file)

outfile= '/mnt/rnabl-work/Guiblet/CCBRRBL8/HTSeq/%s_counts.txt' %(file)

# For bam input
infile= ROOTPATH+'/%s_starM%s/%s_match.bam' %(file,str(mismatch).replace('.',''),file)

CMMD= 'samtools view -h %s | htseq-count --stranded=no -t transcript -i Name -m intersection-strict - %s > %s' %(infile,GFFfilepath,outfile)


print(CMMD)
print(" ")
os.system(CMMD)
