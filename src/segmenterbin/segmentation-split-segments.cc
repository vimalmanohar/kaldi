// segmenterbin/segmentation-split-segments.cc

// Copyright 2016   Vimal Manohar (Johns Hopkins University)

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
#include "segmenter/segmenter.h"

int main(int argc, char *argv[]) {
  try {
    using namespace kaldi;
    using namespace segmenter;

    const char *usage =
        "Split segmentation optionally using alignment.\n"
        "Usage: segmentation-split-segments [options] (segmentation-in-rspecifier|segmentation-in-rxfilename) (segmentation-out-wspecifier|segmentation-out-wxfilename)\n"
        " e.g.: segmentation-split-segments --binary=false foo -\n"
        "       segmentation-split-segments ark:1.seg ark,t:-\n"
        "See also: segmentation-post-process\n";
    
    bool binary = true;
    int32 max_segment_length = -1;
    int32 overlap_length = 0;
    int32 split_label = -1;
    int32 ali_label = 0;
    int32 min_alignment_segment_length = 2;
    std::string alignments_in_fn;

    ParseOptions po(usage);
    
    po.Register("binary", &binary, 
                "Write in binary mode (only relevant if output is a wxfilename)");
    po.Register("alignments", &alignments_in_fn,
                "Alignments used for splitting");
    po.Register("ali-label", &ali_label,
                "Split at this label of alignments");
    po.Register("max-segment-length", &max_segment_length, 
                "If segment is longer than this length, split it into "
                "pieces with less than these many frames. "
                "Refer to the SplitSegments() code for details. "
                "Used in conjunction with the option --overlap-length.");
    po.Register("overlap-length", &overlap_length,
                "When splitting segments longer than max-segment-length, "
                "have the pieces overlap by these many frames. "
                "Refer to the SplitSegments() code for details. "
                "Used in conjunction with the option --max-segment-length.");
    po.Register("split-label", &split_label,
                "If supplied, split only segments of these labels");
    po.Register("min-alignment-segment-length", &min_alignment_segment_length,
                "The minimum length of alignment segment at which "
                "to split the segments");

    po.Read(argc, argv); 
    if (po.NumArgs() != 2) {
      po.PrintUsage();
      exit(1);
    }
    
    std::string segmentation_in_fn = po.GetArg(1),
                segmentation_out_fn = po.GetArg(2);

    bool in_is_rspecifier =
        (ClassifyRspecifier(segmentation_in_fn, NULL, NULL)
         != kNoRspecifier),
        out_is_wspecifier =
        (ClassifyWspecifier(segmentation_out_fn, NULL, NULL, NULL)
         != kNoWspecifier);

    if (in_is_rspecifier != out_is_wspecifier)
      KALDI_ERR << "Cannot mix regular files and archives";
    
    int64 num_done = 0, num_err = 0;
    
    if (!in_is_rspecifier) {
      std::vector<int32> ali;

      Segmentation seg;
      {
        bool binary_in;
        Input ki(segmentation_in_fn, &binary_in);
        seg.Read(ki.Stream(), binary_in);
      }


      if (!alignments_in_fn.empty()) {
        {
          bool binary_in;
          Input ki(alignments_in_fn, &binary_in);
          ReadIntegerVector(ki.Stream(), binary_in, &ali);
        }
        seg.SplitSegmentsUsingAlignment(max_segment_length, 
                                        max_segment_length / 2,
                                        split_label, ali, ali_label,            
                                        min_alignment_segment_length);
      } else {
        seg.SplitSegments(max_segment_length, max_segment_length / 2,
                          overlap_length, split_label);
      }

      {
        Output ko(segmentation_out_fn, binary);
        seg.Sort();
        seg.Write(ko.Stream(), binary);
      } 
      
      KALDI_LOG << "Split segmentation " << segmentation_in_fn 
                << " and wrote " << segmentation_out_fn;
      return 0;
    }

    SegmentationWriter writer(segmentation_out_fn); 
    SequentialSegmentationReader reader(segmentation_in_fn);
    RandomAccessInt32VectorReader ali_reader(alignments_in_fn);

    for (; !reader.Done(); reader.Next()){
      Segmentation seg(reader.Value());
      const std::string &key = reader.Key();
      
      if (!alignments_in_fn.empty()) {
        if (!ali_reader.HasKey(key)) {
          KALDI_WARN << "Could not find key " << key 
                     << " in alignments " << alignments_in_fn;
          num_err++;
          continue;
        }
        seg.SplitSegmentsUsingAlignment(max_segment_length, 
                                        max_segment_length / 2,
                                        split_label, 
                                        ali_reader.Value(key),
                                        ali_label);
      } else {
        seg.SplitSegments(max_segment_length, max_segment_length / 2,
                          overlap_length, split_label);
      }

      seg.Sort();
      writer.Write(key, seg);
      num_done++;
    }

    KALDI_LOG << "Successfully split " << num_done 
              << " segmentations; "
              << "failed with " << num_err << " segmentations";
    return (num_done != 0 ? 0 : 1);
  } catch(const std::exception &e) {
    std::cerr << e.what();
    return -1;
  }
}
