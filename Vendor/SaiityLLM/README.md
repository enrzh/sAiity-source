# Local LLM generation limits

This source is copied from obra/LLM.swift revision c2144e1a0e29c280ec6080b7da85e876d51f8509.
It reuses that pinned package's llama binary and macro modules. The MIT license is preserved here.

The local changes add a generated-token/deadline budget, let actor stop requests run between decode steps,
and await native generation completion before releasing model ownership. The upstream wrapper has no
equivalent limit and its actor decode loop prevents stop requests from executing until it is finished.

Checks run between native token decodes. A single prompt-evaluation or token-decode call cannot be
interrupted; the wrapper waits for it. Stream cancellation targets that exact generation task, so a late
stop request cannot cancel the following request. Exhausted token/context/time budgets discard the
partial answer in the application, which retains its validated cleanup baseline or untranslated source.

Switch back to the upstream module when it exposes equivalent completion and budget APIs. Do not edit
SwiftPM checkouts or change the vendored llama binary to update this patch.
