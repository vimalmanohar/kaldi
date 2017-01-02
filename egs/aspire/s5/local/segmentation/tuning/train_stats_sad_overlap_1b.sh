#!/bin/bash

# This is a script to train a time-delay neural network for overlapped speech activity detection 
# using statistic pooling component for long-context information.

set -o pipefail
set -e 
set -u

. cmd.sh

# At this script level we don't support not running on GPU, as it would be painfully slow.
# If you want to run without GPU you'd have to call train_tdnn.sh with --gpu false,
# --num-threads 16 and --minibatch-size 128.

stage=0
train_stage=-10
get_egs_stage=-10
egs_opts=   # Directly passed to get_egs_multiple_targets.py

# TDNN options
relu_dim=256
chunk_width=40  # We use chunk training for training TDNN
extra_left_context=100  # Maximum left context in egs apart from TDNN's left context 
extra_right_context=20  # Maximum right context in egs apart from TDNN's right context 

# We randomly select an extra {left,right} context for each job between
# min_extra_*_context and extra_*_context so that the network can get used
# to different contexts used to compute statistics.
min_extra_left_context=20   
min_extra_right_context=0

# training options
num_epochs=1
initial_effective_lrate=0.0003
final_effective_lrate=0.00003
num_jobs_initial=3
num_jobs_final=8
remove_egs=false
max_param_change=0.2  # Small max-param change for small network
extra_egs_copy_cmd=   # Used if you want to do some weird stuff to egs
                      # such as removing one of the targets

sad_data_dir=data/train_aztec_unsad_whole_corrupted_sp_hires_bp_2400
ovlp_data_dir=data/train_aztec_unsad_seg_ovlp_corrupted_hires_bp

#extra_left_context=79 
#extra_right_context=11

egs_dir=
nj=40
feat_type=raw
config_dir=

dir=
affix=b

. cmd.sh
. ./path.sh
. ./utils/parse_options.sh

num_utts=`cat $sad_data_dir/utt2spk $ovlp_data_dir/utt2spk | wc -l`
num_utts_subset_valid=`perl -e '$n=int($ARGV[0] * 0.005); print ($n > 4000 ? 4000 : $n)' $num_utts`
num_utts_subset_train=`perl -e '$n=int($ARGV[0] * 0.005); print ($n > 4000 ? 4000 : $n)' $num_utts`

if [ -z "$dir" ]; then
  dir=exp/nnet3_stats_sad_ovlp_snr/nnet_tdnn
fi

dir=$dir${affix:+_$affix}

if ! cuda-compiled; then
  cat <<EOF && exit 1 
This script is intended to be used with GPUs but you have not compiled Kaldi with CUDA 
If you want to use GPUs (and have them), go to src/, and configure and make on a machine
where "nvcc" is installed.
EOF
fi
  
mkdir -p $dir

if [ $stage -le 0 ]; then
  utils/combine_data.sh --extra-files "speech_feat.scp deriv_weights.scp" \
    $dir/combined_data_dir $sad_data_dir $ovlp_data_dir
  utils/split_data.sh $ovlp_data_dir 100
  utils/split_data.sh $dir/combined_data_dir 100

  $train_cmd JOB=1:100 $dir/log/compute_post_output-speech.JOB.log \
    extract-column "scp:utils/filter_scp.pl $dir/combined_data_dir/split100/JOB/utt2spk $dir/combined_data_dir/speech_feat.scp |" ark,t:- \| \
    steps/segmentation/quantize_vector.pl \| \
    ali-to-post ark,t:- ark:- \| \
    weight-post ark:- scp:$dir/combined_data_dir/deriv_weights.scp ark:- \| \
    post-to-feats --post-dim=2 ark:- ark:- \| \
    matrix-sum-rows ark:- ark:- \| \
    vector-sum ark:- $dir/post_output-speech.vec.JOB
  eval vector-sum $dir/post_output-speech.vec.{`seq -s, 100`} $dir/post_output-speech.vec
  rm $dir/post_output-speech.vec.*
  
  $train_cmd JOB=1:100 $dir/log/compute_post_output-overlapped_speech.JOB.log \
    ali-to-post "scp:utils/filter_scp.pl $ovlp_data_dir/split100/JOB/utt2spk $ovlp_data_dir/overlapped_speech_labels.scp |" ark:- \| \
    post-to-feats --post-dim=2 ark:- ark:- \| \
    matrix-sum-rows ark:- ark:- \| \
    vector-sum ark:- $dir/post_output-overlapped_speech.vec.JOB
  eval vector-sum $dir/post_output-overlapped_speech.vec.{`seq -s, 100`} $dir/post_output-overlapped_speech.vec
  rm $dir/post_output-overlapped_speech.vec.*
fi

num_frames_sad=`copy-vector --binary=false $dir/post_output-speech.vec - | awk '{print $2+$3}'`
num_frames_ovlp=`copy-vector --binary=false $dir/post_output-overlapped_speech.vec - | awk '{print $2+$3}'`

if [ $stage -le 1 ]; then
  echo "$0: creating neural net configs using the xconfig parser";

  num_snr_bins=`feat-to-dim scp:$sad_data_dir/irm_targets.scp -`

  mkdir -p $dir/configs
  cat <<EOF > $dir/configs/network.xconfig
  input dim=`feat-to-dim scp:$sad_data_dir/feats.scp -` name=input
  output name=output-temp input=Append(-3,-2,-1,0,1,2,3)
  
  relu-renorm-layer name=tdnn1 input=Append(input@-3, input@-2, input@-1, input, input@1, input@2, input@3) dim=256
  stats-layer name=tdnn2_stats config=mean+count(-99:3:9:99)
  relu-renorm-layer name=tdnn2 input=Append(tdnn1@-6, tdnn1, tdnn2_stats) dim=256
  relu-renorm-layer name=tdnn3 input=Append(-9,0,3) dim=256

  relu-renorm-layer name=pre-final-speech dim=256 input=tdnn3
  output-layer name=output-speech include-log-softmax=true dim=2 objective-scale=`perl -e "print ($num_frames_ovlp / $num_frames_sad) ** 0.25"`

  relu-renorm-layer name=pre-final-snr dim=256 input=tdnn3
  output-layer name=output-snr include-log-softmax=false dim=$num_snr_bins objective-type=quadratic objective-scale=`perl -e "print (($num_frames_ovlp / $num_frames_sad) ** 0.25) / $num_snr_bins"`

  relu-renorm-layer name=pre-final-overlapped_speech dim=256 input=tdnn3
  output-layer name=output-overlapped_speech include-log-softmax=true dim=2
EOF
  steps/nnet3/xconfig_to_configs.py --xconfig-file $dir/configs/network.xconfig \
    --config-dir $dir/configs/ \
    --nnet-edits="rename-node old-name=output-speech new-name=output"
  
  cat <<EOF >> $dir/configs/vars
add_lda=false
EOF
fi

samples_per_iter=`perl -e "print int(400000 / $chunk_width)"`

if [ -z "$egs_dir" ]; then
  egs_dir=$dir/egs_multi
  if [ $stage -le 2 ]; then
    if [[ $(hostname -f) == *.clsp.jhu.edu ]] && [ ! -d $dir/egs_speech/storage ]; then
      utils/create_split_dir.pl \
        /export/b{03,04,05,06}/$USER/kaldi-data/egs_speech/aspire-$(date +'%m_%d_%H_%M')/s5/$dir/egs_speech/storage $dir/egs_speech/storage
    fi
    
    . $dir/configs/vars
    
    steps/nnet3/get_egs_multiple_targets.py --cmd="$decode_cmd" \
      $egs_opts \
      --feat.dir="$sad_data_dir" \
      --feat.cmvn-opts="--norm-means=false --norm-vars=false" \
      --frames-per-eg=$chunk_width \
      --left-context=$[model_left_context + extra_left_context] \
      --right-context=$[model_right_context + extra_right_context] \
      --num-utts-subset-train=$num_utts_subset_train \
      --num-utts-subset-valid=$num_utts_subset_valid \
      --samples-per-iter=$samples_per_iter \
      --stage=$get_egs_stage \
      --targets-parameters="--output-name=output-snr --target-type=dense --targets-scp=$sad_data_dir/irm_targets.scp --deriv-weights-scp=$sad_data_dir/deriv_weights_manual_seg.scp" \
      --targets-parameters="--output-name=output-speech --target-type=sparse --dim=2 --targets-scp=$sad_data_dir/speech_feat.scp --deriv-weights-scp=$sad_data_dir/deriv_weights.scp --scp2ark-cmd=\"extract-column --column-index=0 scp:- ark,t:- | steps/segmentation/quantize_vector.pl | ali-to-post ark,t:- ark:- |\" --compress=true" \
      --generate-egs-scp=true \
      --dir=$dir/egs_speech
  fi

  if [ $stage -le 3 ]; then
    if [[ $(hostname -f) == *.clsp.jhu.edu ]] && [ ! -d $dir/egs_ovlp/storage ]; then
      utils/create_split_dir.pl \
        /export/b{03,04,05,06}/$USER/kaldi-data/egs/aspire-$(date +'%m_%d_%H_%M')/s5/$dir/egs_music/storage $dir/egs_music/storage
    fi

    . $dir/configs/vars
    
    steps/nnet3/get_egs_multiple_targets.py --cmd="$decode_cmd" \
      $egs_opts \
      --feat.dir="$ovlp_data_dir" \
      --feat.cmvn-opts="--norm-means=false --norm-vars=false" \
      --frames-per-eg=$chunk_width \
      --left-context=$[model_left_context + extra_left_context] \
      --right-context=$[model_right_context + extra_right_context] \
      --num-utts-subset-train=$num_utts_subset_train \
      --num-utts-subset-valid=$num_utts_subset_valid \
      --samples-per-iter=$samples_per_iter \
      --stage=$get_egs_stage \
      --targets-parameters="--output-name=output-speech --target-type=sparse --dim=2 --targets-scp=$ovlp_data_dir/speech_feat.scp --deriv-weights-scp=$ovlp_data_dir/deriv_weights.scp  --scp2ark-cmd=\"extract-column --column-index=0 scp:- ark,t:- | steps/segmentation/quantize_vector.pl | ali-to-post ark,t:- ark:- |\"" \
      --targets-parameters="--output-name=output-overlapped_speech --target-type=sparse --dim=2 --targets-scp=$ovlp_data_dir/overlapped_speech_labels.scp --deriv-weights-scp=$ovlp_data_dir/deriv_weights_for_overlapped_speech.scp --scp2ark-cmd=\"ali-to-post scp:- ark:- |\"" \
      --generate-egs-scp=true \
      --dir=$dir/egs_ovlp
  fi

  if [ $stage -le 4 ]; then
    # num_chunk_per_minibatch is multiplied by 4 to allow a buffer to use 
    # the same egs with a different num_chunk_per_minibatch
    steps/nnet3/multilingual/get_egs.sh \
      --minibatch-size $[chunk_width * num_chunk_per_minibatch * 4] \
      --samples-per-iter $samples_per_iter \
      2 $dir/egs_speech $dir/egs_ovlp $dir/egs_multi
  fi
fi

if [ $stage -le 5 ]; then
  steps/nnet3/train_raw_rnn.py --stage=$train_stage \
    --feat.cmvn-opts="--norm-means=false --norm-vars=false" \
    --egs.chunk-width=$chunk_width \
    --egs.dir="$egs_dir" --egs.stage=$get_egs_stage \
    --egs.chunk-left-context=$extra_left_context \
    --egs.chunk-right-context=$extra_right_context \
    --egs.use-multitask-egs=true --egs.rename-multitask-outputs=false \
    ${extra_egs_copy_cmd:+--egs.extra-copy-cmd="$extra_egs_copy_cmd"} \
    --trainer.min-chunk-left-context=$min_extra_left_context \
    --trainer.min-chunk-right-context=$min_extra_right_context \
    --trainer.num-epochs=$num_epochs \
    --trainer.samples-per-iter=20000 \
    --trainer.optimization.num-jobs-initial=$num_jobs_initial \
    --trainer.optimization.num-jobs-final=$num_jobs_final \
    --trainer.optimization.initial-effective-lrate=$initial_effective_lrate \
    --trainer.optimization.final-effective-lrate=$final_effective_lrate \
    --trainer.optimization.shrink-value=1.0 \
    --trainer.rnn.num-chunk-per-minibatch=$num_chunk_per_minibatch \
    --trainer.deriv-truncate-margin=8 \
    --trainer.max-param-change=$max_param_change \
    --cmd="$decode_cmd" --nj 40 \
    --cleanup=true \
    --cleanup.remove-egs=$remove_egs \
    --cleanup.preserve-model-interval=10 \
    --use-gpu=true \
    --use-dense-targets=false \
    --feat-dir=$sad_data_dir \
    --targets-scp="$speech_feat_scp" \
    --dir=$dir || exit 1
fi
