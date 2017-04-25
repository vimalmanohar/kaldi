// simplehmmbin/simple-hmm-align-compiled.cc

// Copyright 2009-2013  Microsoft Corporation
//                      Johns Hopkins University (author: Daniel Povey)
//                2016  Vimal Manohar


// See ../../COPYING for clarification regarding multiple authors
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//  http://www.apache.org/licenses/LICENSE-2.0
//
// THIS CODE IS PROVIDED *AS IS* BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY
// KIND, EITHER EXPRESS OR IMPLIED, INCLUDING WITHOUT LIMITATION ANY IMPLIED
// WARRANTIES OR CONDITIONS OF TITLE, FITNESS FOR A PARTICULAR PURPOSE,
// MERCHANTABLITY OR NON-INFRINGEMENT.
// See the Apache 2 License for the specific language governing permissions and
// limitations under the License.

#include "base/kaldi-common.h"
#include "util/common-utils.h"
#include "simplehmm/simple-hmm.h"
#include "simplehmm/simple-hmm-utils.h"
#include "fstext/fstext-lib.h"
#include "decoder/decoder-wrappers.h"
#include "decoder/decodable-matrix.h"

int main(int argc, char *argv[]) {
  try {
    using namespace kaldi;
    typedef kaldi::int32 int32;
    using fst::SymbolTable;
    using fst::VectorFst;
    using fst::StdArc;

    const char *usage =
        "Align matrix of log-likelihoods given simple HMM model.\n"
        "Usage:   simple-hmm-align-compiled [options] <model-in> <graphs-rspecifier> "
        "<loglikes-rspecifier> <alignments-wspecifier> [<scores-wspecifier>]\n"
        "e.g.: \n"
        " simple-hmm-align-compiled 1.mdl ark:graphs.fsts ark:log_likes.1.ark ark:1.ali\n";

    ParseOptions po(usage);
    AlignConfig align_config;
    BaseFloat acoustic_scale = 1.0;
    BaseFloat transition_scale = 1.0;
    BaseFloat self_loop_scale = 1.0;

    align_config.Register(&po);
    po.Register("transition-scale", &transition_scale,
                "Transition-probability scale [relative to acoustics]");
    po.Register("acoustic-scale", &acoustic_scale,
                "Scaling factor for acoustic likelihoods");
    po.Register("self-loop-scale", &self_loop_scale,
                "Scale of self-loop versus non-self-loop log probs [relative to acoustics]");
    po.Read(argc, argv);

    if (po.NumArgs() < 4 || po.NumArgs() > 5) {
      po.PrintUsage();
      exit(1);
    }
    
    std::string model_in_filename = po.GetArg(1),
        fst_rspecifier = po.GetArg(2),
        loglikes_rspecifier = po.GetArg(3),
        alignment_wspecifier = po.GetArg(4),
        scores_wspecifier = po.GetOptArg(5);

    SimpleHmm model;
    ReadKaldiObject(model_in_filename, &model);

    SequentialTableReader<fst::VectorFstHolder> fst_reader(fst_rspecifier);
    RandomAccessBaseFloatMatrixReader loglikes_reader(loglikes_rspecifier);
    Int32VectorWriter alignment_writer(alignment_wspecifier);
    BaseFloatWriter scores_writer(scores_wspecifier);

    int32 num_done = 0, num_err = 0, num_retry = 0;
    double tot_like = 0.0;
    kaldi::int64 frame_count = 0;

    for (; !fst_reader.Done(); fst_reader.Next()) {
      const std::string &utt = fst_reader.Key();
      if (!loglikes_reader.HasKey(utt)) {
        num_err++;
        KALDI_WARN << "No loglikes for utterance " << utt;
      } else {
        const Matrix<BaseFloat> &loglikes = loglikes_reader.Value(utt);
        VectorFst<StdArc> decode_fst(fst_reader.Value());
        fst_reader.FreeCurrent();  // this stops copy-on-write of the fst
        // by deleting the fst inside the reader, since we're about to mutate
        // the fst by adding transition probs.

        if (loglikes.NumRows() == 0) {
          KALDI_WARN << "Zero-length utterance: " << utt;
          num_err++;
          continue;
        }

        {  // Add transition-probs to the FST.
          std::vector<int32> disambig_syms;  // empty
          AddTransitionProbs(model, disambig_syms, transition_scale, 
                             self_loop_scale, &decode_fst);
        }

        DecodableMatrixScaledMapped decodable(model, loglikes, acoustic_scale);
         
        AlignUtteranceWrapper(align_config, utt,
                              acoustic_scale, &decode_fst, 
                              &decodable,
                              &alignment_writer, &scores_writer,
                              &num_done, &num_err, &num_retry,
                              &tot_like, &frame_count);
      }
    }
    KALDI_LOG << "Overall log-likelihood per frame is " 
              << (tot_like/frame_count)
              << " over " << frame_count<< " frames.";
    KALDI_LOG << "Retried " << num_retry << " out of "
              << (num_done + num_err) << " utterances.";
    KALDI_LOG << "Done " << num_done << ", errors on " << num_err;
    return (num_done != 0 ? 0 : 1);
  } catch(const std::exception &e) {
    std::cerr << e.what();
    return -1;
  }
}

