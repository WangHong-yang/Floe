# Third-party notices

Floe depends on sherpa-onnx 2.0.1 (Apache 2.0), X-ASR model weights (Apache 2.0), and ONNX Runtime (MIT). Their license texts are in `licenses/` and copied into the built app. Upstream provenance is linked in the README.

`Resources/bpe.vocab` is derived from the X-ASR model's `bpe.model` using the sherpa-onnx export utility and SentencePiece 0.2.1; its checksum is verified during the build.

The glass logo was created and supplied by this project's owner. `scripts/prepare-logo.swift` is an optional local artwork preparation utility and is not required to build Floe.

Downloaded libraries, model binaries, and test audio are build dependencies cached in the Git-ignored `vendor/` directory. No user recordings, personal hotwords, or transcript history are included in this repository.
