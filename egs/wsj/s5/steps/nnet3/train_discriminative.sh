#!/bin/bash

# Copyright 2012-2014  Johns Hopkins University (Author: Daniel Povey)
#           2014-2015  Vimal Manohar
# Apache 2.0.

set -e
set -u
set -o pipefail

# This script does MPE or MMI or state-level minimum bayes risk (sMBR) training
# using egs obtained by steps/nnet3/get_egs_discriminative.sh

# Begin configuration section.
cmd=run.pl
num_epochs=4       # Number of epochs of training
use_gpu=true
truncate_deriv_weights=0  # can be used to set to zero the weights of derivs from frames
                          # near the edges.  (counts subsampled frames).
apply_deriv_weights=true
run_diagnostics=true
learning_rate=0.00002
effective_lrate=    # If supplied, overrides the learning rate, which gets set to effective_lrate * num_jobs_nnet.
acoustic_scale=0.1  # acoustic scale for MMI/MPFE/SMBR training.
boost=0.0       # option relevant for MMI

criterion=smbr
drop_frames=false #  option relevant for MMI
one_silence_class=true # option relevant for MPE/SMBR
num_jobs_nnet=4    # Number of neural net jobs to run in parallel.  Note: this
                   # will interact with the learning rates (if you decrease
                   # this, you'll have to decrease the learning rate, and vice
                   # versa).

minibatch_size=64  # This is the number of examples rather than the number of output frames.
modify_learning_rates=true
last_layer_factor=1.0  # relates to modify-learning-rates
first_layer_factor=1.0 # relates to modify-learning-rates
shuffle_buffer_size=5000 # This "buffer_size" variable controls randomization of the samples
                # on each iter.  You could set it to 0 or to a large value for complete
                # randomization, but this would both consume memory and cause spikes in
                # disk I/O.  Smaller is easier on disk and memory but less random.  It's
                # not a huge deal though, as samples are anyway randomized right at the start.


stage=-3

adjust_priors=false
num_threads=16  # this is the default but you may want to change it, e.g. to 1 if
                # using GPUs.

cleanup=true
retroactive=false
remove_egs=false
src_model=  # will default to $degs_dir/final.mdl

left_deriv_truncate=   # number of time-steps to avoid using the deriv of, on the left.
right_deriv_truncate=  # number of time-steps to avoid using the deriv of, on the right.
# End configuration section.


echo "$0 $@"  # Print the command line for logging

if [ -f path.sh ]; then . ./path.sh; fi
. parse_options.sh || exit 1;


if [ $# != 2 ]; then
  echo "Usage: $0 [opts] <degs-dir> <exp-dir>"
  echo " e.g.: $0 exp/tri4_mpe_degs exp/tri4_mpe"
  echo ""
  echo "You have to first call get_egs_discriminative2.sh to dump the egs."
  echo "Caution: the options 'drop-frames' and 'criterion' are taken here"
  echo "even though they were required also by get_egs_discriminative2.sh,"
  echo "and they should normally match."
  echo ""
  echo "Main options (for others, see top of script file)"
  echo "  --config <config-file>                           # config file containing options"
  echo "  --cmd (utils/run.pl|utils/queue.pl <queue opts>) # how to run jobs."
  echo "  --num-epochs <#epochs|4>                        # Number of epochs of training"
  echo "  --learning-rate <learning-rate|0.0002>           # Learning rate to use"
  echo "  --effective-lrate <effective-learning-rate>      # If supplied, learning rate will be set to"
  echo "                                                   # this value times num-jobs-nnet."
  echo "  --num-jobs-nnet <num-jobs|8>                     # Number of parallel jobs to use for main neural net"
  echo "                                                   # training (will affect results as well as speed; try 8, 16)"
  echo "                                                   # Note: if you increase this, you may want to also increase"
  echo "                                                   # the learning rate.  Also note: if there are fewer archives"
  echo "                                                   # of egs than this, it will get reduced automatically."
  echo "  --num-threads <num-threads|16>                   # Number of parallel threads per job (will affect results"
  echo "                                                   # as well as speed; may interact with batch size; if you increase"
  echo "                                                   # this, you may want to decrease the batch size.  With GPU, must be 1."
  echo "  --parallel-opts <opts|\"--num-threads 16 --mem 1G\">      # extra options to pass to e.g. queue.pl for processes that"
  echo "                                                   # use multiple threads... "
  echo "  --stage <stage|-3>                               # Used to run a partially-completed training process from somewhere in"
  echo "                                                   # the middle."
  echo "  --criterion <criterion|smbr>                     # Training criterion: may be smbr, mmi or mpfe"
  echo "  --boost <boost|0.0>                              # Boosting factor for MMI (e.g., 0.1)"
  echo "  --drop-frames <true,false|false>                 # Option that affects MMI training: if true, we exclude gradients from frames"
  echo "                                                   # where the numerator transition-id is not in the denominator lattice."
  echo "  --one-silence-class <true,false|false>           # Option that affects MPE/SMBR training (will tend to reduce insertions)"
  echo "  --modify-learning-rates <true,false|false>       # If true, modify learning rates to try to equalize relative"
  echo "                                                   # changes across layers."
  exit 1;
fi

degs_dir=$1
dir=$2

[ -z "$src_model" ] && src_model=$degs_dir/final.mdl

# Check some files.
for f in $degs_dir/degs.1.ark $degs_dir/info/{num_archives,silence.csl,frames_per_eg,egs_per_archive} $src_model; do
  [ ! -f $f ] && echo "$0: no such file $f" && exit 1;
done

mkdir -p $dir/log || exit 1;

# copy some things
for f in splice_opts cmvn_opts tree final.mat; do
  if [ -f $degs_dir/$f ]; then
    cp $degs_dir/$f $dir/ || exit 1;
  fi
done

silphonelist=`cat $degs_dir/info/silence.csl` || exit 1;

frames_per_eg=$(cat $degs_dir/info/frames_per_eg) || { echo "error: no such file $degs_dir/info/frames_per_eg"; exit 1; }
num_archives=$(cat $degs_dir/info/num_archives) || exit 1;

if [ $num_jobs_nnet -gt $num_archives ]; then
  echo "$0: num-jobs-nnet $num_jobs_nnet exceeds number of archives $num_archives,"
  echo " ... setting it to $num_archives."
  num_jobs_nnet=$num_archives
fi

num_iters=$[($num_epochs*$num_archives)/$num_jobs_nnet]

echo "$0: Will train for $num_epochs epochs = $num_iters iterations"

if $use_gpu; then
  parallel_suffix=""
  train_queue_opt="--gpu 1"
  prior_gpu_opt="--use-gpu=yes"
  prior_queue_opt="--gpu 1"
  parallel_train_opts=
  if ! cuda-compiled; then
    echo "$0: WARNING: you are running with one thread but you have not compiled"
    echo "   for CUDA.  You may be running a setup optimized for GPUs.  If you have"
    echo "   GPUs and have nvcc installed, go to src/ and do ./configure; make"
    exit 1
  fi
else
  echo "$0: without using a GPU this will be very slow.  nnet3 does not yet support multiple threads."
  parallel_train_opts="--use-gpu=no"
  prior_gpu_opt="--use-gpu=no"
  prior_queue_opt=""
fi

for e in $(seq 1 $num_epochs); do
  x=$[($e*$num_archives)/$num_jobs_nnet] # gives the iteration number.
  iter_to_epoch[$x]=$e
done

if [ $stage -le -1 ]; then
  echo "$0: Copying initial model and modifying preconditioning setup"

  # Note, the baseline model probably had preconditioning, and we'll keep it;
  # but we want online preconditioning with a larger number of samples of
  # history, since in this setup the frames are only randomized at the segment
  # level so they are highly correlated.  It might make sense to tune this a
  # little, later on, although I doubt it matters once the --num-samples-history
  # is large enough.

  if [ ! -z "$effective_lrate" ]; then
    learning_rate=$(perl -e "print ($num_jobs_nnet*$effective_lrate);")
    echo "$0: setting learning rate to $learning_rate = --num-jobs-nnet * --effective-lrate."
  fi

  $cmd $dir/log/convert.log \
    nnet3-am-copy --learning-rate=$learning_rate "$src_model" $dir/0.mdl || exit 1;
fi


rm -f $dir/.error 2>/dev/null || true 

x=0   

deriv_time_opts=
[ ! -z "$left_deriv_truncate" ] && deriv_time_opts="--optimization.min-deriv-time=$left_deriv_truncate"
[ ! -z "$right_deriv_truncate" ] && \
  deriv_time_opts="$deriv_time_opts --optimization.max-deriv-time=$((frames_per_eg - right_deriv_truncate))"

while [ $x -lt $num_iters ]; do
  if [ $stage -le $x ]; then
    
    if $run_diagnostics; then
      # Set off jobs doing some diagnostics, in the background.  # Use the egs dir from the previous iteration for the diagnostics
      $cmd $dir/log/compute_objf_valid.$x.log \
        nnet3-discriminative-compute-objf \
        --silence-phones=$silphonelist \
        --criterion=$criterion --drop-frames=$drop_frames \
        --one-silence-class=$one_silence_class \
        --boost=$boost --acoustic-scale=$acoustic_scale \
        $dir/$x.mdl \
        "ark:nnet3-discriminative-merge-egs --minibatch-size=$minibatch_size ark:$degs_dir/valid_diagnostic.degs ark:- |" &
      $cmd $dir/log/compute_objf_train.$x.log \
        nnet3-discriminative-compute-objf \
        --silence-phones=$silphonelist \
        --criterion=$criterion --drop-frames=$drop_frames \
        --one-silence-class=$one_silence_class \
        --boost=$boost --acoustic-scale=$acoustic_scale \
        $dir/$x.mdl \
        "ark:nnet3-discriminative-merge-egs --minibatch-size=$minibatch_size ark:$degs_dir/train_diagnostic.degs ark:- |" &
    fi
    
    if [ $x -gt 0 ]; then
      $cmd $dir/log/progress.$x.log \
        nnet3-show-progress --use-gpu=no "nnet3-am-copy --raw=true $dir/$[$x-1].mdl - |" "nnet3-am-copy --raw=true $dir/$x.mdl - |" \
        '&&' \
        nnet3-info "nnet3-am-copy --raw=true $dir/$x.mdl - |" &
    fi


    echo "Training neural net (pass $x)"
    
    ( # this sub-shell is so that when we "wait" below,
      # we only wait for the training jobs that we just spawned,
      # not the diagnostic jobs that we spawned above.

      # We can't easily use a single parallel SGE job to do the main training,
      # because the computation of which archive and which --frame option
      # to use for each job is a little complex, so we spawn each one separately.
      for n in `seq $num_jobs_nnet`; do
        archive=$[(($n+($x*$num_jobs_nnet))%$num_archives)+1]

        $cmd $train_queue_opt $dir/log/train.$x.$n.log \
          nnet3-discriminative-train --verbose=3 --apply-deriv-weights=$apply_deriv_weights \
          $parallel_train_opts $deriv_time_opts \
          --silence-phones=$silphonelist \
          --criterion=$criterion --drop-frames=$drop_frames \
          --one-silence-class=$one_silence_class \
          --boost=$boost --acoustic-scale=$acoustic_scale \
          $dir/$x.mdl \
          "ark:nnet3-discriminative-copy-egs --truncate-deriv-weights=$truncate_deriv_weights ark:$degs_dir/degs.$archive.ark ark:- | nnet3-discriminative-shuffle-egs --buffer-size=$shuffle_buffer_size --srand=$x ark:- ark:- | nnet3-discriminative-merge-egs --minibatch-size=$minibatch_size ark:- ark:- |" \
          $dir/$[$x+1].$n.raw || touch $dir/.error &
      done
      wait
    )

    nnets_list=$(for n in $(seq $num_jobs_nnet); do echo $dir/$[$x+1].$n.raw; done)

    # below use run.pl instead of a generic $cmd for these very quick stages,
    # so that we don't run the risk of waiting for a possibly hard-to-get GPU.
    run.pl $dir/log/average.$x.log \
      nnet3-average $nnets_list - \| \
      nnet3-am-copy --set-raw-nnet=- $dir/$x.mdl $dir/$[$x+1].mdl || exit 1;

    #if $modify_learning_rates; then
    #  run.pl $dir/log/modify_learning_rates.$x.log \
    #    nnet-modify-learning-rates --retroactive=$retroactive \
    #    --last-layer-factor=$last_layer_factor \
    #    --first-layer-factor=$first_layer_factor \
    #    $dir/$x.mdl $dir/$[$x+1].mdl $dir/$[$x+1].mdl || exit 1;
    #fi
    rm $nnets_list
  fi
  if $adjust_priors && [ ! -z "${iter_to_epoch[$x]}" ]; then
    if [ ! -f $degs_dir/priors_egs.1.ark ]; then
      echo "$0: Expecting $degs_dir/priors_egs.1.ark to exist since --adjust-priors was true."
      echo "$0: Run this script with --adjust-priors false to not adjust priors"
      exit 1
    fi
    (
    e=${iter_to_epoch[$x]}
    rm -f $dir/.error 2> /dev/null || true
    num_archives_priors=`cat $degs_dir/info/num_archives_priors` || { touch $dir/.error; echo "Could not find $degs_dir/info/num_archives_priors. Set --adjust-priors false to not adjust priors"; exit 1; }

    $cmd JOB=1:$num_archives_priors $prior_queue_opt $dir/log/get_post.epoch$e.JOB.log \
      nnet3-compute-from-egs $prior_gpu_opt --apply-exp=true \
      "nnet3-am-copy --raw=true $dir/$x.mdl -|" \
      ark:$degs_dir/priors_egs.JOB.ark ark:- \| \
      matrix-sum-rows ark:- ark:- \| \
      vector-sum ark:- $dir/post.epoch$e.JOB.vec || \
      { touch $dir/.error; echo "Error in getting posteriors for adjusting priors. See $dir/log/get_post.epoch$e.*.log"; exit 1; }

    sleep 3;

    $cmd $dir/log/sum_post.epoch$e.log \
      vector-sum $dir/post.epoch$e.*.vec $dir/post.epoch$e.vec || \
      { touch $dir/.error; echo "Error in summing posteriors. See $dir/log/sum_post.epoch$e.log"; exit 1; }

    rm $dir/post.epoch$e.*.vec

    echo "Re-adjusting priors based on computed posteriors for iter $x"
    $cmd $dir/log/adjust_priors.epoch$e.log \
      nnet3-adjust-priors $dir/$x.mdl $dir/post.epoch$e.vec $dir/$x.mdl \
      || { touch $dir/.error; echo "Error in adjusting priors. See $dir/log/adjust_priors.epoch$e.log"; exit 1; }
    ) &
  fi

  [ -f $dir/.error ] && exit 1

  x=$[$x+1]
done

rm -f $dir/final.mdl 2>/dev/null || true
cp $dir/$x.mdl $dir/final.mdl

echo Done

epoch_final_iters=
for e in $(seq 0 $num_epochs); do
  x=$[($e*$num_archives)/$num_jobs_nnet] # gives the iteration number.
  ln -sf $x.mdl $dir/epoch$e.mdl
  epoch_final_iters="$epoch_final_iters $x"
done


# function to remove egs that might be soft links.
remove () { for x in $*; do [ -L $x ] && rm $(readlink -f $x); rm $x; done }

if $cleanup && $remove_egs; then  # note: this is false by default.
  echo Removing training examples
  for n in $(seq $num_archives); do
    remove $degs_dir/degs.*
    remove $degs_dir/priors_egs.*
  done
fi


if $cleanup; then
  echo Removing most of the models
  for x in `seq 0 $num_iters`; do
    if ! echo $epoch_final_iters | grep -w $x >/dev/null; then 
      # if $x is not an epoch-final iteration..
      rm $dir/$x.mdl 2>/dev/null
    fi
  done
fi
