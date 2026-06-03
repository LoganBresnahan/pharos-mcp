//// MCP content blocks.
////
//// Content blocks are the unit of tool output. The MCP spec defines
//// `text`, `image`, and `resource` variants. Pharos currently emits
//// only text; the other variants are added when a tool needs them.

import gleam/json.{type Json}

pub type ContentBlock {
  Text(text: String)
}

pub fn text(value: String) -> ContentBlock {
  Text(value)
}

pub fn to_json(block: ContentBlock) -> Json {
  case block {
    Text(value) ->
      json.object([
        #("type", json.string("text")),
        #("text", json.string(value)),
      ])
  }
}
