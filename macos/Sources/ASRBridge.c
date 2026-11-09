#include "ASRBridge.h"
#include "sherpa-onnx.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

struct GTRecognizer {
  const SherpaOnnxOnlineRecognizer *recognizer;
  const SherpaOnnxOnlineStream *stream;
};

static GTRecognizer *Create(const char *directory, float score) {
  char encoder[4096], decoder[4096], joiner[4096], tokens[4096], vocab[4096];
  snprintf(encoder, sizeof(encoder), "%s/encoder.int8.onnx", directory);
  snprintf(decoder, sizeof(decoder), "%s/decoder.onnx", directory);
  snprintf(joiner, sizeof(joiner), "%s/joiner.int8.onnx", directory);
  snprintf(tokens, sizeof(tokens), "%s/tokens.txt", directory);
  snprintf(vocab, sizeof(vocab), "%s/bpe.vocab", directory);
  if (!SherpaOnnxFileExists(encoder) || !SherpaOnnxFileExists(decoder) ||
      !SherpaOnnxFileExists(joiner) || !SherpaOnnxFileExists(tokens)) return NULL;
  SherpaOnnxOnlineRecognizerConfig config = {0};
  config.feat_config.sample_rate = 16000;
  config.feat_config.feature_dim = 80;
  config.model_config.transducer.encoder = encoder;
  config.model_config.transducer.decoder = decoder;
  config.model_config.transducer.joiner = joiner;
  config.model_config.tokens = tokens;
  config.model_config.provider = "cpu";
  config.model_config.num_threads = 2;
  config.decoding_method = "greedy_search";
  if (score > 0) {
    if (!SherpaOnnxFileExists(vocab)) return NULL;
    config.model_config.modeling_unit = "bpe";
    config.model_config.bpe_vocab = vocab;
    config.decoding_method = "modified_beam_search";
    config.max_active_paths = 4;
    config.hotwords_score = score;
  }
  // Each hold is one utterance. Silence must not discard earlier words.
  config.enable_endpoint = 0;
  GTRecognizer *r = calloc(1, sizeof(*r));
  if (!r) return NULL;
  r->recognizer = SherpaOnnxCreateOnlineRecognizer(&config);
  if (!r->recognizer) { free(r); return NULL; }
  return r;
}

GTRecognizer *GTCreate(const char *directory) { return Create(directory, 0); }
GTRecognizer *GTCreateWithHotwords(const char *directory, float score) {
  return Create(directory, score);
}
void GTCancel(GTRecognizer *r) {
  if (r && r->stream) {
    SherpaOnnxDestroyOnlineStream(r->stream);
    r->stream = NULL;
  }
}

void GTDestroy(GTRecognizer *r) {
  if (!r) return;
  GTCancel(r);
  SherpaOnnxDestroyOnlineRecognizer(r->recognizer);
  free(r);
}

int GTBegin(GTRecognizer *r) {
  if (!r) return 0;
  GTCancel(r);
  r->stream = SherpaOnnxCreateOnlineStream(r->recognizer);
  return r->stream != NULL;
}

int GTBeginWithHotwords(GTRecognizer *r, const char *hotwords) {
  if (!r || !hotwords || !*hotwords) return GTBegin(r);
  GTCancel(r);
  r->stream = SherpaOnnxCreateOnlineStreamWithHotwords(r->recognizer, hotwords);
  return r->stream != NULL;
}
void GTAccept(GTRecognizer *r, const float *samples, int32_t count) {
  if (!r || !r->stream || count <= 0) return;
  SherpaOnnxOnlineStreamAcceptWaveform(r->stream, 16000, samples, count);
  while (SherpaOnnxIsOnlineStreamReady(r->recognizer, r->stream))
    SherpaOnnxDecodeOnlineStream(r->recognizer, r->stream);
}

void GTFinish(GTRecognizer *r) {
  if (!r || !r->stream) return;
  // Supply right context for the final encoder chunk, then signal EOS.
  float tail[8000] = {0};
  GTAccept(r, tail, 8000);
  SherpaOnnxOnlineStreamInputFinished(r->stream);
  while (SherpaOnnxIsOnlineStreamReady(r->recognizer, r->stream))
    SherpaOnnxDecodeOnlineStream(r->recognizer, r->stream);
}

char *GTText(GTRecognizer *r) {
  if (!r || !r->stream) return strdup("");
  const SherpaOnnxOnlineRecognizerResult *result =
    SherpaOnnxGetOnlineStreamResult(r->recognizer, r->stream);
  char *text = strdup(result && result->text ? result->text : "");
  if (result) SherpaOnnxDestroyOnlineRecognizerResult(result);
  return text;
}

void GTFreeText(char *text) { free(text); }
