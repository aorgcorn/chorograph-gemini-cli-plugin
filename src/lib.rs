use chorograph_plugin_sdk_rust::prelude::*;
use serde_json::json;

struct GeminiCLI;

impl GeminiCLI {
    /// Formats all messages before the final user turn into a conversation transcript
    /// so that the CLI has full context when replying. Returns an empty string when
    /// there is only one message (first-turn / "chat" action — no history yet).
    fn format_history(&self, messages: &[serde_json::Value]) -> String {
        // Drop the last message (the new user prompt — already included in the prompt itself).
        let prior: Vec<&serde_json::Value> = messages
            .iter()
            .rev()
            .skip(1) // skip the final user message
            .collect::<Vec<_>>()
            .into_iter()
            .rev()
            .collect();

        if prior.is_empty() {
            return String::new();
        }

        let mut history = String::from("\n\n### Conversation History (most recent context):\n");
        for msg in &prior {
            let role = msg
                .get("role")
                .and_then(|r| r.as_str())
                .unwrap_or("unknown");
            let text = msg.get("text").and_then(|t| t.as_str()).unwrap_or("");
            let label = if role == "user" { "User" } else { "Assistant" };
            history.push_str(&format!("\n**{}:** {}\n", label, text));
        }
        history.push_str("\n---\nContinue the conversation based on the history above.\n");
        history
    }

    fn format_skeletons(&self, payload: &serde_json::Value) -> String {
        let mut context = String::new();
        if let Some(skeletons) = payload.get("skeletons").and_then(|s| s.as_array()) {
            if !skeletons.is_empty() {
                context.push_str("\n\n### Project Structure Context (AST Skeletons):\n");
                for skel in skeletons {
                    if let (Some(path), Some(symbols)) = (
                        skel.get("path").and_then(|p| p.as_str()),
                        skel.get("symbols").and_then(|s| s.as_array()),
                    ) {
                        context.push_str(&format!("\nFile: `{}`\n", path));
                        for sym in symbols {
                            if let (Some(name), Some(kind), Some(line)) = (
                                sym.get("name").and_then(|n| n.as_str()),
                                sym.get("kind").and_then(|k| k.as_str()),
                                sym.get("line").and_then(|l| l.as_u64()),
                            ) {
                                context.push_str(&format!(
                                    "  - {} `{}` (line {})\n",
                                    kind, name, line
                                ));
                            }
                        }
                    }
                }
            }
        }
        context
    }

    fn run_gemini(&self, session_id: &str, prompt: &str) -> Result<()> {
        log!("[Gemini Plugin] Spawning gemini for session={}", session_id);

        // Wrap in bash -lc to ensure shims and environment are active
        let child = match ChildProcess::spawn(
            "bash",
            vec![
                "-lc",
                &format!("gemini --json \"{}\"", prompt.replace("\"", "\\\"")),
            ],
            None,
            std::collections::HashMap::new(),
        ) {
            Ok(c) => c,
            Err(e) => {
                log!("[Gemini Plugin] Failed to spawn gemini: {:?}", e);
                push_ai_event(
                    session_id,
                    &AIEvent::Error {
                        message: format!("Failed to spawn gemini: {:?}", e),
                    },
                );
                push_ai_event(
                    session_id,
                    &AIEvent::TurnCompleted {
                        session_id: session_id.to_string(),
                    },
                );
                return Err(e);
            }
        };

        let mut buffer = Vec::new();

        while child.wait_for_data(60000) {
            if let Ok(ReadResult::Data(err_data)) = child.read(PipeType::Stderr) {
                if !err_data.is_empty() {
                    let err_msg = String::from_utf8_lossy(&err_data);
                    log!("[Gemini Plugin] Stderr: {}", err_msg);
                }
            }

            match child.read(PipeType::Stdout)? {
                ReadResult::Data(data) => {
                    buffer.extend(data);
                    while let Some(pos) = buffer.iter().position(|&b| b == b'\n') {
                        let line = buffer.drain(..=pos).collect::<Vec<_>>();
                        if let Ok(val) = serde_json::from_slice::<serde_json::Value>(&line) {
                            if val.get("type") == Some(&json!("item.completed")) {
                                if let Some(item) = val.get("item") {
                                    let item_type = item.get("type").and_then(|t| t.as_str());
                                    if item_type == Some("agent_message") {
                                        if let Some(msg) = item.get("text").and_then(|t| t.as_str())
                                        {
                                            push_ai_event(
                                                session_id,
                                                &AIEvent::StreamingDelta {
                                                    session_id: session_id.to_string(),
                                                    text: msg.to_string(),
                                                },
                                            );
                                        }
                                    } else if item_type == Some("reasoning") {
                                        if let Some(msg) = item.get("text").and_then(|t| t.as_str())
                                        {
                                            push_ai_event(
                                                session_id,
                                                &AIEvent::Reasoning {
                                                    session_id: session_id.to_string(),
                                                    text: msg.to_string(),
                                                },
                                            );
                                        }
                                    } else if item_type == Some("file_change") {
                                        // Gemini has written files to disk.  Emit a ToolCall for the
                                        // activity log AND a CrdtWrite so the host captures the
                                        // content into the CRDT VFS as a speculative write that the
                                        // user can approve or reject from the canvas overlay card.
                                        if let Some(changes) =
                                            item.get("changes").and_then(|c| c.as_array())
                                        {
                                            for change in changes {
                                                if let Some(path) =
                                                    change.get("path").and_then(|p| p.as_str())
                                                {
                                                    let kind = change
                                                        .get("kind")
                                                        .and_then(|k| k.as_str())
                                                        .unwrap_or("update");
                                                    push_ai_event(
                                                        session_id,
                                                        &AIEvent::ToolCall {
                                                            name: format!("WRITE {}", path),
                                                        },
                                                    );
                                                    if kind == "delete" {
                                                        // File has been deleted — emit CrdtWrite
                                                        // with empty content so the host can show
                                                        // a DEL row in the speculative overlay.
                                                        push_ai_event(
                                                            session_id,
                                                            &AIEvent::CrdtWrite {
                                                                session_id: session_id.to_string(),
                                                                path: path.to_string(),
                                                                content: String::new(),
                                                            },
                                                        );
                                                    } else {
                                                        match read_host_file(path) {
                                                            Ok(content) => {
                                                                push_ai_event(
                                                                    session_id,
                                                                    &AIEvent::CrdtWrite {
                                                                        session_id: session_id
                                                                            .to_string(),
                                                                        path: path.to_string(),
                                                                        content,
                                                                    },
                                                                );
                                                            }
                                                            Err(e) => {
                                                                log!(
                                                                    "[Gemini Plugin] Failed to read file {} for CrdtWrite: {:?}",
                                                                    path,
                                                                    e
                                                                );
                                                            }
                                                        }
                                                    }
                                                }
                                            }
                                        }
                                    }
                                }
                            }
                        } else {
                            let text = String::from_utf8_lossy(&line).to_string();
                            push_ai_event(
                                session_id,
                                &AIEvent::StreamingDelta {
                                    session_id: session_id.to_string(),
                                    text,
                                },
                            );
                        }
                    }
                }
                ReadResult::EOF => break,
                ReadResult::Empty => continue,
            }
        }

        push_ai_event(
            session_id,
            &AIEvent::TurnCompleted {
                session_id: session_id.to_string(),
            },
        );

        Ok(())
    }
}

#[chorograph_plugin]
pub fn init() {
    let ui = json!([
        { "type": "label", "text": "Gemini CLI (Rust WASM)" }
    ]);
    push_ui(&ui.to_string());
}

#[chorograph_plugin]
pub fn handle_action(action_id: String, payload: serde_json::Value) {
    let provider = GeminiCLI;
    log!(
        "[Gemini Plugin] handle_action id={} payload={}",
        action_id,
        payload
    );

    let context = provider.format_skeletons(&payload);

    // All action variants (chat, reply, plan, engage) use the same messages-array protocol.
    // Every turn is speculative: CrdtWrite events are always emitted so the host shows
    // overlay cards on the canvas for user approval/discard.
    if action_id == "chat" || action_id == "reply" || action_id == "plan" || action_id == "engage" {
        if let Some(session_id) = payload.get("session_id").and_then(|s| s.as_str()) {
            let messages = payload
                .get("messages")
                .and_then(|m| m.as_array())
                .map(|v| v.as_slice())
                .unwrap_or(&[]);

            let last_user_text = messages
                .iter()
                .rev()
                .find(|m| m.get("role").and_then(|r| r.as_str()) == Some("user"))
                .and_then(|m| m.get("text").and_then(|t| t.as_str()))
                .unwrap_or("");

            if !last_user_text.is_empty() {
                let history = provider.format_history(messages);
                let final_prompt = format!("{}{}{}", last_user_text, history, context);
                let _ = provider.run_gemini(session_id, &final_prompt);
            } else {
                log!(
                    "[Gemini Plugin] {}: no user message found in payload",
                    action_id
                );
            }
        }
    }
}
