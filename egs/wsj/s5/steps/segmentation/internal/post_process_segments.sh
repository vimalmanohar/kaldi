#! /bin/bash

# Copyright 2015-16  Vimal Manohar
# Apache 2.0.

set -e -o pipefail -u
. path.sh

cmd=run.pl
stage=-10

# General segmentation options
pad_length=50          # Pad speech segments by this many frames on either side
max_blend_length=10  # Maximum duration of speech that will be removed as part
                       # of smoothing process. This is only if there are no other
                       # speech segments nearby.
max_intersegment_length=50  # Merge nearby speech segments if the silence
                            # between them is less than this many frames.
post_pad_length=50        # Pad speech segments by this many frames on either side
                          # after the merging process using max_intersegment_length
max_segment_length=1000   # Segments that are longer than this are split into
                          # overlapping frames.
overlap_length=100        # Overlapping frames when segments are split.
                          # See the above option.
min_silence_length=30     # Min silence length at which to split very long segments

frame_shift=0.01

. utils/parse_options.sh

if [ $# -ne 3 ]; then
  echo "Usage: $0 <data-dir> <segmentation-dir> <segmented-data-dir>"
  echo " e.g.: $0 data/dev_aspire_whole exp/vad_dev_aspire data/dev_aspire_seg"
  exit 1
fi

data_dir=$1
dir=$2
segmented_data_dir=$3

for f in $dir/orig_segmentation.1.gz $data_dir/segments; do
  if [ ! -f $f ]; then
    echo "$0: Could not find $f"
    exit 1
  fi
done

cat <<EOF > $dir/segmentation.conf
pad_length=$pad_length          # Pad speech segments by this many frames on either side
max_blend_length=$max_blend_length  # Maximum duration of speech that will be removed as part
                       # of smoothing process. This is only if there are no other
                       # speech segments nearby.
max_intersegment_length=$max_intersegment_length  # Merge nearby speech segments if the silence
                            # between them is less than this many frames.
post_pad_length=$post_pad_length        # Pad speech segments by this many frames on either side
                          # after the merging process using max_intersegment_length
max_segment_length=$max_segment_length   # Segments that are longer than this are split into
                          # overlapping frames.
overlap_length=$overlap_length        # Overlapping frames when segments are split.
                          # See the above option.
min_silence_length=$min_silence_length     # Min silence length at which to split very long segments

frame_shift=$frame_shift
EOF

nj=`cat $dir/num_jobs` || exit 1

if [ $stage -le 1 ]; then
  rm -r $segmented_data_dir || true
  utils/data/convert_data_dir_to_whole.sh $data_dir $segmented_data_dir || exit 1
  rm $segmented_data_dir/text
fi

if [ $stage -le 2 ]; then
  # Post-process the orignal SAD segmentation using the following steps:
  # 1) blend short speech segments of less than $max_blend_length frames
  # into silence 
  # 2) Remove all silence frames and widen speech segments by padding
  # $pad_length frames
  # 3) Merge adjacent segments that have an intersegment length of less than
  # $max_intersegment_length frames
  # 4) Widen speech segments again after merging 
  # 5) Split segments into segments of $max_segment_length at the point where
  # the original segmentation had silence
  # 6) Split segments into overlapping segments of max length
  # $max_segment_length and overlap $overlap_length
  # 7) Convert segmentation to kaldi segments and utt2spk
  $cmd JOB=1:$nj $dir/log/post_process_segmentation.JOB.log \
    gunzip -c $dir/orig_segmentation.JOB.gz \| \
    segmentation-post-process --merge-adjacent-segments --max-intersegment-length=0 ark:- ark:- \| \
    segmentation-post-process --max-blend-length=$max_blend_length --blend-short-segments-class=1 ark:- ark:- \| \
    segmentation-post-process --remove-labels=0 --pad-label=1 --pad-length=$pad_length ark:- ark:- \| \
    segmentation-post-process --merge-adjacent-segments --max-intersegment-length=$max_intersegment_length ark:- ark:- \| \
    segmentation-post-process --pad-label=1 --pad-length=$post_pad_length ark:- ark:- \| \
    segmentation-split-segments --alignments="ark,s,cs:gunzip -c $dir/orig_segmentation.JOB.gz | segmentation-to-ali ark:- ark:- |" \
    --max-segment-length=$max_segment_length --min-alignment-chunk-length=$min_silence_length --ali-label=0 ark:- ark:- \| \
    segmentation-split-segments \
    --max-segment-length=$max_segment_length --overlap-length=$overlap_length ark:- ark:- \| \
    segmentation-to-segments --frame-shift=$frame_shift ark:- \
    ark,t:$dir/utt2spk.JOB $dir/segments.JOB || exit 1
fi

for n in `seq $nj`; do
  cat $dir/utt2spk.$n
done > $segmented_data_dir/utt2spk

for n in `seq $nj`; do
  cat $dir/segments.$n
done > $segmented_data_dir/segments

if [ ! -s $segmented_data_dir/utt2spk ] || [ ! -s $segmented_data_dir/segments ]; then
  echo "$0: Segmentation failed to generate segments or utt2spk!"
  exit 1
fi

utils/utt2spk_to_spk2utt.pl $segmented_data_dir/utt2spk > $segmented_data_dir/spk2utt || exit 1
utils/fix_data_dir.sh $segmented_data_dir

if [ ! -s $segmented_data_dir/utt2spk ] || [ ! -s $segmented_data_dir/segments ]; then
  echo "$0: Segmentation failed to generate segments or utt2spk!"
  exit 1
fi
