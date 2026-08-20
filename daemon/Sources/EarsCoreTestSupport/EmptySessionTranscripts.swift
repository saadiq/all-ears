/// The two 2026-08-20 sessions that motivated the empty-transcript gate,
/// verbatim as `transcribe` rendered them.
///
/// Both were meetings nobody spoke in, and both ran the full on-end chain:
/// `cleanup` and `summarize` produced a note speculating about whether the
/// meeting had happened, published it, and overwrote an unrelated daily note
/// with it. Neither is a document anyone would have invented as a test case —
/// a 605-second recording that transcribes to the single word `Yeah.` is
/// exactly the shape a synthetic fixture rounds off — so they are kept here
/// as-is, and shared by the pure predicate's tests (`EarsCoreTests`) and the
/// chain-level ones (`EarsDaemonKitTests`).
public enum EmptySessionTranscripts {
  /// Session `c08595c8-77fa-48c4-a077-ff5d9f60e522`: 605 seconds recorded,
  /// one word, 0.556s of speech. The damaging case — long enough to look like
  /// a real meeting from the session record alone.
  public static let oneWord = """
    ---
    schema: 1
    kind: transcript
    session: c08595c8-77fa-48c4-a077-ff5d9f60e522
    title: meet VmKkVuH3hvEB
    attendees:
    - Tom Elliot (me)
    started: 2026-08-20T14:00:58Z
    sources:
    - mic
    range:
      start: 2026-08-20T14:00:58Z
      end: 2026-08-20T14:11:03Z
    model:
      name: parakeet-tdt-fluidaudio
      backend: fluidaudio
      version: "parakeet-tdt-0.6b-v3"
    diarization:
      enabled: false
    generated: 2026-08-20T14:11:06Z
    duration_seconds: 605
    speech_seconds: 0.556
    word_count: 1
    vocab: []
    audio_stores:
    - "mic=session"
    ---

    **[14:04:53] You**
    Yeah.
    """

  /// Session `eb57a96c-a031-405e-913b-961297710caf`: 4 seconds recorded, no
  /// segments at all. Summarize still wrote a note for it, whose body was
  /// "There is nothing substantive to summarize."
  public static let silent = """
    ---
    schema: 1
    kind: transcript
    session: eb57a96c-a031-405e-913b-961297710caf
    title: meet VmKkVuH3hvEB
    attendees:
    - Tom Elliot (me)
    started: 2026-08-20T07:43:01Z
    sources:
    - mic
    range:
      start: 2026-08-20T07:43:01Z
      end: 2026-08-20T07:43:05Z
    model:
      name: parakeet-tdt-fluidaudio
      backend: fluidaudio
      version: "parakeet-tdt-0.6b-v3"
    diarization:
      enabled: false
    generated: 2026-08-20T07:43:07Z
    duration_seconds: 4
    speech_seconds: 0
    word_count: 0
    vocab: []
    audio_stores:
    - "mic=session"
    ---

    """

  /// A real exchange, for the other side of the gate: brief, but plainly a
  /// conversation. Same schema, measurements above both default thresholds.
  public static let substantive = """
    ---
    schema: 1
    kind: transcript
    session: 4a1f9c22-0d18-4a71-9f0b-2c4e6d8a1b33
    title: meet VmKkVuH3hvEB
    attendees:
    - Tom Elliot (me)
    started: 2026-08-20T09:15:00Z
    sources:
    - mic
    range:
      start: 2026-08-20T09:15:00Z
      end: 2026-08-20T09:19:40Z
    model:
      name: parakeet-tdt-fluidaudio
      backend: fluidaudio
      version: "parakeet-tdt-0.6b-v3"
    diarization:
      enabled: false
    generated: 2026-08-20T09:19:44Z
    duration_seconds: 280
    speech_seconds: 96.4
    word_count: 214
    vocab: []
    audio_stores:
    - "mic=session"
    ---

    **[09:15:04] You**
    Right, so the retention clock starts at transcript completion, not at
    session end — that is the whole reason the skip has to return success.
    """
}
