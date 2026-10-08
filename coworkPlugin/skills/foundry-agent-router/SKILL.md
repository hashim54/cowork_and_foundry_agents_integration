---
name: foundry-agent-router
description: |
  Lists and invokes agents in the configured Microsoft Foundry project.
  Use when the user asks which Foundry agents are available, asks to invoke
  a Foundry agent, or wants a Foundry agent to perform a task.
license: MIT
metadata:
  author: Foundry Cowork Plugin contributors
  version: "1.0"
---

# Foundry Agent Router

Use the connector that provides `agent_get` and `agent_invoke` for this project only:

`{{FOUNDRY_PROJECT_ENDPOINT}}`

## Workflow

1. Always use the project endpoint above; never call another Foundry project.
2. When the user asks what is available or the agent name is ambiguous, call
   `agent_get` without an agent name.
3. Never invent an agent name. If unavailable, show the available agents and
   ask the user to select one.
4. Call `agent_invoke` with the selected name and faithfully pass the user's
   request as `inputText`.
5. Omit protocol and agent version unless explicitly requested. Let the
   server auto-detect the protocol and use the latest version.
6. Reuse a returned `conversationId` only for the same user, Cowork thread,
   Foundry project, and agent. For prompt agents and Responses-protocol
   hosted agents, this carries conversation history.
7. Reuse a returned hosted-agent `sessionId` only within that same scope.
   It may retain sandbox/filesystem or agent-managed state; it does not
   itself replay Responses history. Invocations-protocol agents must
   implement their own conversational memory.
8. Never treat an MCP transport session ID as a Foundry conversation ID.
9. If no reusable identifier is returned, include a concise, labeled summary
   of relevant prior turns in the next `inputText`. Do not duplicate history
   when a valid conversation identifier is reused.
10. Switching agents or starting fresh resets identifier reuse. Transfer
    context to another agent only when the user requests it.
11. Identify the responding agent. Report actual errors and do not silently
    switch projects or identities after authentication/authorization failures.

Use only `agent_get` and `agent_invoke`. Do not create, update, delete, or
evaluate agents or Azure resources. These are planner instructions, not a
server-side security boundary.
