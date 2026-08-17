# Third-party notices

Vocaret is licensed under the Apache License 2.0 (see `LICENSE`). It builds on the
following third-party components. Each remains under its own license and
copyright.

## Statically linked into the Vocaret binary

| Component | Copyright | License |
|---|---|---|
| [WhisperKit](https://github.com/argmaxinc/WhisperKit) | © 2024 Argmax, Inc. | MIT |
| [swift-transformers](https://github.com/huggingface/swift-transformers) | © Hugging Face SAS | Apache-2.0 |
| [swift-jinja](https://github.com/johnmai-dev/swift-jinja) | © Hugging Face SAS / John Mai | Apache-2.0 |
| [swift-argument-parser](https://github.com/apple/swift-argument-parser) | © Apple Inc. | Apache-2.0 |
| [swift-crypto](https://github.com/apple/swift-crypto) | © Apple Inc. | Apache-2.0 |
| [swift-asn1](https://github.com/apple/swift-asn1) | © Apple Inc. | Apache-2.0 |
| [swift-collections](https://github.com/apple/swift-collections) | © Apple Inc. | Apache-2.0 |
| [yyjson](https://github.com/ibireme/yyjson) | © YaoYuan | MIT |

Apache-2.0 components are used unmodified; a copy of the Apache License 2.0 is
included as `LICENSE`. MIT components require their copyright notice to be
preserved, which this file does.

## Downloaded at runtime (not distributed with Vocaret)

**Whisper speech-recognition models** — converted to Core ML and hosted at
[argmaxinc/whisperkit-coreml](https://huggingface.co/argmaxinc/whisperkit-coreml).
Downloaded on first launch into `~/Library/Application Support/Vocaret/Models`.
The underlying [Whisper](https://github.com/openai/whisper) model and code are
© OpenAI, MIT licensed. Vocaret deliberately does **not** bundle these weights;
they are fetched from their original source at runtime.

## Optional, installed by the user (not distributed with Vocaret)

**llama.cpp** — © 2023 The ggml authors, MIT licensed. Installed by the user via
Homebrew (`brew install llama.cpp`). Vocaret launches `llama-server` as a separate
process and talks to it over localhost HTTP; it does not link against or
redistribute llama.cpp.

**Qwen3-4B-Instruct-2507 (GGUF)** — © Alibaba Cloud, Apache-2.0 licensed.
Downloaded by `scripts/setup_llm.sh` from
[unsloth/Qwen3-4B-Instruct-2507-GGUF](https://huggingface.co/unsloth/Qwen3-4B-Instruct-2507-GGUF)
into `~/Library/Application Support/Vocaret/Models`. Not redistributed by Vocaret.

## Apple frameworks

Vocaret uses AppKit, AVFoundation, CoreAudio, CoreML, Carbon (HIToolbox),
ApplicationServices and ServiceManagement from the macOS SDK under the Apple
SDK license terms.
