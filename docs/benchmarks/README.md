# Local ASR fixtures

Keep real recordings out of Git. A fixture directory used by
`scripts/model-matrix.sh` contains mono Float32 16 kHz WAV files and a sidecar
`manifest.json`:

```json
{
  "fixtures": [
    {
      "audio": "german-english.wav",
      "expectedText": "Das ist ein test and now I am speaking English.",
      "expectedLanguages": ["de", "en"],
      "maxWER": 0.25
    }
  ]
}
```

The benchmark runs Nemotron and Whisper sequentially, keeps model weights
resident between regions, and emits latency, real-time factor, WER, and
language-preservation fields. Use separate reports for before/after changes;
do not compare cold preparation with warm segmented decode.
