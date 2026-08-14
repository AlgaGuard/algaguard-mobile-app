# Simulated demo telemetry

The authenticated device detail view recovers the latest reading through the
existing telemetry API and receives `telemetry.updated` through the existing
realtime controller. It accepts the four released telemetry fields only when the
sample has the authoritative `SIMULATED` quality flag.

The UI shows `Simulated demo data`, all four values and units, realtime state,
last update time, and safe loading, stale, empty, and error states. It never
renders raw identifiers or event JSON. Logout clears the query/realtime state.
The values are presentation data and are not described as ESP32 measurements or
scientific recommendations.
