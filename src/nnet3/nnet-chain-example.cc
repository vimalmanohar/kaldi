// nnet3/nnet-chain-example.cc

// Copyright      2015    Johns Hopkins University (author: Daniel Povey)

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

#include <cmath>
#include "nnet3/nnet-chain-example.h"
#include "nnet3/nnet-example-utils.h"

namespace kaldi {
namespace nnet3 {


// writes compressed as unsigned char a vector 'vec' that is required to have
// values between 0 and 1.
static inline void WriteVectorAsChar(std::ostream &os,
                                     bool binary,
                                     const VectorBase<BaseFloat> &vec) {
  if (binary) {
    int32 dim = vec.Dim();
    std::vector<unsigned char> char_vec(dim);
    const BaseFloat *data = vec.Data();
    for (int32 i = 0; i < dim; i++) {
      BaseFloat value = data[i];
      KALDI_ASSERT(value >= 0.0 && value <= 1.0);
      // below, the adding 0.5 is done so that we round to the closest integer
      // rather than rounding down (since static_cast will round down).
      char_vec[i] = static_cast<unsigned char>(255.0 * value + 0.5);
    }
    WriteIntegerVector(os, binary, char_vec);
  } else {
    // the regular floating-point format will be more readable for text mode.
    vec.Write(os, binary);
  }
}

// reads data written by WriteVectorAsChar.
static inline void ReadVectorAsChar(std::istream &is,
                                    bool binary,
                                    Vector<BaseFloat> *vec) {
  if (binary) {
    BaseFloat scale = 1.0 / 255.0;
    std::vector<unsigned char> char_vec;
    ReadIntegerVector(is, binary, &char_vec);
    int32 dim = char_vec.size();
    vec->Resize(dim, kUndefined);
    BaseFloat *data = vec->Data();
    for (int32 i = 0; i < dim; i++)
      data[i] = scale * char_vec[i];
  } else {
    vec->Read(is, binary);
  }
}



void NnetChainSupervision::Write(std::ostream &os, bool binary) const {
  CheckDim();
  WriteToken(os, binary, "<NnetChainSup>");
  WriteToken(os, binary, name);
  WriteIndexVector(os, binary, indexes);
  supervision.Write(os, binary);
  WriteToken(os, binary, "<DW>");  // for DerivWeights.  Want to save space.
  WriteVectorAsChar(os, binary, deriv_weights);
  WriteToken(os, binary, "</NnetChainSup>");
}

bool NnetChainSupervision::operator == (const NnetChainSupervision &other) const {
  return name == other.name && indexes == other.indexes &&
      supervision == other.supervision &&
      deriv_weights.ApproxEqual(other.deriv_weights);
}
bool NnetChainExample::operator == (const NnetChainExample &other) const {
  if (!(inputs == other.inputs))
    return false;
  std::vector<NnetSupervision>::const_iterator this_iter = outputs.begin(),
    other_iter = other.outputs.begin(),
    end = outputs.end();
  for (;this_iter != end; ++this_iter, ++other_iter) {
    if (dynamic_cast<const NnetChainSupervision*>(&(*this_iter))) {
     const NnetChainSupervision* other_chain_sup = dynamic_cast<const NnetChainSupervision*>(&(*other_iter)),
      *this_chain_sup = dynamic_cast<const NnetChainSupervision*>(&(*this_iter));
     if (!((*other_chain_sup) == (*this_chain_sup)))
       return false;
    } else if(dynamic_cast<const NnetIo*>(&(*this_iter)))  {
     const NnetIo* other_chain_sup = dynamic_cast<const NnetIo*>(&(*other_iter)),
      *this_chain_sup = dynamic_cast<const NnetIo*>(&(*this_iter));
      if (!((*other_chain_sup) == (*this_chain_sup)))
        return false;
    }
  }
  return true;
}
void NnetChainSupervision::Read(std::istream &is, bool binary) {
  ExpectToken(is, binary, "<NnetChainSup>");
  ReadToken(is, binary, &name);
  ReadIndexVector(is, binary, &indexes);
  supervision.Read(is, binary);
  std::string token;
  ReadToken(is, binary, &token);
  // in the future this back-compatibility code can be reworked.
  if (token != "</NnetChainSup>") {
    KALDI_ASSERT(token == "<DW>");
    ReadVectorAsChar(is, binary, &deriv_weights);
    ExpectToken(is, binary, "</NnetChainSup>");
  }
  CheckDim();
}


void NnetChainSupervision::CheckDim() const {
  if (supervision.frames_per_sequence == -1) {
    // this object has not been set up.
    KALDI_ASSERT(indexes.empty());
    return;
  }
  KALDI_ASSERT(indexes.size() == supervision.num_sequences *
               supervision.frames_per_sequence && !indexes.empty() &&
               supervision.frames_per_sequence > 1);
  int32 first_frame = indexes[0].t,
      frame_skip = indexes[supervision.num_sequences].t - first_frame,
      num_sequences = supervision.num_sequences,
      frames_per_sequence = supervision.frames_per_sequence;
  int32 k = 0;
  for (int32 i = 0; i < frames_per_sequence; i++) {
    for (int32 j = 0; j < num_sequences; j++,k++) {
      int32 n = j, t = i * frame_skip + first_frame, x = 0;
      Index index(n, t, x);
      KALDI_ASSERT(indexes[k] == index);
    }
  }
  if (deriv_weights.Dim() != 0) {
    KALDI_ASSERT(deriv_weights.Dim() == indexes.size());
    KALDI_ASSERT(deriv_weights.Min() >= 0.0 &&
                 deriv_weights.Max() <= 1.0);
  }
}

NnetChainSupervision::NnetChainSupervision(const NnetChainSupervision &other): 
    NnetSupervision(other.name, other.indexes),
    supervision(other.supervision),
    deriv_weights(other.deriv_weights) { CheckDim(); }

void NnetChainSupervision::Swap(NnetChainSupervision *other) {
  name.swap(other->name);
  indexes.swap(other->indexes);
  supervision.Swap(&(other->supervision));
  deriv_weights.Swap(&(other->deriv_weights));
  if (RandInt(0, 5) == 0)
    CheckDim();
}

NnetChainSupervision::NnetChainSupervision(
    const std::string &name,
    const chain::Supervision &supervision,
    const Vector<BaseFloat> &deriv_weights,
    int32 first_frame,
    int32 frame_skip):
    NnetSupervision(name),
    supervision(supervision),
    deriv_weights(deriv_weights) {
  // note: this will set the 'x' index to zero.
  indexes.resize(supervision.num_sequences *
                 supervision.frames_per_sequence);
  int32 k = 0, num_sequences = supervision.num_sequences,
      frames_per_sequence = supervision.frames_per_sequence;
  for (int32 i = 0; i < frames_per_sequence; i++) {
    for (int32 j = 0; j < num_sequences; j++,k++) {
      indexes[k].n = j;
      indexes[k].t = i * frame_skip + first_frame;
    }
  }
  KALDI_ASSERT(k == indexes.size());
  CheckDim();
}


void NnetChainExample::Write(std::ostream &os, bool binary) const {
  // Note: weight, label, input_frames and spk_info are members.  This is a
  // struct.
  WriteToken(os, binary, "<Nnet3ChainEg>");
  WriteToken(os, binary, "<NumInputs>");
  int32 size = inputs.size();
  WriteBasicType(os, binary, size);
  KALDI_ASSERT(size > 0 && "Attempting to write NnetChainExample with no inputs");
  if (!binary) os << '\n';
  for (int32 i = 0; i < size; i++) {
    inputs[i].Write(os, binary);
    if (!binary) os << '\n';
  }
  WriteToken(os, binary, "<NumOutputs>");
  size = outputs.size();
  WriteBasicType(os, binary, size);
  KALDI_ASSERT(size > 0 && "Attempting to write NnetChainExample with no outputs");
  if (!binary) os << '\n';
  for (int32 i = 0; i < size; i++) {
    outputs[i].Write(os, binary);
    if (!binary) os << '\n';
  }
  WriteToken(os, binary, "</Nnet3ChainEg>");
}

void NnetChainExample::Read(std::istream &is, bool binary) {
  ExpectToken(is, binary, "<Nnet3ChainEg>");
  ExpectToken(is, binary, "<NumInputs>");
  int32 size;
  ReadBasicType(is, binary, &size);
  if (size < 1 || size > 1000000)
    KALDI_ERR << "Invalid size " << size;
  inputs.resize(size);
  for (int32 i = 0; i < size; i++)
    inputs[i].Read(is, binary);
  ExpectToken(is, binary, "<NumOutputs>");
  ReadBasicType(is, binary, &size);
  if (size < 1 || size > 1000000)
    KALDI_ERR << "Invalid size " << size;
  outputs.resize(size);
  for (int32 i = 0; i < size; i++)
    outputs[i].Read(is, binary);
  ExpectToken(is, binary, "</Nnet3ChainEg>");
}

void NnetChainExample::Swap(NnetChainExample *other) {
  inputs.swap(other->inputs);
  outputs.swap(other->outputs);
}

void NnetChainExample::Compress() {
  std::vector<NnetIo>::iterator iter = inputs.begin(), end = inputs.end();
  // calling features.Compress() will do nothing if they are sparse or already
  // compressed.
  for (; iter != end; ++iter) iter->features.Compress();
}

NnetChainExample::NnetChainExample(const NnetChainExample &other):
    inputs(other.inputs), outputs(other.outputs) { }


// called from MergeChainExamplesInternal, this function merges the Supervision
// objects into one.  Requires (and checks) that they all have the same name.
static void MergeSupervision(
    const std::vector<const NnetChainSupervision*> &inputs,
    NnetChainSupervision *output) {
  int32 num_inputs = inputs.size(),
      num_indexes = 0;
  for (int32 n = 0; n < num_inputs; n++) {
    KALDI_ASSERT(inputs[n]->name == inputs[0]->name);
    num_indexes += inputs[n]->indexes.size();
  }
  output->name = inputs[0]->name;
  std::vector<const chain::Supervision*> input_supervision;
  input_supervision.reserve(inputs.size());
  for (int32 n = 0; n < num_inputs; n++)
    input_supervision.push_back(&(inputs[n]->supervision));
  std::vector<chain::Supervision> output_supervision;
  bool compactify = true;
  AppendSupervision(input_supervision,
                         compactify,
                         &output_supervision);
  if (output_supervision.size() != 1)
    KALDI_ERR << "Failed to merge 'chain' examples-- inconsistent lengths "
              << "or weights?";
  output->supervision.Swap(&(output_supervision[0]));

  output->indexes.clear();
  output->indexes.reserve(num_indexes);
  for (int32 n = 0; n < num_inputs; n++) {
    const std::vector<Index> &src_indexes = inputs[n]->indexes;
    int32 cur_size = output->indexes.size();
    output->indexes.insert(output->indexes.end(),
                           src_indexes.begin(), src_indexes.end());
    std::vector<Index>::iterator iter = output->indexes.begin() + cur_size,
        end = output->indexes.end();
    // change the 'n' index to correspond to the index into 'input'.
    // Each example gets a different 'n' value, starting from 0.
    for (; iter != end; ++iter) {
      KALDI_ASSERT(iter->n == 0 && "Merging already-merged chain egs");
      iter->n = n;
    }
  }
  KALDI_ASSERT(output->indexes.size() == num_indexes);
  // OK, at this point the 'indexes' will be in the wrong order,
  // because they should be first sorted by 't' and next by 'n'.
  // 'sort' will fix this, due to the operator < on type Index.
  std::sort(output->indexes.begin(), output->indexes.end());

  // merge the deriv_weights.
  if (inputs[0]->deriv_weights.Dim() != 0) {
    int32 frames_per_sequence = inputs[0]->deriv_weights.Dim();
    output->deriv_weights.Resize(output->indexes.size(), kUndefined);
    KALDI_ASSERT(output->deriv_weights.Dim() ==
                 frames_per_sequence * num_inputs);
    for (int32 n = 0; n < num_inputs; n++) {
      const Vector<BaseFloat> &src_deriv_weights = inputs[n]->deriv_weights;
      KALDI_ASSERT(src_deriv_weights.Dim() == frames_per_sequence);
      // the ordering of the deriv_weights corresponds to the ordering of the
      // Indexes, where the time dimension has the greater stride.
      for (int32 t = 0; t < frames_per_sequence; t++) {
        output->deriv_weights(t * num_inputs + n) = src_deriv_weights(t);
      }
    }
  }
  output->CheckDim();
}


void MergeChainExamples(bool compress,
                        std::vector<NnetChainExample> *input,
                        NnetChainExample *output) {
  int32 num_examples = input->size();
  KALDI_ASSERT(num_examples > 0);
  // we temporarily make the input-features in 'input' look like regular NnetExamples,
  // so that we can recycle the MergeExamples() function.
  std::vector<NnetExample> eg_inputs(num_examples);
  for (int32 i = 0; i < num_examples; i++)
    eg_inputs[i].io.swap((*input)[i].inputs);
  NnetExample eg_output;
  MergeExamples(eg_inputs, compress, &eg_output);
  // swap the inputs back so that they are not really changed.
  for (int32 i = 0; i < num_examples; i++)
    eg_inputs[i].io.swap((*input)[i].inputs);
  // write to 'output->inputs'
  eg_output.io.swap(output->inputs);

  // Now deal with the supervision 'outputs' such as ChainSupervision or NnetIo.  There will
  // normally be just one of ChainSupervision 'output', with name "output", but we
  // handle the more general case.
  int32 num_output_names = (*input)[0].outputs.size();
  output->outputs.resize(num_output_names);
  for (int32 i = 0; i < num_output_names; i++) {
    if (dynamic_cast<NnetChainSupervision*>(&((*input)[0].outputs[i]))) {
      std::vector<const NnetChainSupervision*> to_merge(num_examples);
      for (int32 j = 0; j < num_examples; j++) {
        KALDI_ASSERT((*input)[j].outputs.size() == num_output_names);

        to_merge[j] = dynamic_cast<NnetChainSupervision*>(&((*input)[j].outputs[i]));
      }
      NnetChainSupervision* chain_output = dynamic_cast<NnetChainSupervision*>(&(output->outputs[i]));
      MergeSupervision(to_merge,
                       chain_output);
    } else if (dynamic_cast<NnetIo*>(&((*input)[0].outputs[i]))) {
      // we temporarily make the examples like regular NnetExamples, 
      // and we use MergeExample() function to merge NnetIo type outputs.
      std::vector<NnetExample> eg_io_output(num_examples);
      for (int32 j = 0; j < num_examples; j++) {
        NnetIo* io_out = dynamic_cast<NnetIo*>(&((*input)[j].outputs[i]));
        eg_io_output[i].io[0].Swap(io_out);
      }
      NnetExample eg_merged_output;
      MergeExamples(eg_io_output, compress, &eg_merged_output);
      // write to 'input->outputs'
      NnetIo* io_output = dynamic_cast<NnetIo*>(&(output->outputs[i]));
      eg_merged_output.io[0].Swap((io_output));
    }
  }
}

void TruncateDerivWeights(int32 truncate,
                          NnetChainExample *eg) {
  for (size_t i = 0; i < eg->outputs.size(); i++) {
    if (dynamic_cast<NnetChainSupervision*>(&eg->outputs[i])) {
      NnetChainSupervision* chain_eg = dynamic_cast<NnetChainSupervision*>(&(eg->outputs[i]));
      Vector<BaseFloat> &deriv_weights = chain_eg->deriv_weights;
      if (deriv_weights.Dim() == 0) {
        deriv_weights.Resize(chain_eg->indexes.size());
        deriv_weights.Set(1.0);
      }
      int32 num_sequences = chain_eg->supervision.num_sequences,
         frames_per_sequence = chain_eg->supervision.frames_per_sequence;
      KALDI_ASSERT(2 * truncate  < frames_per_sequence);
      for (int32 t = 0; t < truncate; t++)
        for (int32 s = 0; s < num_sequences; s++)
          deriv_weights(t * num_sequences + s) = 0.0;
      for (int32 t = frames_per_sequence - truncate;
           t < frames_per_sequence; t++)
        for (int32 s = 0; s < num_sequences; s++)
          deriv_weights(t * num_sequences + s) = 0.0;
    }
  }
}

void GetChainComputationRequest(const Nnet &nnet,
                                const NnetChainExample &eg,
                                bool need_model_derivative,
                                bool store_component_stats,
                                ComputationRequest *request) {
  request->inputs.clear();
  request->inputs.reserve(eg.inputs.size());
  request->outputs.clear();
  request->outputs.reserve(eg.outputs.size());
  request->need_model_derivative = need_model_derivative;
  request->store_component_stats = store_component_stats;
  for (size_t i = 0; i < eg.inputs.size(); i++) {
    const NnetIo &io = eg.inputs[i];
    const std::string &name = io.name;
    int32 node_index = nnet.GetNodeIndex(name);
    if (node_index == -1 &&
        !nnet.IsInputNode(node_index))
      KALDI_ERR << "Nnet example has input named '" << name
                << "', but no such input node is in the network.";

    request->inputs.resize(request->inputs.size() + 1);
    IoSpecification &io_spec = request->inputs.back();
    io_spec.name = name;
    io_spec.indexes = io.indexes;
    io_spec.has_deriv = false;
  }
  for (size_t i = 0; i < eg.outputs.size(); i++) {
    // there will normally be exactly one output , named "output"
    // The output has two types as NnetChainSupervision and NnetIo.
    const NnetSupervision &sup = eg.outputs[i];
    const std::string &name = sup.name;
    int32 node_index = nnet.GetNodeIndex(name);
    if (node_index == -1 &&
        !nnet.IsOutputNode(node_index))
      KALDI_ERR << "Nnet example has output named '" << name
                << "', but no such output node is in the network.";
    request->outputs.resize(request->outputs.size() + 1);
    IoSpecification &io_spec = request->outputs.back();
    io_spec.name = name;
    io_spec.indexes = sup.indexes;
    io_spec.has_deriv = nnet.IsOutputNode(node_index) && need_model_derivative;
  }
  // check to see if something went wrong.
  if (request->inputs.empty())
    KALDI_ERR << "No inputs in computation request.";
  if (request->outputs.empty())
    KALDI_ERR << "No outputs in computation request.";
}

void ShiftChainExampleTimes(int32 frame_shift,
                            const std::vector<std::string> &exclude_names,
                            NnetChainExample *eg) {
  std::vector<NnetIo>::iterator input_iter = eg->inputs.begin(),
      input_end = eg->inputs.end();
  for (; input_iter != input_end; ++input_iter) {
    bool must_exclude = false;
    std::vector<string>::const_iterator exclude_iter = exclude_names.begin(),
        exclude_end = exclude_names.end();
    for (; exclude_iter != exclude_end; ++exclude_iter)
      if (input_iter->name == *exclude_iter)
        must_exclude = true;
    if (!must_exclude) {
      std::vector<Index>::iterator indexes_iter = input_iter->indexes.begin(),
          indexes_end = input_iter->indexes.end();
      for (; indexes_iter != indexes_end; ++indexes_iter)
        indexes_iter->t += frame_shift;
    }
  }
  // note: we'll normally choose a small enough shift that the output-data
  // shift will be zero after dividing by frame_subsampling_factor
  // (e.g. frame_subsampling_factor == 3 and shift = 0 or 1.
  std::vector<NnetSupervision>::iterator
      sup_iter = eg->outputs.begin(),
      sup_end = eg->outputs.end();
  for (; sup_iter != sup_end; ++sup_iter) {
    std::vector<Index> &indexes = sup_iter->indexes;
    KALDI_ASSERT(indexes.size() >= 2 && indexes[0].n == indexes[1].n &&
                 indexes[0].x == indexes[1].x);
    int32 frame_subsampling_factor = indexes[1].t - indexes[0].t;
    KALDI_ASSERT(frame_subsampling_factor > 0);

    // We need to shift by a multiple of frame_subsampling_factor.
    // Round to the closest multiple.
    int32 supervision_frame_shift =
        frame_subsampling_factor *
        std::floor(0.5 + (frame_shift * 1.0 / frame_subsampling_factor));
    if (supervision_frame_shift == 0)
      continue;
    std::vector<Index>::iterator indexes_iter = indexes.begin(),
        indexes_end = indexes.end();
    for (; indexes_iter != indexes_end; ++indexes_iter)
      indexes_iter->t += supervision_frame_shift;
  }
}

} // namespace nnet3
} // namespace kaldi