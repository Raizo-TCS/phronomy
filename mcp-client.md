# MCP client support

Phronomy supports the official `mcp` Ruby SDK **1.x**. MCP SDK 0.x is not supported.

## Transports

`Phronomy::Tools::Mcp.from_server` supports:

- `stdio://...`
- `http://...`
- `https://...`

HTTP and SSE support are standard dependencies of Phronomy through `faraday` and
`event_stream_parser`.

## Input-schema subset

Phronomy intentionally supports a strict subset of JSON Schema 2020-12 for MCP
Tool inputs.

Supported root keywords:

- `$schema`
- `type` (`object` only)
- `properties`
- `required`
- `title`
- `description`
- `additionalProperties` when omitted or `false`

Supported property types:

- `string`
- `integer`
- `number`
- `boolean`

Supported property keywords:

- `type`
- `description`
- `enum`
- `title`

The following validation keywords are accepted but ignored with a warning:

- `minimum`, `maximum`, `exclusiveMinimum`, `exclusiveMaximum`, `multipleOf`
- `minLength`, `maxLength`, `pattern`, `format`, `default`, `examples`

Unknown keywords, structural composition (`oneOf`, `anyOf`, `allOf`, `$ref`,
conditionals), arrays, nested objects, and nullable type arrays fail fast with
`Phronomy::ToolError` rather than silently changing the Tool contract.

When `additionalProperties` is omitted, the remote schema is accepted, but
Phronomy still exposes and accepts only names declared in `properties`.

`outputSchema` is detected and reported with a warning, but is not validated in
this phase.

## Errors and cancellation

- JSON-RPC errors raised by the SDK are converted to `Phronomy::ToolError`.
- MCP Tool results with `isError: true` are returned to the model as Tool error
  text so the model can correct its arguments.
- An expired HTTP session is reconnected for future calls. The failed Tool call
  is not replayed because Tool side effects are not assumed to be idempotent.
- Cancellation invalidates the current client and transport. The next call creates
  a new connection, preventing an abandoned SDK worker from sharing the old stdio
  stream with a new request.

Calls, reconnects, and explicit `close` operations on a Tool instance are
serialized. `close` synchronously closes the current client and permits a later
call to reconnect. A transport detached by cancellation is owned by the bounded
MCP cleanup pool and is drained during Runtime shutdown; `close` does not wait
for an older detached transport.
