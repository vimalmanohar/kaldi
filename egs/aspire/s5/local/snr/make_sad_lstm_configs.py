#!/usr/bin/env python

from __future__ import print_function
import os
import argparse
import sys
import warnings
import copy
import imp
import shlex

nodes = imp.load_source('nodes', 'steps/nnet3/components.py')
nnet3_train_lib = imp.load_source('ntl', 'steps/nnet3/nnet3_train_lib.py')
chain_lib = imp.load_source('ncl', 'steps/nnet3/chain/nnet3_chain_lib.py')

def GetArgs():
    # we add compulsary arguments as named arguments for readability
    parser = argparse.ArgumentParser(description="Writes config files and variables "
                                                 "for LSTMs creation and training",
                                     epilog="See steps/nnet3/lstm/train.sh for example.")

    # Only one of these arguments can be specified, and one of them has to
    # be compulsarily specified
    feat_group = parser.add_mutually_exclusive_group(required = True)
    feat_group.add_argument("--feat-dim", type=int,
                            help="Raw feature dimension, e.g. 13")
    feat_group.add_argument("--feat-dir", type=str,
                            help="Feature directory, from which we derive the feat-dim")

    # only one of these arguments can be specified
    ivector_group = parser.add_mutually_exclusive_group(required = False)
    ivector_group.add_argument("--ivector-dim", type=int,
                                help="iVector dimension, e.g. 100", default=0)
    ivector_group.add_argument("--ivector-dir", type=str,
                                help="iVector dir, which will be used to derive the ivector-dim  ", default=None)

    num_target_group = parser.add_mutually_exclusive_group(required = True)
    num_target_group.add_argument("--num-targets", type=int,
                                  help="number of network targets (e.g. num-pdf-ids/num-leaves)")
    num_target_group.add_argument("--ali-dir", type=str,
                                  help="alignment directory, from which we derive the num-targets")
    num_target_group.add_argument("--tree-dir", type=str,
                                  help="directory with final.mdl, from which we derive the num-targets")
    num_target_group.add_argument("--output-node-parameters", type=str, action='append',
                                  dest='output_node_para_array',
                                  help = "Define output nodes' and their parameters like output-suffix, dim, objective-type etc")

    # General neural network options
    parser.add_argument("--splice-indexes", type=str,
                        help="Splice indexes at input layer, e.g. '-3,-2,-1,0,1,2,3'", required = True, default="0")
    parser.add_argument("--xent-regularize", type=float,
                        help="For chain models, if nonzero, add a separate output for cross-entropy "
                        "regularization (with learning-rate-factor equal to the inverse of this)",
                        default=0.0)
    parser.add_argument("--add-lda", type=str, action=nnet3_train_lib.StrToBoolAction,
                        help="If \"true\" an LDA matrix computed from the input features "
                        "(spliced according to the first set of splice-indexes) will be used as "
                        "the first Affine layer. This affine layer's parameters are fixed during training. "
                        "This variable needs to be set to \"false\" when using dense-targets "
                        "or when --add-idct is set to \"true\".",
                        default=True, choices = ["false", "true"])

    # Output options
    parser.add_argument("--include-log-softmax", type=str, action=nnet3_train_lib.StrToBoolAction,
                        help="add the final softmax layer ", default=True, choices = ["false", "true"])
    parser.add_argument("--add-final-sigmoid", type=str, action=nnet3_train_lib.StrToBoolAction,
                        help="add a sigmoid layer as the final layer. Applicable only if skip-final-softmax is true.",
                        choices=['true', 'false'], default = False)
    parser.add_argument("--objective-type", type=str, default="linear",
                        choices = ["linear", "quadratic","xent-per-dim"],
                        help = "the type of objective; i.e. quadratic or linear")

    # LSTM options
    parser.add_argument("--num-lstm-layers", type=int,
                        help="Number of LSTM layers to be stacked", default=1)
    parser.add_argument("--cell-dim", type=int,
                        help="dimension of lstm-cell")
    parser.add_argument("--recurrent-projection-dim", type=int,
                        help="dimension of recurrent projection")
    parser.add_argument("--non-recurrent-projection-dim", type=int,
                        help="dimension of non-recurrent projection")
    parser.add_argument("--hidden-dim", type=int,
                        help="dimension of fully-connected layers")

    # Natural gradient options
    parser.add_argument("--ng-per-element-scale-options", type=str,
                        help="options to be supplied to NaturalGradientPerElementScaleComponent", default="")
    parser.add_argument("--ng-affine-options", type=str,
                        help="options to be supplied to NaturalGradientAffineComponent", default="")

    # Gradient clipper options
    parser.add_argument("--norm-based-clipping", type=str, action=nnet3_train_lib.StrToBoolAction,
                        help="use norm based clipping in ClipGradient components ", default=True, choices = ["false", "true"])
    parser.add_argument("--clipping-threshold", type=float,
                        help="clipping threshold used in ClipGradient components, if clipping-threshold=0 no clipping is done", default=30)
    parser.add_argument("--self-repair-scale-nonlinearity", type=float,
                        help="A non-zero value activates the self-repair mechanism in the sigmoid and tanh non-linearities of the LSTM", default=0.00001)
    parser.add_argument("--self-repair-scale-clipgradient", type=float,
                        help="A non-zero value activates the self-repair mechanism in the ClipGradient component of the LSTM", default=1.0)

    # Delay options
    parser.add_argument("--label-delay", type=int, default=None,
                        help="option to delay the labels to make the lstm robust")

    parser.add_argument("--lstm-delay", type=str, default=None,
                        help="option to have different delays in recurrence for each lstm")

    # Options to convert input MFCC into Fbank features. This is useful when a
    # LDA layer is not added (such as when using dense targets)
    parser.add_argument("--cepstral-lifter", type=float, dest = "cepstral_lifter",
                        help="The factor used for determining the liftering vector in the production of MFCC. "
                        "User has to ensure that it matches the lifter used in MFCC generation, "
                        "e.g. 22.0", default=22.0)
    parser.add_argument("--add-idct", type=str, action=nnet3_train_lib.StrToBoolAction,
                        help="Add an IDCT after input to convert MFCC to Fbank",
                        default = False, choices = ["true", "false"])

    parser.add_argument("config_dir",
                        help="Directory to write config files and variables")

    print(' '.join(sys.argv))

    args = parser.parse_args()
    args = CheckArgs(args)

    return args

def CheckArgs(args):
    if not os.path.exists(args.config_dir):
        os.makedirs(args.config_dir)

    ## Check arguments.
    if args.feat_dir is not None:
        args.feat_dim = nnet3_train_lib.GetFeatDim(args.feat_dir)

    if args.ivector_dir is not None:
        args.ivector_dim = nnet3_train_lib.GetIvectorDim(args.ivector_dir)

    if not args.feat_dim > 0:
        raise Exception("feat-dim has to be postive")

    if args.add_lda and args.add_idct:
        raise Exception("add-idct can be true only if add-lda is false")

    if len(args.output_node_para_array) == 0:
        if args.ali_dir is not None:
            args.num_targets = nnet3_train_lib.GetNumberOfLeaves(args.ali_dir)
        elif args.tree_dir is not None:
            args.num_targets = chain_lib.GetNumberOfLeaves(args.tree_dir)
        if not args.num_targets > 0:
            print(args.num_targets)
            raise Exception("num_targets has to be positive")
        args.output_node_para_array.append(
                "--dim={0} --objective-type={1} --include-log-softmax={2} --add-final-sigmoid={3} --xent-regularize={4}".format(
                    args.num_targets, args.objective_type,
                    "true" if args.include_log_softmax else "false",
                    "true" if args.add_final_sigmoid else "false",
                    args.xent_regularize))

    if not args.ivector_dim >= 0:
        raise Exception("ivector-dim has to be non-negative")

    if (args.num_lstm_layers < 1):
        sys.exit("--num-lstm-layers has to be a positive integer")
    if (args.clipping_threshold < 0):
        sys.exit("--clipping-threshold has to be a non-negative")
    if args.lstm_delay is None:
        args.lstm_delay = [[-1]] * args.num_lstm_layers
    else:
        try:
            args.lstm_delay = ParseLstmDelayString(args.lstm_delay.strip())
        except ValueError:
            sys.exit("--lstm-delay has incorrect format value. Provided value is '{0}'".format(args.lstm_delay))
        if len(args.lstm_delay) != args.num_lstm_layers:
            sys.exit("--lstm-delay: Number of delays provided has to match --num-lstm-layers")

    return args

def PrintConfig(file_name, config_lines):
    f = open(file_name, 'w')
    f.write("\n".join(config_lines['components'])+"\n")
    f.write("\n#Component nodes\n")
    f.write("\n".join(config_lines['component-nodes'])+"\n")
    f.close()

def ParseSpliceString(splice_indexes, label_delay=None):
    ## Work out splice_array e.g. splice_array = [ [ -3,-2,...3 ], [0], [-2,2], .. [ -8,8 ] ]
    split1 = splice_indexes.split(" ");  # we already checked the string is nonempty.
    if len(split1) < 1:
        splice_indexes = "0"

    left_context=0
    right_context=0
    if label_delay is not None:
        left_context = -label_delay
        right_context = label_delay

    splice_array = []
    try:
        for i in range(len(split1)):
            indexes = map(lambda x: int(x), split1[i].strip().split(","))
            print(indexes)
            if len(indexes) < 1:
                raise ValueError("invalid --splice-indexes argument, too-short element: "
                                + splice_indexes)

            if (i > 0)  and ((len(indexes) != 1) or (indexes[0] != 0)):
                raise ValueError("elements of --splice-indexes splicing is only allowed initial layer.")

            if not indexes == sorted(indexes):
                raise ValueError("elements of --splice-indexes must be sorted: "
                                + splice_indexes)
            left_context += -indexes[0]
            right_context += indexes[-1]
            splice_array.append(indexes)
    except ValueError as e:
        raise ValueError("invalid --splice-indexes argument " + splice_indexes + str(e))

    left_context = max(0, left_context)
    right_context = max(0, right_context)

    return {'left_context':left_context,
            'right_context':right_context,
            'splice_indexes':splice_array,
            'num_hidden_layers':len(splice_array)
            }

def ParseLstmDelayString(lstm_delay):
    ## Work out lstm_delay e.g. "-1 [-1,1] -2" -> list([ [-1], [-1, 1], [-2] ])
    split1 = lstm_delay.split(" ");
    lstm_delay_array = []
    try:
        for i in range(len(split1)):
            indexes = map(lambda x: int(x), split1[i].strip().lstrip('[').rstrip(']').strip().split(","))
            if len(indexes) < 1:
                raise ValueError("invalid --lstm-delay argument, too-short element: "
                                + lstm_delay)
            elif len(indexes) == 2 and indexes[0] * indexes[1] >= 0:
                raise ValueError('Warning: ' + str(indexes) + ' is not a standard BLSTM mode. There should be a negative delay for the forward, and a postive delay for the backward.')
            if len(indexes) == 2 and indexes[0] > 0: # always a negative delay followed by a postive delay
                indexes[0], indexes[1] = indexes[1], indexes[0]
            lstm_delay_array.append(indexes)
    except ValueError as e:
        raise ValueError("invalid --lstm-delay argument " + lstm_delay + str(e))

    return lstm_delay_array

def AddOutputLayers(config_lines, prev_layer_output, output_nodes, ng_affine_options = "", label_delay = 0):

    for o in output_nodes:
        # make the intermediate config file for layerwise discriminative
        # training
        nodes.AddFinalLayer(config_lines, prev_layer_output, o.dim,
                            ng_affine_options, label_delay = label_delay,
                            include_log_softmax = o.include_log_softmax,
                            add_final_sigmoid = o.add_final_sigmoid,
                            objective_type = o.objective_type,
                            name_affix = o.output_suffix,
                            objective_scale = o.objective_scale)

        if o.xent_regularize != 0.0:
            nodes.AddFinalLayer(config_lines, prev_layer_output, o.dim,
                                include_log_softmax = True,
                                label_delay = label_delay,
                                name_affix = o.output_suffix + '_xent')

def MakeConfigs(config_dir, feat_dim, ivector_dim, add_lda,
                add_idct, cepstral_lifter,
                splice_indexes, lstm_delay, cell_dim, hidden_dim,
                recurrent_projection_dim, non_recurrent_projection_dim,
                num_lstm_layers, num_hidden_layers,
                norm_based_clipping, clipping_threshold,
                ng_per_element_scale_options, ng_affine_options,
                label_delay, output_nodes,
                self_repair_scale_nonlinearity, self_repair_scale_clipgradient):

    config_lines = {'components':[], 'component-nodes':[]}

    if add_idct:
        nnet3_train_lib.WriteIdctMatrix(feat_dim, cepstral_lifter, config_dir.strip() + "/idct.mat")

    config_files={}
    prev_layer_output = nodes.AddInputLayer(config_lines, feat_dim, splice_indexes[0],
                        ivector_dim,
                        idct_mat = config_dir.strip() + "/idct.mat" if add_idct else None)

    # Add the init config lines for estimating the preconditioning matrices
    init_config_lines = copy.deepcopy(config_lines)
    init_config_lines['components'].insert(0, '# Config file for initializing neural network prior to')
    init_config_lines['components'].insert(0, '# preconditioning matrix computation')

    for o in output_nodes:
        nodes.AddOutputLayer(init_config_lines, prev_layer_output, label_delay = label_delay, objective_type = o.objective_type, suffix = o.output_suffix)

    config_files[config_dir + '/init.config'] = init_config_lines

    # add_lda needs to be set "false" when using dense targets,
    # or if the task is not a simple classification task
    # (e.g. regression, multi-task)
    if add_lda:
        prev_layer_output = nodes.AddLdaLayer(config_lines, "L0", prev_layer_output, args.config_dir + '/lda.mat')

    for i in range(num_lstm_layers):
        if len(lstm_delay[i]) == 2: # add a bi-directional LSTM layer
            prev_layer_output = nodes.AddBLstmLayer(config_lines, "BLstm{0}".format(i+1),
                                                    prev_layer_output, cell_dim,
                                                    recurrent_projection_dim, non_recurrent_projection_dim,
                                                    clipping_threshold, norm_based_clipping,
                                                    ng_per_element_scale_options, ng_affine_options,
                                                    lstm_delay = lstm_delay[i], self_repair_scale_nonlinearity = self_repair_scale_nonlinearity, self_repair_scale_clipgradient = self_repair_scale_clipgradient)
        else: # add a uni-directional LSTM layer
            prev_layer_output = nodes.AddLstmLayer(config_lines, "Lstm{0}".format(i+1),
                                                   prev_layer_output, cell_dim,
                                                   recurrent_projection_dim, non_recurrent_projection_dim,
                                                   clipping_threshold, norm_based_clipping,
                                                   ng_per_element_scale_options, ng_affine_options,
                                                   lstm_delay = lstm_delay[i][0], self_repair_scale_nonlinearity = self_repair_scale_nonlinearity, self_repair_scale_clipgradient = self_repair_scale_clipgradient)

        AddOutputLayers(config_lines, prev_layer_output, output_nodes,
                        ng_affine_options, label_delay = label_delay)

        config_files['{0}/layer{1}.config'.format(config_dir, i+1)] = config_lines
        config_lines = {'components':[], 'component-nodes':[]}

    for i in range(num_lstm_layers, num_hidden_layers):
        prev_layer_output = nodes.AddAffRelNormLayer(config_lines, "L{0}".format(i+1),
                                               prev_layer_output, hidden_dim,
                                               ng_affine_options, self_repair_scale = self_repair_scale_nonlinearity)

        AddOutputLayers(confile_lines, prev_layer_output, output_nodes,
                        ng_affine_options, label_delay = label_delay)

        config_files['{0}/layer{1}.config'.format(config_dir, i+1)] = config_lines
        config_lines = {'components':[], 'component-nodes':[]}

    # printing out the configs
    # init.config used to train lda-mllt train
    for key in config_files.keys():
        PrintConfig(key, config_files[key])




def ProcessSpliceIndexes(config_dir, splice_indexes, label_delay, num_lstm_layers):
    parsed_splice_output = ParseSpliceString(splice_indexes.strip(), label_delay)
    left_context = parsed_splice_output['left_context']
    right_context = parsed_splice_output['right_context']
    num_hidden_layers = parsed_splice_output['num_hidden_layers']
    splice_indexes = parsed_splice_output['splice_indexes']

    if (num_hidden_layers < num_lstm_layers):
        raise Exception("num-lstm-layers : number of lstm layers has to be greater than number of layers, decided based on splice-indexes")

    return [left_context, right_context, num_hidden_layers, splice_indexes]

def ParseOutputNodesParameters(para_array):
    output_parser = argparse.ArgumentParser()
    output_parser.add_argument('--output-suffix', type=str, action=nnet3_train_lib.NullstrToNoneAction,
                                help = "Name of the output node. e.g. output-xent")
    output_parser.add_argument('--dim', type=int, required=True,
                                help = "Dimension of the output node")
    output_parser.add_argument("--include-log-softmax", type=str, action=nnet3_train_lib.StrToBoolAction,
                        help="add the final softmax layer ", default=True, choices = ["false", "true"])
    output_parser.add_argument("--add-final-sigmoid", type=str, action=nnet3_train_lib.StrToBoolAction,
                        help="add a sigmoid layer as the final layer. Applicable only if skip-final-softmax is true.",
                        choices=['true', 'false'], default = False)
    output_parser.add_argument("--objective-type", type=str, default="linear",
                        choices = ["linear", "quadratic","xent-per-dim"],
                        help = "the type of objective; i.e. quadratic or linear")
    output_parser.add_argument("--xent-regularize", type=float,
                               help="For chain models, if nonzero, add a separate output for cross-entropy "
                               "regularization (with learning-rate-factor equal to the inverse of this)",
                               default=0.0)
    output_parser.add_argument("--objective-scale", type=float,
                               help="Scale the gradients by this value",
                               default=1.0)

    output_nodes = [ output_parser.parse_args(shlex.split(x)) for x in para_array ]

    return output_nodes

def Main():
    args = GetArgs()
    [left_context, right_context, num_hidden_layers, splice_indexes] = ProcessSpliceIndexes(args.config_dir, args.splice_indexes, args.label_delay, args.num_lstm_layers)

    # write the files used by other scripts like steps/nnet3/get_egs.sh
    f = open(args.config_dir + "/vars", "w")
    print('model_left_context=' + str(left_context), file=f)
    print('model_right_context=' + str(right_context), file=f)
    print('num_hidden_layers=' + str(num_hidden_layers), file=f)
    print('add_lda=' + ("true" if args.add_lda else "false"), file=f)
    f.close()

    output_nodes = ParseOutputNodesParameters(args.output_node_para_array)

    MakeConfigs(config_dir = args.config_dir,
                feat_dim = args.feat_dim, ivector_dim = args.ivector_dim,
                add_lda = args.add_lda,
                add_idct = args.add_idct, cepstral_lifter = args.cepstral_lifter,
                splice_indexes = splice_indexes, lstm_delay = args.lstm_delay,
                cell_dim = args.cell_dim,
                hidden_dim = args.hidden_dim,
                recurrent_projection_dim = args.recurrent_projection_dim,
                non_recurrent_projection_dim = args.non_recurrent_projection_dim,
                num_lstm_layers = args.num_lstm_layers,
                num_hidden_layers = num_hidden_layers,
                norm_based_clipping = args.norm_based_clipping,
                clipping_threshold = args.clipping_threshold,
                ng_per_element_scale_options = args.ng_per_element_scale_options,
                ng_affine_options = args.ng_affine_options,
                label_delay = args.label_delay,
                output_nodes = output_nodes,
                self_repair_scale_nonlinearity = args.self_repair_scale_nonlinearity,
                self_repair_scale_clipgradient = args.self_repair_scale_clipgradient)

if __name__ == "__main__":
    Main()
