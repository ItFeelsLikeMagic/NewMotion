# Local observability contract

The shared `MetricsRecorder` is the only foundation logging API. It accepts
protocol message types, byte counts, sequence numbers, fixed enum values, and
durations/rates. It has no field or method for typed text, transcript text,
audio bytes, QR secrets, long-term keys, or arbitrary strings. Sinks receive
structured records and may retain them locally for a test run.

The recorder tracks connection/lifecycle transitions, packet counts by type,
sequence gaps, duplicates, retries, acknowledgements, a deterministic latency
histogram, heartbeat releases, audio gaps/duration, and motion sample/output
rates. Seven latency buckets are stable: 0–4, 5–9, 10–24, 25–49, 50–99,
100–249, and 250+ milliseconds.

The MVP has no remote analytics sink. A future local file sink must use a
bounded retention policy (default seven days), write only the structured event
fields, and provide an explicit “Clear diagnostics” action. During development,
the in-memory test sink is cleared after each test; uninstalling the app or
using that action is the removal procedure for persisted local diagnostics.

