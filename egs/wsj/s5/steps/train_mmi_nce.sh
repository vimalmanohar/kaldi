#!/bin/bash
# Copyright 2014  Vimal Manohar (Johns Hopkins University)

# Semisupervised discriminative training using MMI objective for 
# supervised data and NCE objective for unsupervised data
# 4 iterations (by default) of Extended Baum-Welch update.
# MMI training (or optionally boosted MMI, if you give the --boost option).
#
# For the numerator we have a fixed alignment rather than a lattice--
# this actually follows from the way lattices are defined in Kaldi, which
# is to have a single path for each word (output-symbol) sequence.

# Begin configuration section.
cmd=run.pl
num_iters=4
stage=0

# MMI Options
boost=0.0
cancel=true # if true, cancel num and den counts on each frame.
drop_frames=false # if true, ignore stats from frames where num + den
                       # have no overlap. 

tau=1200
weight_tau=10
alpha=10          # Weight on NCE term in objective

transform_dir_sup=
transform_dir_unsup=

acwt=0.1
update_flags="mv"
# End configuration section

echo "$0 $@"  # Print the command line for logging

[ -f ./path.sh ] && . ./path.sh; # source the path.
. parse_options.sh || exit 1;

if [ $# -ne 7 ]; then
  echo "Usage: steps/train_mmi_nce.sh <data-sup> <data-unsup> <lang> <ali> <denlats> <lats> <exp>"
  echo " e.g.: steps/train_mmi_nce.sh data/train data/unsup data/lang exp/tri3b_ali exp/tri3b_denlats exp/tri3b/decode_unsup exp/tri3b_mmi_nce"
  echo "Main options (for others, see top of script file)"
  echo "  --boost <boost-weight>                           # (e.g. 0.1), for boosted MMI.  (default 0)"
  echo "  --cancel (true|false)                            # cancel stats (true by default)"
  echo "  --cmd (utils/run.pl|utils/queue.pl <queue opts>) # how to run jobs."
  echo "  --config <config-file>                           # config containing options"
  echo "  --stage <stage>                                  # stage to do partial re-run from."
  echo "  --tau                                            # tau for i-smooth to last iter (default 400)"
  echo "  --weight-tau                                     # tau weight update for i-smooth to last iter (default 10)"
  echo "  --alpha                                          # scale unsupervised stats relative to supervised stats"
  exit 1;
fi

data_sup=$1
data_unsup=$2
lang=$3
alidir=$4
denlatdir=$5
latdir=$6
dir=$7

mkdir -p $dir/log

for f in $data_unsup/feats.scp $data_sup/feats.scp $alidir/{tree,final.mdl,ali.1.gz} $latdir/lat.1.gz $denlatdir/lat.1.gz; do
  [ ! -f $f ] && echo "$0: no such file $f" && exit 1;
done
nj_sup=`cat $alidir/num_jobs` || exit 1;
[ "$nj_sup" -ne "`cat $denlatdir/num_jobs`" ] && \
  echo "$alidir and $denlatdir have different num-jobs" && exit 1;
nj_unsup=`cat $latdir/num_jobs` || exit 1;

sdata_sup=$data_sup/split$nj_sup
sdata_unsup=$data_unsup/split$nj_unsup
splice_opts=`cat $alidir/splice_opts 2>/dev/null`
cmvn_opts=`cat $alidir/cmvn_opts 2>/dev/null`
mkdir -p $dir/log
cp $alidir/splice_opts $dir 2>/dev/null
cp $alidir/cmvn_opts $dir 2>/dev/null # cmn/cmvn option.
[[ -d $sdata_sup && $data_sup/feats.scp -ot $sdata_sup ]] || split_data.sh $data_sup $nj_sup || exit 1;
[[ -d $sdata_unsup && $data_unsup/feats.scp -ot $sdata_unsup ]] || split_data.sh $data_unsup $nj_unsup || exit 1;
echo $nj_sup > $dir/num_jobs_sup
echo $nj_unsup > $dir/num_jobs_unsup

cp $alidir/tree $dir
cp $alidir/final.mdl $dir/0.mdl

silphonelist=`cat $lang/phones/silence.csl` || exit 1;

# Set up features

if [ -f $alidir/final.mat ]; then feat_type=lda; else feat_type=delta; fi
echo "$0: feature type is $feat_type"

case $feat_type in
  delta) feats_sup="ark,s,cs:apply-cmvn $cmvn_opts --utt2spk=ark:$sdata_sup/JOB/utt2spk scp:$sdata_sup/JOB/cmvn.scp scp:$sdata_sup/JOB/feats.scp ark:- | add-deltas ark:- ark:- |";;
  lda) feats_sup="ark,s,cs:apply-cmvn $cmvn_opts --utt2spk=ark:$sdata_sup/JOB/utt2spk scp:$sdata_sup/JOB/cmvn.scp scp:$sdata_sup/JOB/feats.scp ark:- | splice-feats $splice_opts ark:- ark:- | transform-feats $alidir/final.mat ark:- ark:- |"
    cp $alidir/final.mat $dir    
    ;;
  *) echo "Invalid feature type $feat_type" && exit 1;
esac

case $feat_type in
  delta) feats_unsup="ark,s,cs:apply-cmvn $cmvn_opts --utt2spk=ark:$sdata_unsup/JOB/utt2spk scp:$sdata_unsup/JOB/cmvn.scp scp:$sdata_unsup/JOB/feats.scp ark:- | add-deltas ark:- ark:- |";;
  lda) feats_unsup="ark,s,cs:apply-cmvn $cmvn_opts --utt2spk=ark:$sdata_unsup/JOB/utt2spk scp:$sdata_unsup/JOB/cmvn.scp scp:$sdata_unsup/JOB/feats.scp ark:- | splice-feats $splice_opts ark:- ark:- | transform-feats $alidir/final.mat ark:- ark:- |"
    ;;
  *) echo "Invalid feature type $feat_type" && exit 1;
esac

[ -z "$transform_dir_sup" ] && echo "$0: --transform-dir-sup was not specified. Trying $alidir as transform_dir" && transform_dir_sup=$alidir

[ -f $transform_dir_sup/trans.1 ] && echo Using transforms from $transform_dir_sup for supervised data && \
  feats_sup="$feats_sup transform-feats --utt2spk=ark:$sdata_sup/JOB/utt2spk ark,s,cs:$transform_dir_sup/trans.JOB ark:- ark:- |"


[ -z "$transform_dir_unsup" ] && echo "$0: --transform-dir-unsup was not specified. Trying $latdir as transform_dir" && transform_dir_unsup=$latdir

[ -f $transform_dir_unsup/trans.1 ] && echo Using transforms from $transform_dir_unsup for unsupervised data && \
  feats_unsup="$feats_unsup transform-feats --utt2spk=ark:$sdata_unsup/JOB/utt2spk ark,s,cs:$transform_dir_unsup/trans.JOB ark:- ark:- |"

denlats="ark:gunzip -c $denlatdir/lat.JOB.gz|"
if [[ "$boost" != "0.0" && "$boost" != 0 ]]; then
  denlats="$denlats lattice-boost-ali --b=$boost --silence-phones=$silphonelist $alidir/final.mdl ark:- 'ark,s,cs:gunzip -c $alidir/ali.JOB.gz|' ark:- |"
fi

lats="ark:gunzip -c $latdir/lat.JOB.gz|"
cur_mdl=$alidir/final.mdl

x=0
while [ $x -lt $num_iters ]; do
  echo "Iteration $x of MMI-NCE training"
  # Note: the num and den states are accumulated at the same time, so we
  # can cancel them per frame.
  if [ $stage -le $x ]; then
    $cmd JOB=1:$nj_sup $dir/log/acc.$x.JOB.log \
      gmm-rescore-lattice $dir/$x.mdl "$denlats" "$feats_sup" ark:- \| \
      lattice-to-post --acoustic-scale=$acwt ark:- ark:- \| \
      sum-post --drop-frames=$drop_frames --merge=$cancel --scale1=-1 \
      ark:- "ark,s,cs:gunzip -c $alidir/ali.JOB.gz | ali-to-post ark:- ark:- |" ark:- \| \
      gmm-acc-stats2 $dir/$x.mdl "$feats_sup" ark,s,cs:- \
      $dir/num_acc.$x.JOB.acc $dir/den_acc.$x.JOB.acc || exit 1;

    n=`echo $dir/{num,den}_acc.$x.*.acc | wc -w`;
    [ "$n" -ne $[$nj_sup*2] ] && \
      echo "Wrong number of MMI accumulators $n versus 2*$nj_sup" && exit 1;
    $cmd $dir/log/den_acc_sum.$x.log \
      gmm-sum-accs $dir/den_acc.$x.acc $dir/den_acc.$x.*.acc || exit 1;
    rm $dir/den_acc.$x.*.acc
    $cmd $dir/log/num_acc_sum.$x.log \
      gmm-sum-accs $dir/num_acc.$x.acc $dir/num_acc.$x.*.acc || exit 1;
    rm $dir/num_acc.$x.*.acc
    
    $cmd JOB=1:$nj_unsup $dir/log/lat_acc.$x.JOB.log \
      gmm-rescore-lattice $cur_mdl "$lats" "$feats_unsup" ark:- \| \
      lattice-to-nce-post --acoustic-scale=$acwt $cur_mdl \
        ark:- ark:- \| \
      gmm-acc-stats $cur_mdl "$feats_unsup" ark,s,cs:- \
        $dir/lat_acc.$x.JOB.acc || exit 1;
    
    n=`echo $dir/lat_acc.$x.*.acc | wc -w`;
    [ "$n" -ne $[$nj_unsup] ] && \
      echo "Wrong number of NCE accumulators $n versus $nj_unsup" && exit 1;
    $cmd $dir/log/lat_acc_sum.$x.log \
      gmm-sum-accs $dir/lat_acc.$x.acc $dir/lat_acc.$x.*.acc || exit 1;
    rm $dir/lat_acc.$x.*.acc

  # note: this tau value is for smoothing towards model parameters, not
  # as in the Boosted MMI paper, not towards the ML stats as in the earlier
  # work on discriminative training (e.g. my thesis).  
  # You could use gmm-ismooth-stats to smooth to the ML stats, if you had
  # them available [here they're not available if cancel=true].

    $cmd $dir/log/update.$x.log \
      gmm-est-gaussians-ebw --tau=$tau --update-flags=$update_flags \
      $cur_mdl $dir/num_acc.$x.acc \
      "gmm-sum-accs - $dir/den_acc.$x.acc \"gmm-scale-accs -$alpha $dir/lat_acc.$x.acc - |\" |" \
      - \| gmm-est-weights-ebw --weight-tau=$weight_tau \
      --update-flags=$update_flags - $dir/num_acc.$x.acc \
      "gmm-sum-accs - $dir/den_acc.$x.acc \"gmm-scale-accs -$alpha $dir/lat_acc.$x.acc - |\" |" \
      $dir/$[$x+1].mdl || exit 1;
    rm $dir/{den,num,lat}_acc.$x.acc
  fi
  cur_mdl=$dir/$[$x+1].mdl

  # Some diagnostics: the objective function progress and auxiliary-function
  # improvement.

  tail -n 50 $dir/log/acc.$x.*.log | perl -e '$acwt=shift @ARGV; while(<STDIN>) { if(m/gmm-acc-stats2.+Overall weighted acoustic likelihood per frame was (\S+) over (\S+) frames/) { $tot_aclike += $1*$2; $tot_frames1 += $2; } if(m|lattice-to-post.+Overall average log-like/frame is (\S+) over (\S+) frames.  Average acoustic like/frame is (\S+)|) { $tot_den_lat_like += $1*$2; $tot_frames2 += $2; $tot_den_aclike += $3*$2; } } if (abs($tot_frames1 - $tot_frames2) > 0.01*($tot_frames1 + $tot_frames2)) { print STDERR "Frame-counts disagree $tot_frames1 versus $tot_frames2\n"; } $tot_den_lat_like /= $tot_frames2; $tot_den_aclike /= $tot_frames2; $tot_aclike *= ($acwt / $tot_frames1);  $num_like = $tot_aclike + $tot_den_aclike; $per_frame_objf = $num_like - $tot_den_lat_like; print "$per_frame_objf $tot_frames1\n"; ' $acwt > $dir/tmpf
  objf_mmi=`cat $dir/tmpf | awk '{print $1}'`;
  nf_mmi=`cat $dir/tmpf | awk '{print $2}'`;
  rm $dir/tmpf

 tail -n 50 $dir/log/acc.$x.*.log | perl -e 'while(<STDIN>) { if(m/lattice-to-nce-post.+Overall average Negative Conditional Entropy is (\S+) over (\S+) frames/) { $tot_objf += $1*$2; $tot_frames += $2; }} $tot_objf /= $tot_frames; print "$tot_objf*$ARGV[0] $tot_frames\n"; ' $alpha> $dir/tmpf
  objf_nce=`cat $dir/tmpf | awk '{print $1}'`;
  nf_nce=`cat $dir/tmpf | awk '{print $2}'`;
  rm $dir/tmpf

  nf=`perl -e "print $nf_nce + $nf_mmi"`
  impr=`grep -w Overall $dir/log/update.$x.log | awk '{x += $10*$12;} END{print x;}'`
  impr=`perl -e "print ($impr*$acwt/$nf);"` # We multiply by acwt, and divide by $nf which is the "real" number of frames.
  echo "Iteration $x: MMI objf was $objf_mmi, NCE objf was $objf_nce, auxf change was $impr" | tee $dir/objf.$x.log

  x=$[$x+1]
done

echo "MMI-NCE training finished"

rm $dir/final.mdl 2>/dev/null
ln -s $x.mdl $dir/final.mdl

exit 0;

