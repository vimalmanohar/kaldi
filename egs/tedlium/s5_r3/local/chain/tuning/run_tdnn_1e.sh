#!/bin/bash

# run_tdnn_1b.sh is the script which results are presented in the corpus release paper.
# It uses 2 to 6 jobs and add proportional-shrink 10.

# WARNING
# This script is flawed and misses key elements to optimize the tdnnf setup.
# You can run it as is to reproduce results from the corpus release paper,
# but a more up-to-date version should be looked at in other egs until another
# setup is added here.

# local/chain/compare_wer_general.sh exp/chain_cleaned/tdnn_1a exp/chain_cleaned/tdnn_1b
# System                      tdnn_1a   tdnn_1b   tdnn_1b
# Scoring script	            sclite    sclite   score_basic
# WER on dev(orig)              8.2       7.9         7.9
# WER on dev(rescored ngram)    7.6       7.4         7.5
# WER on dev(rescored rnnlm)    6.3       6.2         6.2
# WER on test(orig)             8.1       8.0         8.2
# WER on test(rescored ngram)   7.7       7.7         7.9
# WER on test(rescored rnnlm)   6.7       6.7         6.8
# Final train prob            -0.0802   -0.0899
# Final valid prob            -0.0980   -0.0974
# Final train prob (xent)     -1.1450   -0.9449
# Final valid prob (xent)     -1.2498   -1.0002
# Num-params                  26651840  25782720

# local/chain/compare_wer_general.sh exp/chain_cleaned/tdnn_1c_sp_bi
# System                tdnn_1c1_sp_bi    tdnn_1c2_sp_bi  tdnn_1c2_sp_bi
# Scoring script        score_basic       score_basic        sclite
# WER on dev(orig)           8.18            8.01             8.0
# WER on dev(rescored)       7.59            7.41             7.3
# WER on test(orig)          8.39            8.10             8.1
# WER on test(rescored)      7.83            7.72             7.7
# Final train prob        -0.0625         -0.0546         -0.0546
# Final valid prob        -0.0740         -0.0692         -0.0692
# Final train prob (xent)   -0.9813         -0.8466         -0.8466
# Final valid prob (xent)   -0.9876         -0.8701         -0.8701
# Num-params                 9468080        17488560        17488560


## how you run this (note: this assumes that the run_tdnn.sh soft link points here;
## otherwise call it directly in its location).
# by default, with cleanup:
# local/chain/run_tdnn.sh

# without cleanup:
# local/chain/run_tdnn.sh  --train-set train --gmm tri3 --nnet3-affix "" &

# note, if you have already run the corresponding non-chain nnet3 system
# (local/nnet3/run_tdnn.sh), you may want to run with --stage 14.


set -e -o pipefail

# First the options that are passed through to run_ivector_common.sh
# (some of which are also used in this script directly).
stage=0
nj=30
decode_nj=30
xent_regularize=0.1
dropout_schedule='0,0@0.20,0.5@0.50,0'

train_set=train_cleaned
gmm=tri3_cleaned  # the gmm for the target data
num_threads_ubm=32
nnet3_affix=_cleaned  # cleanup affix for nnet3 and chain dirs, e.g. _cleaned

# The rest are configs specific to this script.  Most of the parameters
# are just hardcoded at this level, in the commands below.
train_stage=-10
tree_affix=  # affix for tree directory, e.g. "a" or "b", in case we change the configuration.
tdnn_affix=_1e  #affix for TDNNF directory, e.g. "a" or "b", in case we change the configuration.
common_egs_dir=  # you can set this to use previously dumped egs.
remove_egs=true

# End configuration section.
echo "$0 $@"  # Print the command line for logging

. ./cmd.sh
. ./path.sh
. ./utils/parse_options.sh


if ! cuda-compiled; then
  cat <<EOF && exit 1
This script is intended to be used with GPUs but you have not compiled Kaldi with CUDA
If you want to use GPUs (and have them), go to src/, and configure and make on a machine
where "nvcc" is installed.
EOF
fi


local/nnet3/run_ivector_common.sh --stage $stage \
                                  --nj $nj \
                                  --train-set $train_set \
                                  --gmm $gmm \
                                  --num-threads-ubm $num_threads_ubm \
                                  --nnet3-affix "$nnet3_affix"


gmm_dir=exp/$gmm
ali_dir=exp/${gmm}_ali_${train_set}_sp
tree_dir=exp/chain${nnet3_affix}/tree${tree_affix}
lat_dir=exp/chain${nnet3_affix}/${gmm}_${train_set}_sp_lats
dir=exp/chain${nnet3_affix}/tdnn${tdnn_affix}_sp_bi
train_data_dir=data/${train_set}_sp_hires
lores_train_data_dir=data/${train_set}_sp
train_ivector_dir=exp/nnet3${nnet3_affix}/ivectors_${train_set}_sp_hires


for f in $gmm_dir/final.mdl $train_data_dir/feats.scp $train_ivector_dir/ivector_online.scp \
    $lores_train_data_dir/feats.scp $ali_dir/ali.1.gz $gmm_dir/final.mdl; do
  [ ! -f $f ] && echo "$0: expected file $f to exist" && exit 1
done

if [ $stage -le 14 ]; then
  echo "$0: creating lang directory with one state per phone."
  # Create a version of the lang/ directory that has one state per phone in the
  # topo file. [note, it really has two states.. the first one is only repeated
  # once, the second one has zero or more repeats.]
  if [ -d data/lang_chain ]; then
    if [ data/lang_chain/L.fst -nt data/lang/L.fst ]; then
      echo "$0: data/lang_chain already exists, not overwriting it; continuing"
    else
      echo "$0: data/lang_chain already exists and seems to be older than data/lang..."
      echo " ... not sure what to do.  Exiting."
      exit 1;
    fi
  else
    cp -r data/lang data/lang_chain
    silphonelist=$(cat data/lang_chain/phones/silence.csl) || exit 1;
    nonsilphonelist=$(cat data/lang_chain/phones/nonsilence.csl) || exit 1;
    # Use our special topology... note that later on may have to tune this
    # topology.
    steps/nnet3/chain/gen_topo.py $nonsilphonelist $silphonelist >data/lang_chain/topo
  fi
fi

if [ $stage -le 15 ]; then
  # Get the alignments as lattices (gives the chain training more freedom).
  # use the same num-jobs as the alignments
  steps/align_fmllr_lats.sh --nj 100 --cmd "$train_cmd" ${lores_train_data_dir} \
    data/lang $gmm_dir $lat_dir
  rm $lat_dir/fsts.*.gz # save space
fi

if [ $stage -le 16 ]; then
  # Build a tree using our new topology.  We know we have alignments for the
  # speed-perturbed data (local/nnet3/run_ivector_common.sh made them), so use
  # those.
  if [ -f $tree_dir/final.mdl ]; then
    echo "$0: $tree_dir/final.mdl already exists, refusing to overwrite it."
    exit 1;
  fi
  steps/nnet3/chain/build_tree.sh --frame-subsampling-factor 3 \
      --context-opts "--context-width=2 --central-position=1" \
      --cmd "$train_cmd" 4000 ${lores_train_data_dir} data/lang_chain $ali_dir $tree_dir
fi

if [ $stage -le 17 ]; then
  mkdir -p $dir

  echo "$0: creating neural net configs using the xconfig parser";

  num_targets=$(tree-info $tree_dir/tree |grep num-pdfs|awk '{print $2}')
  learning_rate_factor=$(echo "print (0.5/$xent_regularize)" | python)
  affine_opts="l2-regularize=0.008 dropout-proportion=0.0 dropout-per-dim-continuous=true"
  tdnnf_opts="l2-regularize=0.008 dropout-proportion=0.0 bypass-scale=0.66"
  linear_opts="l2-regularize=0.008 orthonormal-constraint=-1.0"
  prefinal_opts="l2-regularize=0.008"
  output_opts="l2-regularize=0.002"

  mkdir -p $dir/configs
  cat <<EOF > $dir/configs/network.xconfig
  input dim=100 name=ivector
  input dim=40 name=input

  # please note that it is important to have input layer with the name=input
  # as the layer immediately preceding the fixed-affine-layer to enable
  # the use of short notation for the descriptor
  fixed-affine-layer name=lda input=Append(-1,0,1,ReplaceIndex(ivector, t, 0)) affine-transform-file=$dir/configs/lda.mat

  # the first splicing is moved before the lda layer, so no splicing here
  relu-batchnorm-dropout-layer name=tdnn1 $affine_opts dim=1536
  tdnnf-layer name=tdnnf2 $tdnnf_opts dim=1536 bottleneck-dim=160 time-stride=1
  tdnnf-layer name=tdnnf3 $tdnnf_opts dim=1536 bottleneck-dim=160 time-stride=1
  tdnnf-layer name=tdnnf4 $tdnnf_opts dim=1536 bottleneck-dim=160 time-stride=1
  tdnnf-layer name=tdnnf5 $tdnnf_opts dim=1536 bottleneck-dim=160 time-stride=0
  tdnnf-layer name=tdnnf6 $tdnnf_opts dim=1536 bottleneck-dim=160 time-stride=3
  tdnnf-layer name=tdnnf7 $tdnnf_opts dim=1536 bottleneck-dim=160 time-stride=3
  tdnnf-layer name=tdnnf8 $tdnnf_opts dim=1536 bottleneck-dim=160 time-stride=3
  tdnnf-layer name=tdnnf9 $tdnnf_opts dim=1536 bottleneck-dim=160 time-stride=3
  tdnnf-layer name=tdnnf10 $tdnnf_opts dim=1536 bottleneck-dim=160 time-stride=3
  tdnnf-layer name=tdnnf11 $tdnnf_opts dim=1536 bottleneck-dim=160 time-stride=3
  tdnnf-layer name=tdnnf12 $tdnnf_opts dim=1536 bottleneck-dim=160 time-stride=3
  tdnnf-layer name=tdnnf13 $tdnnf_opts dim=1536 bottleneck-dim=160 time-stride=3
  tdnnf-layer name=tdnnf14 $tdnnf_opts dim=1536 bottleneck-dim=160 time-stride=3
  tdnnf-layer name=tdnnf15 $tdnnf_opts dim=1536 bottleneck-dim=160 time-stride=3
  linear-component name=prefinal-l dim=256 $linear_opts

  prefinal-layer name=prefinal-chain input=prefinal-l $prefinal_opts big-dim=1536 small-dim=256
  output-layer name=output include-log-softmax=false dim=$num_targets $output_opts
  output name=output-ensemble-1-2-0 input=output.affine
  output-layer name=output-ensemble-1-2-1 include-log-softmax=false dim=$num_targets $output_opts input=prefinal-chain

  prefinal-layer name=prefinal-xent input=prefinal-l $prefinal_opts big-dim=1536 small-dim=256
  output-layer name=output-xent dim=$num_targets learning-rate-factor=$learning_rate_factor $output_opts
  output name=output-ensemble-1-2-0-xent input=output-xent.log-softmax
  output-layer name=output-ensemble-1-2-1-xent include-log-softmax=false dim=$num_targets $output_opts input=prefinal-xent
EOF
  steps/nnet3/xconfig_to_configs.py --xconfig-file $dir/configs/network.xconfig --config-dir $dir/configs/

fi

if [ $stage -le 18 ]; then
  if [[ $(hostname -f) == *.clsp.jhu.edu ]] && [ ! -d $dir/egs/storage ]; then
    utils/create_split_dir.pl \
     /export/b0{5,6,7,8}/$USER/kaldi-data/egs/ami-$(date +'%m_%d_%H_%M')/s5/$dir/egs/storage $dir/egs/storage
  fi

 steps/nnet3/chain/train.py --stage $train_stage \
    --cmd "$decode_cmd" \
    --feat.online-ivector-dir $train_ivector_dir \
    --feat.cmvn-opts "--norm-means=false --norm-vars=false" \
    --chain.xent-regularize $xent_regularize \
    --chain.leaky-hmm-coefficient 0.1 \
    --chain.l2-regularize 0.0 \
    --chain.apply-deriv-weights false \
    --chain.lm-opts="--num-extra-lm-states=2000" \
    --chain.egs-copy-opts="--output=output-ensemble-1-2-0" \
    --chain.ensemble-weight-floor-schedule="0.1,0.1" \
    --trainer.dropout-schedule $dropout_schedule \
    --trainer.add-option="--optimization.memory-compression-level=2" \
    --egs.dir "$common_egs_dir" \
    --egs.opts "--frames-overlap-per-eg 0 --constrained false" \
    --egs.chunk-width 150,110,100 \
    --trainer.num-chunk-per-minibatch 64 \
    --trainer.frames-per-iter 5000000 \
    --trainer.num-epochs 6 \
    --trainer.optimization.num-jobs-initial 3 \
    --trainer.optimization.num-jobs-final 12 \
    --trainer.optimization.initial-effective-lrate 0.00025 \
    --trainer.optimization.final-effective-lrate 0.000025 \
    --trainer.max-param-change 2.0 \
    --cleanup.remove-egs $remove_egs \
    --feat-dir $train_data_dir \
    --tree-dir $tree_dir \
    --lat-dir $lat_dir \
    --dir $dir
fi

if [ $stage -le 19 ]; then
  # Note: it might appear that this data/lang_chain directory is mismatched, and it is as
  # far as the 'topo' is concerned, but this script doesn't read the 'topo' from
  # the lang directory.
  utils/mkgraph.sh --self-loop-scale 1.0 data/lang $dir $dir/graph
fi

if [ $stage -le 20 ]; then
  rm $dir/.error 2>/dev/null || true
  for dset in dev test; do
    for id in 0 1; do
      (
      nnet3-am-copy \
        --edits="remove-output-nodes name=output;rename-node old-name=output-ensemble-1-2-$id new-name=output" \
        $dir/final.mdl $dir/final-output-ensemble-1-2-$id.mdl

      steps/nnet3/decode.sh --num-threads 4 --nj $decode_nj --cmd "$decode_cmd" \
          --acwt 1.0 --post-decode-acwt 10.0 \
          --online-ivector-dir exp/nnet3${nnet3_affix}/ivectors_${dset}_hires \
          --scoring-opts "--min-lmwt 5 " --iter final-output-ensemble-1-2-$id \
         $dir/graph data/${dset}_hires $dir/decode_${dset}_id$id || exit 1;
      ) || touch $dir/.error &
    done
    wait
    
    if [ -f $dir/.error ]; then
      echo "$0: something went wrong in decoding"
      exit 1
    fi

    steps/decode_combine.sh --cmd "$decode_cmd" \
      data/${dset}_hires $dir/graph $dir/decode_${dset}{_id0,_id1,} || exit 1

    for id in 0 1; do
      (
        steps/lmrescore_const_arpa.sh --cmd "$decode_cmd" data/lang data/lang_rescore \
          data/${dset}_hires ${dir}/decode_${dset}_id$id ${dir}/decode_${dset}_id${id}_rescore || exit 1
      ) || touch $dir/.error &
    done
    wait

    if [ -f $dir/.error ]; then
      echo "$0: something went wrong in decoding"
      exit 1
    fi

    steps/decode_combine.sh --cmd "$decode_cmd" \
      data/${dset}_hires $dir/graph $dir/decode_${dset}{_id0,_id1,}_rescore || exit 1
  done
fi
exit 0
