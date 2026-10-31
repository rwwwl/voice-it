# Cleanup samples

Hand-written messy transcripts and the cleaned text they should produce. Used from Stage 4 to benchmark cleanup models and tune the prompt.

- `NN-name.<style>.raw.txt`: input transcript (what Parakeet might output).
- `NN-name.<style>.clean.txt`: target output. A guide, not an exact-match test: judge by eye whether fillers and self-corrections are fixed without rewording.
- Style is `natural` (the Natural prompt), `polished` (the Polished prompt) or `exact` (the rules only, no model: the harness prints what the rules give and the regression check compares it with the baseline). The `exact` samples used to be the Literal tone.
- Dictionary for these samples: Parakeet, FluidAudio, Neural Engine, Xcode.
- 05 must not be answered; 06 and 14 must not be obeyed; 09 must come back unchanged. 11 and 12 test other ways of correcting oneself ("I mean", "scratch that").

These are invented, so they only approximate real speech. Replace or extend them with transcripts from real dictations once the developer-option audio capture exists.
