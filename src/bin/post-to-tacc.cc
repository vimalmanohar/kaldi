// bin/post-to-tacc.cc

// Copyright 2009-2011 Chao Weng  Microsoft Corporation
//           2015   Minhua Wu

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
#include "hmm/transition-model.h"
#include "hmm/posterior.h"

int main(int argc, char *argv[]) {
  try {
    using namespace kaldi;
    typedef kaldi::int32 int32;  

    const char *usage =
        "From posteriors, compute transition-accumulators\n"
        "The output is a vector of counts/soft-counts, indexed by transition-id)\n"
        "Note: the model is only read in order to get the size of the vector\n"
        "\n"
        "Usage: post-to-tacc [options] <model> <post-rspecifier> <accs>\n"
        " e.g.: post-to-tacc --binary=false 1.mdl \"ark:ali-to-post 1.ali|\" 1.tacc\n";

    bool binary = true;
    bool per_pdf = false;
    int32 num_targets = -1;

    ParseOptions po(usage);
    po.Register("binary", &binary, "Write output in binary mode.");
    po.Register("per-pdf", &per_pdf, "if true, accumulate counts per pdf-id"
                " rather than transition-id. (default: false)");
    po.Register("num-targets", &num_targets, "number of targets; useful when "
                "there is no transition model.");
    po.Read(argc, argv);

    if (po.NumArgs() != 3) && (po.NumArgs() != 2) {
      po.PrintUsage();
      exit(1);
    }
      
    int32 N = po.NumArgs();

    std::string model_rxfilename,
        post_rspecifier = po.GetArg(N-1),
        accs_wxfilename = po.GetArg(N);

     
    if (N == 3) 
      model_rxfilename = po.GetArg(1);
    else 
      KALDI_ASSERT(num_targets > 0 && !per_pdf);

    kaldi::SequentialPosteriorReader posterior_reader(post_rspecifier);
    
    int32 num_transition_ids = 0;
    
    TransitionModel *trans_model = NULL;
    
    if (N == 3) {
      bool binary_in;
      Input ki(model_rxfilename, &binary_in);
      trans_model = new TransitionModel;
      trans_model->Read(ki.Stream(), binary_in);
      num_transition_ids = trans_model->NumTransitionIds();
    }
    
    Vector<double> accs(trans_model ? num_transition_ids+1 : num_targets); 
    // +1 because tids 1-based; position zero is empty.  
    int32 num_done = 0;      
    
    for (; !posterior_reader.Done(); posterior_reader.Next()) {
      const kaldi::Posterior &posterior = posterior_reader.Value();
      int32 num_frames = static_cast<int32>(posterior.size());
      for (int32 i = 0; i < num_frames; i++) {
        for (int32 j = 0; j < static_cast<int32>(posterior[i].size()); j++) {
          int32 id = posterior[i][j].first;
          if (num_targets < 0 && (id <= 0 || id > num_transition_ids) )
            KALDI_ERR << "Invalid transition-id " << id
                      << " encountered for utterance "
                      << posterior_reader.Key();
          else if (num_targets >= 0 && (id < 0 || id > num_targets)) 
            KALDI_ERR << "Invalid target " << id
                      << " encountered for utterance "
                      << posterior_reader.Key();
          accs(id) += posterior[i][j].second;
        }
      }
      num_done++;
    }

    if (per_pdf) {
      KALDI_LOG << "accumulate counts per pdf-id";
      int32 num_pdf_ids = trans_model->NumPdfs();
      Vector<double> pdf_accs(num_pdf_ids);
      for (int32 i = 1; i < num_transition_ids; i++) {
        int32 pid = trans_model->TransitionIdToPdf(i);
        pdf_accs(pid) += accs(i);
      }
      Vector<BaseFloat> pdf_accs_float(pdf_accs);
      Output ko(accs_wxfilename, binary);
      pdf_accs_float.Write(ko.Stream(), binary);
    } else {
      Vector<BaseFloat> accs_float(accs);
      Output ko(accs_wxfilename, binary);
      accs_float.Write(ko.Stream(), binary);
    }
    KALDI_LOG << "Done accumulating stats over "
              << num_done << " utterances; wrote stats to "
              << accs_wxfilename;
    return (num_done != 0 ? 0 : 1);
  } catch(const std::exception &e) {
    std::cerr << e.what();
    return -1;
  }
}

