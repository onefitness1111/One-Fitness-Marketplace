// Retired. The full exercise-photo upload ran on Nov 23, 2026. Does nothing.
Deno.serve(() => new Response(JSON.stringify({ error: "retired" }), { status: 410, headers: { "Content-Type": "application/json" } }));
