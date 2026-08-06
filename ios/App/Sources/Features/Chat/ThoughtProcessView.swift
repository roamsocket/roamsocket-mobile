// Thought process UI lives in `ThinkingBlock` (shared by chat + code session).
// Reasoning is extracted from `<think>` / `<thinking>` tags via
// `ThinkingExtractor` when the assistant reply is stored (and again
// at render time as a fallback).
