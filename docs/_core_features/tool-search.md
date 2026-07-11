---
layout: default
title: Tool Search
parent: "Tools"
nav_order: 5
description: Keep large tool catalogs out of the model's context. Mark tools as deferred and let the provider's tool search load only the ones a conversation needs.
redirect_from:
  - /guides/tool-search
---

# {{ page.title }}
{: .no_toc }

{{ page.description }}
{: .fs-6 .fw-300 }

## Table of contents
{: .no_toc .text-delta }

1. TOC
{:toc}

---

After reading this guide, you will know:

*   When deferred tool loading helps.
*   How to mark tools as deferred.
*   Which providers support it and what happens on the others.

## When to use it

When a chat is wired to many tools, every tool's full JSON Schema ships on every request. Three costs follow:

1. **Token bloat.** Hundreds of tools can add tens of thousands of tokens per request.
2. **Prompt-cache eviction.** Adding or removing tools changes the request prefix and invalidates the cache.
3. **Selection accuracy.** Models choose worse tools when the menu is long.

Tool search addresses all three. You mark tools as **deferred**, and the provider keeps their schemas out of the model's context until its tool search loads the ones the conversation actually needs. The API below is the same whichever provider you use.

## Marking tools as deferred

Pass `defer: true` when registering tools:

```ruby
chat = RubyLLM.chat(model: "claude-sonnet-4-6")
chat.with_tools(*mcp_client.tools, defer: true)
```

Or declare it once on a tool that should always be deferred:

```ruby
class DeepResearchTool < RubyLLM::Tool
  description "Runs a multi-step web investigation"
  deferred

  parameter :query, description: "What to investigate"

  def execute(query:)
    # ...
  end
end

chat.with_tools(DeepResearchTool)
```

`defer: true` on `with_tools` overrides a tool that is not declared `deferred`, and `defer: false` overrides one that is.

## How the model loads deferred tools

Every request sends the same tools array: each deferred tool with the provider's defer flag, plus that provider's tool-search primitive. Because the array never changes between turns, the provider's prompt cache is preserved, which is the point of the feature.

When the model searches and finds a tool, the provider reports it back, and RubyLLM replays the search exchange from the transcript on later requests, so the model keeps using found tools without searching again. A found tool executes exactly like any other tool.

## Provider support

| Provider | Protocol | Deferred loading |
|----------|----------|------------------|
| Anthropic | `:anthropic` | Native, on the models Anthropic lists for its tool search tool (Claude 4.5 and later) |
| OpenAI | `:responses` (the default) | Native, on gpt-5.4 and later |
| OpenAI | `:chat_completions` | Not supported |
| Everyone else (Gemini, Bedrock, Mistral, ...) | | Not supported |

Support is resolved per model on every request. When the current provider or model has no native tool search, deferred tools go out as ordinary tools, so the same code runs everywhere and switching models mid-chat, including automatic fallbacks, needs no changes.

Two Anthropic constraints are handled for you: the native search tool is always sent non-deferred, so a chat whose tools are all deferred still works, and combining `defer:` with a tool's `cache_control` raises an `ArgumentError` instead of a provider error.

## Rails persistence

The search exchange rides the message's `raw_content`, the same mechanism that replays provider tools such as web search, so with the 2.0 schema it is persisted with the conversation and found tools stay found across process restarts. It is replayed only while the request still declares deferred tools; otherwise the search blocks are dropped and the model searches again.

## Further reading

*   [Anthropic tool search tool](https://platform.claude.com/docs/en/agents-and-tools/tool-use/tool-search-tool)
*   [OpenAI tool search](https://developers.openai.com/api/docs/guides/tools-tool-search)
*   [Tools guide]({% link _core_features/tools.md %})
