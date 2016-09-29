#!/usr/bin/env python


# Copyright 2016 Vijayaditya Peddinti.
#           2016 Vimal Manohar
# Apache 2.0.


# this script is based on steps/nnet3/lstm/train.sh


import subprocess
import argparse
import sys
import pprint
import logging
import imp
import traceback
from nnet3_train_lib import *

nnet3_log_parse = imp.load_source('', 'steps/nnet3/report/nnet3_log_parse_lib.py')

logger = logging.getLogger(__name__)
logger.setLevel(logging.INFO)
handler = logging.StreamHandler()
handler.setLevel(logging.INFO)
formatter = logging.Formatter('%(asctime)s [%(filename)s:%(lineno)s - %(funcName)s - %(levelname)s ] %(message)s')
handler.setFormatter(formatter)
logger.addHandler(handler)
logger.info('Starting trainer from existing raw model (train_raw_more.py)')


def GetArgs():
    # we add compulsary arguments as named arguments for readability
    parser = argparse.ArgumentParser(description="""
    Trains a raw acoustic model using an existing model""",
    formatter_class=argparse.ArgumentDefaultsHelpFormatter)

    # feat options
    parser.add_argument("--feat.online-ivector-dir", type=str, dest='online_ivector_dir',
                        default = None, action = NullstrToNoneAction,
                        help="""directory with the ivectors extracted in
                        an online fashion.""")
    parser.add_argument("--feat.cmvn-opts", type=str, dest='cmvn_opts',
                        default = None, action = NullstrToNoneAction,
                        help="A string specifying '--norm-means' and '--norm-vars' values")

    # egs extraction options
    parser.add_argument("--egs.chunk-width", type=int, dest='chunk_width',
                        default = 20,
                        help="""Number of output labels in the sequence
                        used to train an LSTM.
                        Caution: if you double this you should halve
                        --trainer.samples-per-iter.""")
    parser.add_argument("--egs.chunk-left-context", type=int, dest='chunk_left_context',
                        default = 40,
                        help="""Number of left steps used in the estimation of LSTM
                        state before prediction of the first label""")
    parser.add_argument("--egs.chunk-right-context", type=int, dest='chunk_right_context',
                        default = 0,
                        help="""Number of right steps used in the estimation of BLSTM
                        state before prediction of the first label""")
    parser.add_argument("--egs.transform_dir", type=str, dest='transform_dir',
                        default = None, action = NullstrToNoneAction,
                        help="""String to provide options directly to steps/nnet3/get_egs.sh script""")
    parser.add_argument("--egs.dir", type=str, dest='egs_dir',
                        default = None, action = NullstrToNoneAction,
                        help="""Directory with egs. If specified this directory
                        will be used rather than extracting egs""")
    parser.add_argument("--egs.stage", type=int, dest='egs_stage',
                        default = 0, help="Stage at which get_egs.sh should be restarted")
    parser.add_argument("--egs.opts", type=str, dest='egs_opts',
                        default = None, action = NullstrToNoneAction,
                        help="""String to provide options directly to steps/nnet3/get_egs.sh script""")

    # trainer options
    parser.add_argument("--trainer.num-epochs", type=int, dest='num_epochs',
                        default = 8,
                        help="Number of epochs to train the model")
    parser.add_argument("--trainer.prior-subset-size", type=int, dest='prior_subset_size',
                        default = 20000,
                        help="Number of samples for computing priors")
    parser.add_argument("--trainer.num-jobs-compute-prior", type=int, dest='num_jobs_compute_prior',
                        default = 10,
                        help="The prior computation jobs are single threaded and run on the CPU")
    parser.add_argument("--trainer.max-models-combine", type=int, dest='max_models_combine',
                        default = 20,
                        help="The maximum number of models used in the final model combination stage. These models will themselves be averages of iteration-number ranges")
    parser.add_argument("--trainer.shuffle-buffer-size", type=int, dest='shuffle_buffer_size',
                        default = 5000,
                        help=""" Controls randomization of the samples on each
                        iteration. If 0 or a large value the randomization is
                        complete, but this will consume memory and cause spikes
                        in disk I/O.  Smaller is easier on disk and memory but
                        less random.  It's not a huge deal though, as samples
                        are anyway randomized right at the start.
                        (the point of this is to get data in different
                        minibatches on different iterations, since in the
                        preconditioning method, 2 samples in the same minibatch
                        can affect each others' gradients.""")
    parser.add_argument("--trainer.max-param-change", type=float, dest='max_param_change',
                        default=2.0,
                        help="""The maximum change in parameters allowed
                        per minibatch, measured in Frobenius norm over
                        the entire model""")
    parser.add_argument("--trainer.samples-per-iter", type=int, dest='samples_per_iter',
                        default=20000,
                        help="""This is really the number of egs in each
                        archive.  Each eg has 'chunk_width' frames in it--
                        for chunk_width=20, this value (20k) is equivalent
                        to the 400k number that we use as a default in
                        regular DNN training.""")


    # Parameters for the optimization
    parser.add_argument("--trainer.optimization.initial-effective-lrate", type=float, dest='initial_effective_lrate',
                        default = 0.0003,
                        help="Learning rate used during the initial iteration")
    parser.add_argument("--trainer.optimization.final-effective-lrate", type=float, dest='final_effective_lrate',
                        default = 0.00003,
                        help="Learning rate used during the final iteration")
    parser.add_argument("--trainer.optimization.num-jobs-initial", type=int, dest='num_jobs_initial',
                        default = 1,
                        help="Number of neural net jobs to run in parallel at the start of training")
    parser.add_argument("--trainer.optimization.num-jobs-final", type=int, dest='num_jobs_final',
                        default = 8,
                        help="Number of neural net jobs to run in parallel at the end of training")
    parser.add_argument("--trainer.optimization.max-models-combine", type=int, dest='max_models_combine',
                        default = 20,
                        help = """ The is the maximum number of models we give to the
                                   final 'combine' stage, but these models will themselves
                                   be averages of iteration-number ranges. """)
    parser.add_argument("--trainer.optimization.momentum", type=float, dest='momentum',
                        default = 0.5,
                        help="""Momentum used in update computation.
                        Note: we implemented it in such a way that
                        it doesn't increase the effective learning rate.""")
    parser.add_argument("--trainer.optimization.shrink-value", type=float, dest='shrink_value',
                        default = 0.99,
                        help="Scaling factor used for scaling the parameter matrices when the derivative averages are below the shrink-threshold at the non-linearities")
    parser.add_argument("--trainer.optimization.shrink-threshold", type=float, dest='shrink_threshold',
                        default = 0.15,
                        help="If the derivative averages are below this threshold we scale the parameter matrices with the shrink-value. It is less than 0.25 for sigmoid non-linearities.")

    # RNN specific trainer options
    parser.add_argument("--trainer.rnn.num-chunk-per-minibatch", type=int, dest='num_chunk_per_minibatch',
                        default=100,
                        help="Number of sequences to be processed in parallel every minibatch" )
    parser.add_argument("--trainer.rnn.num-bptt-steps", type=int, dest='num_bptt_steps',
                        default=None,
                        help="The number of time steps to back-propagate from the last label in the chunk. By default it is same as the chunk-width." )

    # General options
    parser.add_argument("--stage", type=int, default=-4,
                        help="Specifies the stage of the experiment to execution from")
    parser.add_argument("--exit-stage", type=int, default=None,
                        help="If specified, training exits before running this stage")
    parser.add_argument("--cmd", type=str, action = NullstrToNoneAction,
                        dest = "command",
                        help="""Specifies the script to launch jobs.
                        e.g. queue.pl for launching on SGE cluster
                             run.pl for launching on local machine
                        """, default = "queue.pl")
    parser.add_argument("--egs.cmd", type=str, action = NullstrToNoneAction,
                        dest = "egs_command",
                        help="""Script to launch egs jobs""", default = "queue.pl")
    parser.add_argument("--use-gpu", type=str, action = StrToBoolAction,
                        choices = ["true", "false"],
                        help="Use GPU for training", default=True)
    parser.add_argument("--cleanup", type=str, action = StrToBoolAction,
                        choices = ["true", "false"],
                        help="Clean up models after training", default=True)
    parser.add_argument("--cleanup.remove-egs", type=str, dest='remove_egs',
                        default = True, action = StrToBoolAction,
                        choices = ["true", "false"],
                        help="""If true, remove egs after experiment""")
    parser.add_argument("--cleanup.preserve-model-interval", dest = "preserve_model_interval",
                        type=int, default=100,
                        help="Determines iterations for which models will be preserved during cleanup. If iter % preserve_model_interval == 0 model will be preserved.")

    parser.add_argument("--reporting.email", dest = "email",
                        type=str, default=None, action = NullstrToNoneAction,
                        help=""" Email-id to report about the progress of the experiment.
                              NOTE: It assumes the machine on which the script is being run can send
                              emails from command line via. mail program. The
                              Kaldi mailing list will not support this feature.
                              It might require local expertise to setup. """)
    parser.add_argument("--reporting.interval", dest = "reporting_interval",
                        type=int, default=0.1,
                        help="Frequency with which reports have to be sent, measured in terms of fraction of iterations. If 0 and reporting mail has been specified then only failure notifications are sent")
    parser.add_argument("--nj", type=int, default=4,
                        help="Number of parallel jobs")

    parser.add_argument("--init-model", type=str,
                        help="Use a different initial model than dir/init.raw")
    parser.add_argument("--use-dense-targets", type=str, action=StrToBoolAction,
                       default = True, choices = ["true", "false"],
                       help="Train neural network using dense targets")
    parser.add_argument("--feat-dir", type=str, required = True,
                        help="Directory with features used for training the neural network.")
    parser.add_argument("--targets-scp", type=str, required = True,
                        help="Target for training neural network.")
    parser.add_argument("--dir", type=str, required = True,
                        help="Directory to store the models and all other files.")

    print(' '.join(sys.argv))

    args = parser.parse_args()

    [args, run_opts] = ProcessArgs(args)

    return [args, run_opts]

def ProcessArgs(args):
    # process the options
    if args.chunk_width < 1:
        raise Exception("--egs.chunk-width should have a minimum value of 1")

    if args.chunk_left_context < 0:
        raise Exception("--egs.chunk-left-context should be positive")

    if args.chunk_right_context < 0:
        raise Exception("--egs.chunk-right-context should be positive")


    if args.init_model is not None:
        RunKaldiCommand("cp {0} {1}".format(init_model,
                                                '{0}/init.raw'.format(args.dir)))

    if (not os.path.exists(args.dir)) or (not os.path.exists(args.dir+"/init.raw")):
        raise Exception("""This scripts expects {0} to exist and have an
        initial model init.raw""")

    # set the options corresponding to args.use_gpu
    run_opts = RunOpts()
    if args.use_gpu:
        if not CheckIfCudaCompiled():
            logger.warning("""
    You are running with one thread but you have not compiled
    for CUDA.  You may be running a setup optimized for GPUs.  If you have
    GPUs and have nvcc installed, go to src/ and do ./configure; make""")

        run_opts.train_queue_opt = "--gpu 1"
        run_opts.parallel_train_opts = ""
        run_opts.combine_queue_opt = "--gpu 1"
        run_opts.prior_gpu_opt = "--use-gpu=yes"
        run_opts.prior_queue_opt = "--gpu 1"

    else:
        logger.warning("""
    Without using a GPU this will be very slow.  nnet3 does not yet support multiple threads.""")

        run_opts.train_queue_opt = ""
        run_opts.parallel_train_opts = "--use-gpu=no"
        run_opts.combine_queue_opt = ""
        run_opts.prior_gpu_opt = "--use-gpu=no"
        run_opts.prior_queue_opt = ""

    run_opts.command = args.command
    run_opts.egs_command = args.egs_command if args.egs_command is not None else args.command
    run_opts.num_jobs_compute_prior = args.num_jobs_compute_prior

    return [args, run_opts]

#class StrToBoolAction(argparse.Action):
#    """ A custom action to convert bools from shell format i.e., true/false
#        to python format i.e., True/False """
#    def __call__(self, parser, namespace, values, option_string=None):
#        if values == "true":
#            setattr(namespace, self.dest, True)
#        elif values == "false":
#            setattr(namespace, self.dest, False)
#        else:
#            raise Exception("Unknown value {0} for --{1}".format(values, self.dest))
#
#class NullstrToNoneAction(argparse.Action):
#    """ A custom action to convert empty strings passed by shell
#        to None in python. This is necessary as shell scripts print null strings
#        when a variable is not specified. We could use the more apt None
#        in python. """
#    def __call__(self, parser, namespace, values, option_string=None):
#            if values.strip() == "":
#                setattr(namespace, self.dest, None)
#            else:
#                setattr(namespace, self.dest, values)


# a class to store run options
class RunOpts:
    def __init__(self):
        self.command = None
        self.train_queue_opt = None
        self.combine_queue_opt = None
        self.prior_gpu_opt = None
        self.prior_queue_opt = None
        self.parallel_train_opts = None

def TrainNewModels(dir, iter, num_jobs, num_archives_processed, num_archives,
                   raw_model_string, egs_dir,
                   left_context, right_context, min_deriv_time,
                   momentum, max_param_change,
                   shuffle_buffer_size, num_chunk_per_minibatch,
                   cache_read_opt, run_opts):
      # We cannot easily use a single parallel SGE job to do the main training,
      # because the computation of which archive and which --frame option
      # to use for each job is a little complex, so we spawn each one separately.
      # this is no longer true for RNNs as we use do not use the --frame option
      # but we use the same script for consistency with FF-DNN code

    context_opts="--left-context={0} --right-context={1}".format(
                  left_context, right_context)
    processes = []
    for job in range(1,num_jobs+1):
        k = num_archives_processed + job - 1 # k is a zero-based index that we will derive
                                               # the other indexes from.
        archive_index = (k % num_archives) + 1 # work out the 1-based archive index.

        cache_write_opt = ""
        if job == 1:
          # an option for writing cache (storing pairs of nnet-computations and
          # computation-requests) during training.
          cache_write_opt="--write-cache={dir}/cache.{iter}".format(dir=dir, iter=iter+1)

        process_handle = RunKaldiCommand("""
{command} {train_queue_opt} {dir}/log/train.{iter}.{job}.log \
  nnet3-train {parallel_train_opts} {cache_read_opt} {cache_write_opt} \
  --print-interval=10 --momentum={momentum} \
  --max-param-change={max_param_change} \
  --optimization.min-deriv-time={min_deriv_time} "{raw_model}" \
  "ark,bg:nnet3-copy-egs {context_opts} ark:{egs_dir}/egs.{archive_index}.ark ark:- | nnet3-shuffle-egs --buffer-size={shuffle_buffer_size} --srand={iter} ark:- ark:-| nnet3-merge-egs --minibatch-size={num_chunk_per_minibatch} --measure-output-frames=false --discard-partial-minibatches=true ark:- ark:- |" \
  {dir}/{next_iter}.{job}.raw
          """.format(command = run_opts.command,
                     train_queue_opt = run_opts.train_queue_opt,
                     dir = dir, iter = iter, next_iter = iter + 1, job = job,
                     parallel_train_opts = run_opts.parallel_train_opts,
                     cache_read_opt = cache_read_opt, cache_write_opt = cache_write_opt,
                     momentum = momentum, max_param_change = max_param_change,
                     min_deriv_time = min_deriv_time,
                     raw_model = raw_model_string, context_opts = context_opts,
                     egs_dir = egs_dir, archive_index = archive_index,
                     shuffle_buffer_size = shuffle_buffer_size,
                     num_chunk_per_minibatch = num_chunk_per_minibatch),
          wait = False)

        processes.append(process_handle)

    all_success = True
    for process in processes:
        process.wait()
        [stdout_value, stderr_value] = process.communicate()
        print(stderr_value)
        if process.returncode != 0:
            all_success = False

    if not all_success:
        open('{0}/.error'.format(dir), 'w').close()
        raise Exception("There was error during training iteration {0}".format(iter))

def TrainOneIteration(dir, iter, egs_dir,
                      num_jobs, num_archives_processed, num_archives,
                      learning_rate, shrinkage_value, num_chunk_per_minibatch,
                      left_context, right_context, min_deriv_time,
                      momentum, max_param_change, shuffle_buffer_size,
                      compute_accuracy,
                      run_opts, use_raw_nnet = True):
    # Set off jobs doing some diagnostics, in the background.
    # Use the egs dir from the previous iteration for the diagnostics
    logger.info("Training neural net (pass {0})".format(iter))

    ComputeTrainCvProbabilities(dir, iter, egs_dir, run_opts, use_raw_nnet = True, compute_accuracy = compute_accuracy)

    if iter > 0:
        ComputeProgress(dir, iter, egs_dir, run_opts, use_raw_nnet = True)

    # an option for writing cache (storing pairs of nnet-computations
    # and computation-requests) during training.
    cache_read_opt = ""
    do_average = True
    if iter == 0:
        do_average = False   # on iteration 0, pick the best, don't average.
    else:
        cache_read_opt = "--read-cache={dir}/cache.{iter}".format(dir=dir, iter=iter)
    raw_model_string = "nnet3-copy --learning-rate={lr} {dir}/{iter}.raw - |".format(lr = learning_rate, dir = dir, iter = iter)

    if do_average:
      cur_num_chunk_per_minibatch = num_chunk_per_minibatch
    else:
      # on iteration zero or when we just added a layer, use a smaller minibatch
      # size (and we will later choose the output of just one of the jobs): the
      # model-averaging isn't always helpful when the model is changing too fast
      # (i.e. it can worsen the objective function), and the smaller minibatch
      # size will help to keep the update stable.
      cur_num_chunk_per_minibatch = num_chunk_per_minibatch / 2

    try:
        os.remove("{0}/.error".format(dir))
    except OSError:
        pass

    TrainNewModels(dir, iter, num_jobs, num_archives_processed, num_archives,
                   raw_model_string, egs_dir,
                   left_context, right_context, min_deriv_time,
                   momentum, max_param_change,
                   shuffle_buffer_size, cur_num_chunk_per_minibatch,
                   cache_read_opt, run_opts)
    [models_to_average, best_model] = GetSuccessfulModels(num_jobs, '{0}/log/train.{1}.%.log'.format(dir,iter))
    nnets_list = []
    for n in models_to_average:
        nnets_list.append("{0}/{1}.{2}.raw".format(dir, iter + 1, n))

    if do_average:
        # average the output of the different jobs.
        GetAverageNnetModel(dir = dir, iter = iter,
                            nnets_list = " ".join(nnets_list),
                            run_opts = run_opts,
                            use_raw_nnet = True,
                            shrink = shrinkage_value)

    else:
        # choose the best model from different jobs
        GetBestNnetModel(dir = dir, iter = iter,
                         best_model_index = best_model,
                         run_opts = run_opts,
                         use_raw_nnet = True,
                         shrink = shrinkage_value)

    try:
        for i in range(1, num_jobs + 1):
            os.remove("{0}/{1}.{2}.raw".format(dir, iter + 1, i))
    except OSError:
        raise Exception("Error while trying to delete the raw models")

    new_model = "{0}/{1}.raw".format(dir, iter + 1)

    if not os.path.isfile(new_model):
        raise Exception("Could not find {0}, at the end of iteration {1}".format(new_model, iter))
    elif os.stat(new_model).st_size == 0:
        raise Exception("{0} has size 0. Something went wrong in iteration {1}".format(new_model, iter))
    if cache_read_opt and os.path.exists("{0}/cache.{1}".format(dir, iter)):
        os.remove("{0}/cache.{1}".format(dir, iter))


# args is a Namespace with the required parameters
def Train(args, run_opts):
    arg_string = pprint.pformat(vars(args))
    logger.info("Arguments for the experiment\n{0}".format(arg_string))

    feat_dim = GetFeatDim(args.feat_dir)
    ivector_dim = GetIvectorDim(args.online_ivector_dir)

    # split the training data into parts for individual jobs
    SplitData(args.feat_dir, args.nj)

    variables = ParseModelInfo("{0}/init.raw".format(args.dir), use_raw_nnet = True)

    # Set some variables.
    try:
        model_left_context = variables['model_left_context']
        model_right_context = variables['model_right_context']
        num_targets = int(variables['num_targets'])
    except KeyError as e:
        raise Exception("KeyError {0}: Could not read some variables from the model")

    left_context = args.chunk_left_context + model_left_context
    right_context = args.chunk_right_context + model_right_context

    if args.use_dense_targets:
        if GetFeatDimFromScp(args.targets_scp) != num_targets:
            raise Exception("Mismatch between num-targets provided to "
                            "script vs configs")

    default_egs_dir = '{0}/egs'.format(args.dir)

    if args.use_dense_targets:
        target_type = "dense"
        compute_accuracy = False
    else:
        target_type = "sparse"
        compute_accuracy = True

    if (args.stage <= -3) and args.egs_dir is None:
        logger.info("Generating egs")

        GenerateEgsFromTargets(args.feat_dir, args.targets_scp, default_egs_dir,
                    left_context, right_context,
                    args.chunk_width + left_context,
                    args.chunk_width + right_context, run_opts,
                    frames_per_eg = args.chunk_width,
                    egs_opts = args.egs_opts,
                    cmvn_opts = args.cmvn_opts,
                    online_ivector_dir = args.online_ivector_dir,
                    samples_per_iter = args.samples_per_iter,
                    transform_dir = args.transform_dir,
                    stage = args.egs_stage,
                    target_type = target_type,
                    num_targets = num_targets)

    if args.egs_dir is None:
        egs_dir = default_egs_dir
    else:
        egs_dir = args.egs_dir

    [egs_left_context, egs_right_context, frames_per_eg, num_archives] = VerifyEgsDir(egs_dir, feat_dim, ivector_dim, left_context, right_context)
    assert(args.chunk_width == frames_per_eg)

    if (args.num_jobs_final > num_archives):
        raise Exception('num_jobs_final cannot exceed the number of archives in the egs directory')

    # copy the properties of the egs to dir for
    # use during decoding
    CopyEgsPropertiesToExpDir(egs_dir, args.dir)

    RunKaldiCommand("nnet3-copy {0}/init.raw {0}/0.raw".format(args.dir))

    # set num_iters so that as close as possible, we process the data $num_epochs
    # times, i.e. $num_iters*$avg_num_jobs) == $num_epochs*$num_archives,
    # where avg_num_jobs=(num_jobs_initial+num_jobs_final)/2.
    num_archives_to_process = args.num_epochs * num_archives
    num_archives_processed = 0
    num_iters=(num_archives_to_process * 2) / (args.num_jobs_initial + args.num_jobs_final)

    num_iters_combine = VerifyIterations(num_iters, args.num_epochs,
                                         0, num_archives,
                                         args.max_models_combine, 0,
                                         args.num_jobs_final)

    learning_rate = lambda iter, current_num_jobs, num_archives_processed: GetLearningRate(iter, current_num_jobs, num_iters,
                                                                   num_archives_processed,
                                                                    num_archives_to_process,
                                                                    args.initial_effective_lrate,
                                                                    args.final_effective_lrate)
    if args.num_bptt_steps is None:
        num_bptt_steps = args.chunk_width
    else:
        num_bptt_steps = args.num_bptt_steps

    min_deriv_time = args.chunk_width - num_bptt_steps


    logger.info("Training will run for {0} epochs = {1} iterations".format(args.num_epochs, num_iters))
    for iter in range(num_iters):
        if (args.exit_stage is not None) and (iter == args.exit_stage):
            logger.info("Exiting early due to --exit-stage {0}".format(iter))
            return
        current_num_jobs = int(0.5 + args.num_jobs_initial + (args.num_jobs_final - args.num_jobs_initial) * float(iter) / num_iters)

        if args.stage <= iter:
            model_file = "{dir}/{iter}.raw".format(dir = args.dir, iter = iter)
            shrinkage_value = args.shrink_value if DoShrinkage(iter, model_file, "SigmoidComponent", args.shrink_threshold, use_raw_nnet = True) else 1
            logger.info("On iteration {0}, learning rate is {1} and shrink value is {2}.".format(iter, learning_rate(iter, current_num_jobs, num_archives_processed), shrinkage_value))

            TrainOneIteration(dir = args.dir, iter = iter, egs_dir = egs_dir,
                              num_jobs = current_num_jobs,
                              num_archives_processed = num_archives_processed,
                              num_archives = num_archives,
                              learning_rate = learning_rate(iter, current_num_jobs, num_archives_processed),
                              shrinkage_value = shrinkage_value,
                              num_chunk_per_minibatch = args.num_chunk_per_minibatch,
                              left_context = left_context,
                              right_context = right_context,
                              min_deriv_time = min_deriv_time,
                              momentum = args.momentum,
                              max_param_change = args.max_param_change,
                              shuffle_buffer_size = args.shuffle_buffer_size,
                              compute_accuracy = compute_accuracy,
                              run_opts = run_opts,
                              use_raw_nnet = True)
            if args.cleanup:
                # do a clean up everythin but the last 2 models, under certain conditions
                RemoveModel(args.dir, iter-2, num_iters, num_iters_combine,
                            args.preserve_model_interval, use_raw_nnet = True)

            if args.email is not None:
                reporting_iter_interval = num_iters * args.reporting_interval
                if iter % reporting_iter_interval == 0:
                # lets do some reporting
                    [report, times, data] = nnet3_log_parse.GenerateAccuracyReport(args.dir)
                    message = report
                    subject = "Update : Expt {dir} : Iter {iter}".format(dir = args.dir, iter = iter)
                    sendMail(message, subject, args.email)

        num_archives_processed = num_archives_processed + current_num_jobs

    if args.stage <= num_iters:
        logger.info("Doing final combination to produce final.raw")
        CombineModels(args.dir, num_iters, num_iters_combine, egs_dir, run_opts,
                chunk_width = args.chunk_width, use_raw_nnet = True)

    if not args.use_dense_targets and args.stage <= num_iters + 1:
        logger.info("Getting average posterior for purpose of using as priors to convert posteriors into likelihoods.")
        avg_post_vec_file = ComputeAveragePosterior(args.dir, 'final', egs_dir,
                                num_archives, args.prior_subset_size, run_opts, use_raw_nnet = True)

    if args.cleanup:
        logger.info("Cleaning up the experiment directory {0}".format(args.dir))
        remove_egs = args.remove_egs
        if args.egs_dir is not None:
            # this egs_dir was not created by this experiment so we will not
            # delete it
            remove_egs = False

        CleanNnetDir(args.dir, num_iters, egs_dir,
                     preserve_model_interval = args.preserve_model_interval,
                     remove_egs = remove_egs,
                     use_raw_nnet = True)

    # do some reporting
    [report, times, data] = nnet3_log_parse.GenerateAccuracyReport(args.dir)
    if args.email is not None:
        SendMail(report, "Update : Expt {0} : complete".format(args.dir), args.email)

    report_handle = open("{dir}/accuracy.report".format(dir = args.dir), "w")
    report_handle.write(report)
    report_handle.close()

def Main():
    [args, run_opts] = GetArgs()
    try:
        Train(args, run_opts)
    except Exception as e:
        if args.email is not None:
            message = "Training session for experiment {dir} died due to an error.".format(dir = args.dir)
            sendMail(message, message, args.email)
        traceback.print_exc()
        raise e

def SendMail(message, subject, email_id):
    try:
        subprocess.Popen('echo "{message}" | mail -s "{subject}" {email} '.format(
            message = message,
            subject = subject,
            email = email_id), shell=True)
    except Exception as e:
        logger.info(" Unable to send mail due to error:\n {error}".format(error = str(e)))
        pass

if __name__ == "__main__":
    Main()

