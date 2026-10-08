# ADR 0008 — XPC peer authentication

Status: accepted; genuine signed-build verification remains a release gate.

## Problem

The agent's Mach service accepted any local caller, and `loadPolicy` returned security-scoped bookmark data to whoever asked. Any process able to look up the service could rewrite policy, so the index and policy store were effectively unauthenticated.

## Decision

The agent derives a code-signing requirement from its own signature (`SecCodeCopySelf` and the signing information's team identifier), via `PeerRequirement.current()`. It applies the requirement to its listener and incoming connections (`setCodeSigningRequirement`). The CLI client and app transport apply the same requirement to their connections to the agent.

Unsigned or ad-hoc development builds have no team identifier. They skip the requirement and log that peers are unauthenticated. Release behavior depends on genuine Developer ID signing (ADR 0004, ADR 0005); the early ad-hoc pre-releases do not get peer authentication.

The sandboxed Finder extension holds a mach-lookup exception for the agent. It is a thin client and goes through the same checks, and it uses `loadRoots`, which never returns bookmark data.

## Consequences

- Peer authentication is verified only on genuinely signed builds, which cannot yet be produced without Apple credentials.
- Bookmark data is limited to the app, the only client that obtains folder access.
