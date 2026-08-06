// Thought process UI lives in `ThinkingBlock` (shared by chat + code session).
// Collapsed: clock + grey one-line summary (Apple Foundation Model) + chevron.
// Expanded: full text in a “Thought process” sheet.
// Reasoning is extracted from `<think>` / `<thinking>` tags via
// `ThinkingExtractor` when the assistant reply is stored (and again at display).
