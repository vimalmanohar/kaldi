#!/bin/bash

. path.sh

cmd=run.pl
prior_subset_size=20000 # 20k samples per job, for computing priors.
num_jobs_compute_prior=10 # these are single-threaded, run on CPU.
use_gpu=false             # if true, we run on GPU.
egs_type=egs
raw=false
iter=final

. utils/parse_options.sh

echo "$0 $@"  # Print the command line for logging

if [ $# -ne 2 ]; then
  echo "Usage: $0 [opts] <exp-dir> <egs-dir>"
  echo " e.g.: $0 exp/nnet3_sad_snr/tdnn_train_100k_whole_1k_splice2_2_relu500"
  exit 1
fi

dir=$1
egs_dir=$2

if $use_gpu; then
  prior_gpu_opt="--use-gpu=yes"
  prior_queue_opt="--gpu 1"
else
  prior_gpu_opt="--use-gpu=no"
  prior_queue_opt=""
fi

for f in $egs_dir/$egs_type.1.ark $egs_dir/info/num_archives; do 
  if [ ! -f $f ]; then
    echo "$f not found" 
    exit 1 
  fi
done

if $raw; then
  model=$dir/$iter.raw
else 
  model="nnet3-am-copy --raw=true $dir/$iter.mdl - |"
fi

rm -f $dir/post.$iter.*.vec 2>/dev/null

left_context=`cat $egs_dir/info/left_context` || exit 1
right_context=`cat $egs_dir/info/right_context` || exit 1

context_opts="--left-context=$left_context --right-context=$right_context"

num_archives=$(cat $egs_dir/info/num_archives) || { echo "error: no such file $egs_dir/info/frames_per_eg"; exit 1; }
if [ $num_jobs_compute_prior -gt $num_archives ]; then egs_part=1;
else egs_part=JOB; fi

$cmd JOB=1:$num_jobs_compute_prior $prior_queue_opt $dir/log/get_post.$iter.JOB.log \
  nnet3-copy-egs ark:$egs_dir/$egs_type.$egs_part.ark ark:- \| \
  nnet3-subset-egs --srand=JOB --n=$prior_subset_size ark:- ark:- \| \
  nnet3-merge-egs ark:- ark:- \| \
  nnet3-compute-from-egs $prior_gpu_opt --apply-exp=true \
  "$model" ark:- ark:- \| \
  matrix-sum-rows ark:- ark:- \| vector-sum ark:- $dir/post.$iter.JOB.vec || exit 1;

sleep 3;  # make sure there is time for $dir/post.$iter.*.vec to appear.

$cmd $dir/log/vector_sum.$iter.log \
  vector-sum $dir/post.$iter.*.vec $dir/post.$iter.vec || exit 1;

if ! $raw; then
  $cmd $dir/log/adjust_priors.$iter.log \
    nnet3-am-adjust-priors $dir/$iter.mdl $dir/post.$iter.vec $dir/$iter.adjust.mdl
fi

rm -f $dir/post.$iter.*.vec;
