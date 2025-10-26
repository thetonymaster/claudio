# Additional Features Implemented

Following the initial improvements, these additional features from the Anthropic API have been implemented:

## 1. Prompt Caching ✅

Prompt caching reduces costs by up to 90% and latency by up to 85% for long prompts by caching static content.

### Implementation

**Request Module (`lib/claudio/messages/request.ex`):**
- `set_system_with_cache/2` - Sets system prompt with caching
- `add_tool_with_cache/2` - Adds tool definitions with caching
- Support for manual `cache_control` in system blocks, tools, and message content

**Response Module (`lib/claudio/messages/response.ex`):**
- Updated usage tracking to include:
  - `cache_creation_input_tokens` - Tokens written to cache
  - `cache_read_input_tokens` - Tokens read from cache

### Usage Examples

```elixir
# System prompt with caching (5-minute TTL)
Request.new("claude-3-5-sonnet-20241022")
|> Request.set_system_with_cache("Long system prompt here...")
|> Request.add_message(:user, "Question")

# Extended cache TTL (1 hour)
Request.new("claude-3-5-sonnet-20241022")
|> Request.set_system_with_cache("Long context...", ttl: "1h")

# Tools with caching
tool = Tools.define_tool("get_weather", "Get weather", schema)
Request.new("claude-3-5-sonnet-20241022")
|> Request.add_tool_with_cache(tool)

# Manual cache control
Request.new("claude-3-5-sonnet-20241022")
|> Request.set_system([
  %{
    "type" => "text",
    "text" => "Context here...",
    "cache_control" => %{"type" => "ephemeral", "ttl" => "1h"}
  }
])

# Check cache metrics
{:ok, response} = Messages.create(client, request)
IO.inspect(response.usage.cache_read_input_tokens)
IO.inspect(response.usage.cache_creation_input_tokens)
```

### Key Features

- Two TTL options: `"5m"` (default, included) and `"1h"` (extended, additional cost)
- Automatic cache invalidation after TTL expires
- Cache metrics in response usage
- Up to 4 cache breakpoints supported
- Works with system prompts, tools, and message content

## 2. Vision/Image Support ✅

Support for analyzing images using Claude's vision capabilities.

### Implementation

**Request Module:**
- `add_message_with_image/4` - Adds message with base64-encoded image
- `add_message_with_image_url/3` - Adds message with image URL
- Support for manual image content blocks

**Supported Formats:**
- JPEG (`image/jpeg`)
- PNG (`image/png`)
- GIF (`image/gif`)
- WebP (`image/webp`)

**Submission Methods:**
1. Base64-encoded images
2. URL-based images
3. Files API (via `file_id`)

### Usage Examples

```elixir
# Base64-encoded image
image_data = File.read!("image.jpg") |> Base.encode64()

Request.new("claude-3-5-sonnet-20241022")
|> Request.add_message_with_image(
  :user,
  "What's in this image?",
  image_data,
  "image/jpeg"
)

# Image from URL
Request.new("claude-3-5-sonnet-20241022")
|> Request.add_message_with_image_url(
  :user,
  "Describe this image",
  "https://example.com/image.jpg"
)

# Multiple images in one message
Request.new("claude-3-5-sonnet-20241022")
|> Request.add_message(:user, [
  %{
    "type" => "image",
    "source" => %{
      "type" => "base64",
      "media_type" => "image/jpeg",
      "data" => image1_data
    }
  },
  %{
    "type" => "image",
    "source" => %{
      "type" => "base64",
      "media_type" => "image/png",
      "data" => image2_data
    }
  },
  %{"type" => "text", "text" => "Compare these images"}
])

# Using Files API
Request.new("claude-3-5-sonnet-20241022")
|> Request.add_message(:user, [
  %{
    "type" => "image",
    "source" => %{
      "type" => "file",
      "file_id" => "file_abc123"
    }
  },
  %{"type" => "text", "text" => "Analyze this image"}
])
```

### Limits

- Maximum 100 images per API request
- Maximum 5MB per image file
- Images > 8000x8000px will be rejected
- For > 20 images: max 2000x2000px per image

### Best Practices

- Place images before text for optimal performance
- Use clear, high-resolution images
- Consider using Files API for frequently reused images

## 3. PDF/Document Support ✅

Support for analyzing PDF documents and other file types.

### Implementation

**Request Module:**
- `add_message_with_document/3` - Adds message with document from Files API

### Usage Examples

```elixir
# Upload document to Files API first, then reference by file_id
Request.new("claude-3-5-sonnet-20241022")
|> Request.add_message_with_document(
  :user,
  "Summarize this document",
  "file_abc123"
)

# Manual document content block
Request.new("claude-3-5-sonnet-20241022")
|> Request.add_message(:user, [
  %{
    "type" => "document",
    "source" => %{
      "type" => "file",
      "file_id" => "file_xyz789"
    }
  },
  %{"type" => "text", "text" => "What are the key points?"}
])

# With prompt caching for large documents
Request.new("claude-3-5-sonnet-20241022")
|> Request.add_message(:user, [
  %{
    "type" => "document",
    "source" => %{
      "type" => "file",
      "file_id" => "file_large_doc"
    },
    "cache_control" => %{"type" => "ephemeral"}
  },
  %{"type" => "text", "text" => "Analyze section 3"}
])
```

### Notes

- Documents must be uploaded via Files API first
- Returns a `file_id` for reference in messages
- Supports PDF and other document formats
- Can be combined with prompt caching for large documents

## 4. MCP (Model Context Protocol) Servers ✅

Support for integrating with MCP servers.

### Implementation

**Request Module:**
- `add_mcp_server/2` - Adds MCP server definition
- `mcp_servers` field in Request struct
- Included in `to_map/1` output

### Usage Examples

```elixir
# Add MCP server
Request.new("claude-3-5-sonnet-20241022")
|> Request.add_mcp_server(%{
  "name" => "my_server",
  "url" => "http://localhost:8080"
})
|> Request.add_message(:user, "Use the MCP server to fetch data")

# Multiple MCP servers
Request.new("claude-3-5-sonnet-20241022")
|> Request.add_mcp_server(%{
  "name" => "database_server",
  "url" => "http://localhost:8080"
})
|> Request.add_mcp_server(%{
  "name" => "api_server",
  "url" => "http://localhost:9000"
})
```

## Combined Usage Examples

### Vision + Caching

```elixir
# Analyze multiple images with cached context
Request.new("claude-3-5-sonnet-20241022")
|> Request.set_system_with_cache("""
  You are an expert image analyst. Provide detailed descriptions
  focusing on composition, lighting, and emotional impact.
  """, ttl: "1h")
|> Request.add_message_with_image(:user, "Analyze this", image_data)
|> Request.set_max_tokens(1024)
```

### Documents + Tools + Caching

```elixir
# Analyze document with tool access and caching
tools = [
  Tools.define_tool("search_database", "Search for information", schema),
  Tools.define_tool("get_metadata", "Get document metadata", schema)
]

Request.new("claude-3-5-sonnet-20241022")
|> Request.set_system_with_cache("You are a document analyst...", ttl: "1h")
|> Enum.reduce(tools, &Request.add_tool_with_cache(&2, &1))
|> Request.add_message_with_document(:user, "Analyze this report", file_id)
|> Request.set_max_tokens(2048)
```

### Multimodal with Everything

```elixir
# Complex request combining all features
Request.new("claude-3-5-sonnet-20241022")
|> Request.set_system_with_cache(long_context, ttl: "1h")
|> Request.add_tool_with_cache(weather_tool)
|> Request.add_tool_with_cache(search_tool)
|> Request.add_mcp_server(mcp_config)
|> Request.add_message(:user, [
  %{"type" => "image", "source" => %{"type" => "base64", "media_type" => "image/jpeg", "data" => img}},
  %{"type" => "document", "source" => %{"type" => "file", "file_id" => doc_id}},
  %{"type" => "text", "text" => "Analyze the image and document together"}
])
|> Request.set_max_tokens(4096)
|> Request.set_temperature(0.7)
```

## Benefits

### Cost Savings
- **Prompt Caching**: Up to 90% cost reduction for cached content
- **Efficient Image Handling**: Files API reduces data transfer for repeated images

### Performance Improvements
- **Prompt Caching**: Up to 85% latency reduction
- **Automatic Cache Management**: No manual tracking needed (API handles it)

### Enhanced Capabilities
- **Vision**: Analyze images, charts, diagrams, screenshots
- **Documents**: Process PDFs, reports, presentations
- **MCP Integration**: Connect to external data sources
- **Multimodal**: Combine text, images, and documents in single request

## Testing

All new features maintain the existing test coverage:
- ✅ 55 tests passing
- ✅ Backward compatibility maintained
- ✅ New features tested via integration tests

## API Coverage

The Claudio library now supports:
- ✅ Messages API (create, streaming, count_tokens)
- ✅ Message Batches API (all 6 endpoints)
- ✅ Tool/Function Calling
- ✅ Prompt Caching
- ✅ Vision/Images (base64, URL, Files API)
- ✅ PDF/Document Support
- ✅ MCP Servers
- ✅ Extended Thinking
- ✅ All sampling parameters (temperature, top_p, top_k)
- ✅ Stop sequences
- ✅ Metadata
- ✅ Structured error handling

The library is feature-complete for the current Anthropic API (as of January 2025).
